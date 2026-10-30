import Accelerate
import Foundation

/// Per-frame summary of the music handed to lighting effects. All values are 0…1 unless noted.
public struct AudioFeatures: Equatable, Sendable {
    public var bands: [Float]
    public var level: Float          // smoothed, gain-normalized loudness
    public var rmsDB: Float          // raw RMS in dBFS
    public var bass: Float
    public var mid: Float
    public var treble: Float
    public var beat: Bool            // bass onset detected this frame
    public var isSilent: Bool        // below the noise gate long enough to go idle
    public var hasSignal: Bool       // any samples arrived since last frame

    public init(bandCount: Int) {
        bands = [Float](repeating: 0, count: bandCount)
        level = 0; rmsDB = -120; bass = 0; mid = 0; treble = 0
        beat = false; isSilent = true; hasSignal = false
    }

    public static let silent = AudioFeatures(bandCount: 0)
}

public struct AnalyzerSettings: Equatable, Sendable {
    /// 0.2…2. Higher = more dynamic range shown, i.e. quieter detail lights up.
    public var sensitivity: Float = 1
    /// 0…1. Higher = slower release, smoother look.
    public var smoothing: Float = 0.5
    /// 0…2 multiplier for bass energy.
    public var bassResponse: Float = 1
    /// Noise gate in dBFS; quieter audio counts as silence.
    public var noiseGateDB: Float = -60
    public var noiseGateEnabled = true
    /// Seconds of silence before `isSilent` becomes true.
    public var silenceHold: Double = 1.5
    public var adaptiveGain = true

    public init() {}
}

/// FFT spectrum analyzer: Hann window → vDSP real FFT → log-spaced bands with adaptive gain,
/// noise gating and attack/release smoothing, plus bass onset detection.
public final class AudioAnalyzer {
    public let fftSize: Int
    public let bandCount: Int
    public var settings = AnalyzerSettings()

    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private let window: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var power: [Float]

    private var bandEnvelopes: [Envelope]
    private var levelEnv = Envelope(attack: 0.02, release: 0.25)
    private var bassEnv = Envelope(attack: 0.01, release: 0.15)
    private var midEnv = Envelope(attack: 0.02, release: 0.2)
    private var trebleEnv = Envelope(attack: 0.01, release: 0.15)
    private var spectrumGain = AdaptiveGain()
    private var levelGain = AdaptiveGain(initialDB: -25)
    private var bassGain = AdaptiveGain()
    private var midGain = AdaptiveGain()
    private var trebleGain = AdaptiveGain()
    private var bassAverage: Float = 0
    private var lastBeat: Double = -1
    private var clock: Double = 0
    private var silentFor: Double = 10

    public init(fftSize: Int = 2048, bandCount: Int = 24) {
        precondition(fftSize.nonzeroBitCount == 1, "fftSize must be a power of two")
        self.fftSize = fftSize
        self.bandCount = bandCount
        log2n = vDSP_Length(log2(Double(fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningNormalized, count: fftSize, isHalfWindow: false)
        real = [Float](repeating: 0, count: fftSize / 2)
        imag = [Float](repeating: 0, count: fftSize / 2)
        power = [Float](repeating: 0, count: fftSize / 2)
        bandEnvelopes = Array(repeating: Envelope(attack: 0.015, release: 0.18), count: bandCount)
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    public func reset() {
        for i in bandEnvelopes.indices { bandEnvelopes[i].reset() }
        levelEnv.reset(); bassEnv.reset(); midEnv.reset(); trebleEnv.reset()
        bassAverage = 0; silentFor = 10
    }

    /// Lower/upper frequency edges (Hz) of each log-spaced band.
    public static func bandEdges(count: Int, low: Double = 30, high: Double = 16_000) -> [Double] {
        (0...count).map { low * pow(high / low, Double($0) / Double(count)) }
    }

    public func analyze(_ snap: SampleRing.Snapshot, dt: Double) -> AudioFeatures {
        clock += dt
        var f = AudioFeatures(bandCount: bandCount)
        f.hasSignal = snap.newFrames > 0
        f.rmsDB = linearToDB(snap.rms)

        // Smoothing 0…1 → release 60 ms…600 ms.
        let release = 0.06 + Double(settings.smoothing) * 0.54
        for i in bandEnvelopes.indices { bandEnvelopes[i].release = release }
        levelEnv.release = release * 1.3
        bassEnv.release = release * 0.8
        midEnv.release = release
        trebleEnv.release = release * 0.8

        let gated = settings.noiseGateEnabled && f.rmsDB < settings.noiseGateDB
        silentFor = gated || !f.hasSignal ? silentFor + dt : 0
        f.isSilent = silentFor >= settings.silenceHold

        computePower(snap.window)
        let binHz = snap.sampleRate / Double(fftSize)
        let edges = Self.bandEdges(count: bandCount)
        let range = 20 + 25 * min(2, max(0.2, settings.sensitivity))  // 25…70 dB shown

        var bandDB = [Float](repeating: -120, count: bandCount)
        for b in 0..<bandCount {
            bandDB[b] = linearToDB(sqrt(bandPower(from: edges[b], to: edges[b + 1], binHz: binHz)))
        }
        let maxBand = bandDB.max() ?? -120
        if settings.adaptiveGain && !gated { _ = spectrumGain.update(maxBand, dt: dt) }
        for b in 0..<bandCount {
            let target: Float = gated ? 0 : normalize(bandDB[b], spectrumGain, range)
            f.bands[b] = bandEnvelopes[b].process(target, dt: dt)
        }

        let bassDB = linearToDB(sqrt(bandPower(from: 20, to: 150, binHz: binHz)))
        let midDB = linearToDB(sqrt(bandPower(from: 150, to: 2_000, binHz: binHz)))
        let trebleDB = linearToDB(sqrt(bandPower(from: 2_000, to: 16_000, binHz: binHz)))
        if settings.adaptiveGain && !gated {
            _ = bassGain.update(bassDB, dt: dt); _ = midGain.update(midDB, dt: dt)
            _ = trebleGain.update(trebleDB, dt: dt); _ = levelGain.update(f.rmsDB, dt: dt)
        }
        let bassRaw: Float = gated ? 0 : min(1, normalize(bassDB, bassGain, range * 0.6) * settings.bassResponse)
        f.bass = bassEnv.process(bassRaw, dt: dt)
        f.mid = midEnv.process(gated ? 0 : normalize(midDB, midGain, range * 0.6), dt: dt)
        f.treble = trebleEnv.process(gated ? 0 : normalize(trebleDB, trebleGain, range * 0.6), dt: dt)
        f.level = levelEnv.process(gated ? 0 : normalize(f.rmsDB, levelGain, range * 0.7), dt: dt)

        // Onset: instantaneous bass well above its running mean, with a 150 ms refractory period.
        bassAverage += (bassRaw - bassAverage) * Float(min(1, dt / 0.6))
        if !gated, bassRaw > 0.45, bassRaw > bassAverage * 1.35 + 0.08, clock - lastBeat > 0.15 {
            f.beat = true
            lastBeat = clock
        }
        return f
    }

    private func normalize(_ db: Float, _ gain: AdaptiveGain, _ range: Float) -> Float {
        if settings.adaptiveGain { return gain.normalize(db, rangeDB: range) }
        // Fixed scale: 0 dBFS full, −range dBFS dark.
        return min(1, max(0, (db + range) / range))
    }

    private func computePower(_ samples: [Float]) {
        var windowed = [Float](repeating: 0, count: fftSize)
        let n = min(samples.count, fftSize)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                // DC and Nyquist are packed in real[0]/imag[0]; drop Nyquist.
                split.imagp[0] = 0
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(fftSize / 2))
            }
        }
        // zrip returns 2× the DFT; scale so a full-scale sine ≈ 1.0 amplitude in its bin.
        var scale = 1 / Float(fftSize * fftSize)
        vDSP_vsmul(power, 1, &scale, &power, 1, vDSP_Length(fftSize / 2))
        var two: Float = 2 * 2
        vDSP_vsmul(power, 1, &two, &power, 1, vDSP_Length(fftSize / 2))
    }

    /// Total power of bins in [lo, hi) (at least one bin). Summing over log-spaced bands gives
    /// pink-ish music a roughly flat response, and a sine's energy is captured despite window leakage.
    private func bandPower(from lo: Double, to hi: Double, binHz: Double) -> Float {
        let half = fftSize / 2
        var a = Int(ceil(lo / binHz)), b = Int(ceil(hi / binHz))
        a = max(1, min(a, half - 1)); b = max(a + 1, min(b, half))
        var sum: Float = 0
        for i in a..<b { sum += power[i] }
        return sum
    }
}

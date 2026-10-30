import Foundation
import Testing
@testable import BeatRGBKit

func sine(_ hz: Double, amplitude: Float = 0.5, count: Int = 4096, rate: Double = 48_000) -> [Float] {
    (0..<count).map { amplitude * Float(sin(2 * .pi * hz * Double($0) / rate)) }
}

/// Feeds `seconds` of signal through ring + analyzer at 30 fps, returning the last frame.
func run(_ analyzer: AudioAnalyzer, seconds: Double, signal: (Int) -> [Float]) -> AudioFeatures {
    let ring = SampleRing(sampleRate: 48_000)
    var last = AudioFeatures(bandCount: analyzer.bandCount)
    let frames = Int(seconds * 30)
    for i in 0..<frames {
        ring.append(signal(i))
        last = analyzer.analyze(ring.snapshot(count: analyzer.fftSize), dt: 1.0 / 30)
    }
    return last
}

@Suite struct AnalyzerTests {
    @Test func bassToneLightsLowBandsAndBass() {
        let a = AudioAnalyzer()
        let f = run(a, seconds: 1) { _ in sine(60, count: 1600) }
        #expect(!f.isSilent)
        #expect(f.bass > 0.6)
        #expect(f.bass > f.treble + 0.4)
        let low = f.bands.prefix(4).max()!, high = f.bands.suffix(6).max()!
        #expect(low > high + 0.4)
    }

    @Test func trebleToneLightsHighBands() {
        let a = AudioAnalyzer()
        let f = run(a, seconds: 1) { _ in sine(6_000, count: 1600) }
        #expect(f.treble > f.bass + 0.4)
        let peak = f.bands.indices.max { f.bands[$0] < f.bands[$1] }!
        let edges = AudioAnalyzer.bandEdges(count: a.bandCount)
        #expect(edges[peak] <= 6_000 && 6_000 < edges[peak + 1] * 1.2)
    }

    @Test func silenceGoesIdleAfterHold() {
        let a = AudioAnalyzer()
        a.settings.silenceHold = 1
        _ = run(a, seconds: 0.5) { _ in sine(100, count: 1600) }
        let early = run(a, seconds: 0.5) { _ in [Float](repeating: 0, count: 1600) }
        #expect(!early.isSilent)
        let later = run(a, seconds: 1) { _ in [Float](repeating: 0, count: 1600) }
        #expect(later.isSilent)
        #expect(later.bands.allSatisfy { $0 < 0.05 })
    }

    @Test func noiseGateIgnoresHiss() {
        let a = AudioAnalyzer()
        a.settings.noiseGateDB = -50
        a.settings.silenceHold = 0.3
        let f = run(a, seconds: 1) { _ in (0..<1600).map { _ in Float.random(in: -0.001...0.001) } }
        #expect(f.isSilent)
        #expect(f.level < 0.05)
    }

    @Test func kickDrumProducesBeats() {
        let a = AudioAnalyzer()
        var beats = 0
        let ring = SampleRing()
        for i in 0..<90 {   // 3 s, kick every 0.5 s (15 frames)
            let on = i % 15 < 3
            ring.append(on ? sine(55, amplitude: 0.9, count: 1600) : sine(55, amplitude: 0.02, count: 1600))
            if a.analyze(ring.snapshot(count: a.fftSize), dt: 1.0 / 30).beat { beats += 1 }
        }
        #expect((4...7).contains(beats))
    }

    @Test func envelopeAttackFasterThanRelease() {
        var e = Envelope(attack: 0.01, release: 0.5)
        e.process(1, dt: 0.033)
        #expect(e.value > 0.9)
        e.process(0, dt: 0.033)
        #expect(e.value > 0.85)
    }

    @Test func adaptiveGainDecaysButRespectsFloor() {
        var g = AdaptiveGain(decayDBPerSecond: 10, floorDB: -40, initialDB: -10)
        #expect(g.update(-30, dt: 1) == -20)
        #expect(g.update(-90, dt: 10) == -40)
        #expect(g.normalize(-40, rangeDB: 20) == 1)
        #expect(g.normalize(-60, rangeDB: 20) == 0)
    }

    @Test func ringSnapshotReturnsMostRecentSamplesAndRMS() {
        let ring = SampleRing(capacity: 8)
        ring.append([1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        let s = ring.snapshot(count: 4)
        #expect(s.window == [7, 8, 9, 10])
        #expect(s.newFrames == 10)
        #expect(abs(s.rms - Float((385.0 / 10).squareRoot())) < 1e-4)
        #expect(ring.snapshot(count: 2).newFrames == 0)
    }
}

@Suite struct EffectTests {
    func features(bands: [Float], silent: Bool = false) -> AudioFeatures {
        var f = AudioFeatures(bandCount: bands.count)
        f.bands = bands; f.isSilent = silent; f.level = 0.8; f.bass = bands.first ?? 0
        return f
    }

    @Test func spectrumMapsLowToLeftAndRisesFromBottom() {
        let r = EffectRenderer(layout: .grid(rows: 6, cols: 17))
        r.settings.effect = .spectrum; r.settings.brightness = 1
        var bands = [Float](repeating: 0, count: 24); bands[0] = 1; bands[1] = 1
        // Effects fade in from the idle look, so let the crossfade settle first.
        var out: [RGBF] = []
        for _ in 0..<30 { out = r.render(features: features(bands: bands), screen: nil, dt: 1.0 / 30) }
        func peak(_ c: RGBF) -> Float { max(c.r, c.g, c.b) }
        let bottomLeft = peak(out[5 * 17 + 0]), bottomRight = peak(out[5 * 17 + 16])
        let topLeft = peak(out[0])
        #expect(bottomLeft > 0.2)
        #expect(bottomRight < 0.05)
        #expect(topLeft > 0.2)   // full-height bar
        bands[0] = 0.35; bands[1] = 0.35
        let half = r.render(features: features(bands: bands), screen: nil, dt: 1.0 / 30)
        #expect(half[5 * 17].luminance > half[0].luminance * 3)
    }

    @Test func masterBrightnessZeroIsBlack() {
        let r = EffectRenderer()
        r.settings.effect = .rainbowWave; r.settings.brightness = 0
        let out = r.render(features: features(bands: [1, 1, 1]), screen: nil, dt: 0.03)
        #expect(out.allSatisfy { $0 == .black })
    }

    @Test func silenceCrossfadesToIdleColour() {
        let r = EffectRenderer(layout: .grid(rows: 2, cols: 2))
        r.settings.effect = .bassPulse; r.settings.idle = .staticColor
        r.settings.idleColor = ColorValue(0, 1, 0); r.settings.brightness = 1
        var out: [RGBF] = []
        for _ in 0..<60 { out = r.render(features: features(bands: [0, 0], silent: true), screen: nil, dt: 0.05) }
        #expect(out.allSatisfy { abs($0.g - 0.6) < 0.01 && $0.r < 0.01 })
        r.settings.idle = .off
        for _ in 0..<60 { out = r.render(features: features(bands: [0, 0], silent: true), screen: nil, dt: 0.05) }
        #expect(out.allSatisfy { $0.luminance < 0.01 })
    }

    @Test func bassPulseFollowsBass() {
        let r = EffectRenderer(layout: .grid(rows: 6, cols: 17))
        r.settings.effect = .bassPulse; r.settings.baseline = 0.1; r.settings.brightness = 1
        var quiet = features(bands: [0]); quiet.bass = 0
        var loud = features(bands: [1]); loud.bass = 1
        let a = r.render(features: quiet, screen: nil, dt: 0.03).map(\.luminance).reduce(0, +)
        var b: Float = 0
        for _ in 0..<5 { b = r.render(features: loud, screen: nil, dt: 0.03).map(\.luminance).reduce(0, +) }
        #expect(b > a * 3)
    }

    @Test func screenMirrorFollowsDisplayLayout() {
        let r = EffectRenderer(layout: .grid(rows: 6, cols: 17))
        r.settings.effect = .screenMirror; r.settings.brightness = 1; r.settings.screenSaturation = 0
        // Left half red, right half blue.
        let grid = ScreenGrid(width: 4, height: 2, pixels: [RGBF(1, 0, 0), RGBF(1, 0, 0), RGBF(0, 0, 1), RGBF(0, 0, 1),
                                                            RGBF(1, 0, 0), RGBF(1, 0, 0), RGBF(0, 0, 1), RGBF(0, 0, 1)])
        var out: [RGBF] = []
        for _ in 0..<40 { out = r.render(features: .silent, screen: grid, dt: 0.05) }
        #expect(out[0].r > 0.95 && out[0].b < 0.05)
        #expect(out[16].b > 0.95 && out[16].r < 0.05)
        #expect(out[5 * 17].r > 0.95)
    }

    @Test func screenDownsampleAveragesBlocks() {
        // 4×2 BGRA image: left column pair white, right pair black.
        var px = [UInt8]()
        for _ in 0..<2 { for x in 0..<4 { let v: UInt8 = x < 2 ? 255 : 0; px += [v, v, v, 255] } }
        let grid = px.withUnsafeBufferPointer {
            ScreenSampler.downsampleBGRA($0.baseAddress!, width: 4, height: 2, bytesPerRow: 16, gridWidth: 2, gridHeight: 1)
        }
        #expect(grid.pixels == [RGBF(1, 1, 1), RGBF(0, 0, 0)])
    }

    @Test func hsvRoundTrip() {
        for h in stride(from: Float(0), to: 1, by: 0.1) {
            let c = RGBF.hsv(h, 0.8, 0.9)
            let back = c.hsv
            #expect(abs(back.h - h) < 0.01 && abs(back.s - 0.8) < 0.01 && abs(back.v - 0.9) < 0.01)
        }
    }
}

@Suite struct SettingsAndKnobTests {
    @Test func settingsDecodeWithMissingKeys() throws {
        let s = try JSONDecoder().decode(LightingSettings.self, from: Data(#"{"effect":"bassPulse","brightness":0.3}"#.utf8))
        #expect(s.effect == .bassPulse)
        #expect(s.brightness == 0.3)
        #expect(s.idle == LightingSettings().idle)
    }

    @Test func profileStoreRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ProfileStore(directory: dir)
        #expect(store.load().profiles.map(\.name).contains("Bass Party"))
        var lib = ProfileLibrary.builtIn
        lib.profiles[0].name = "Mine"
        lib.activeID = lib.profiles[1].id
        try store.save(lib)
        #expect(store.load() == lib)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func knobRotationDecodes() {
        // Reports captured from the keyboard's 0xFF42 usage 2 interface in software mode.
        var d = KnobDecoder()
        var r: [UInt8] = [0x00, 0x05, 0x60, 0x00, 0x01, 0x00, 0x00, 0x00] + [UInt8](repeating: 0, count: 56)
        #expect(d.decode(r) == .rotate(1))
        r[4] = 0xFF; r[5] = 0xFF; r[6] = 0xFF; r[7] = 0xFF
        #expect(d.decode(r) == .rotate(-1))
        r[2] = 0x61
        #expect(d.decode(r) == nil)
    }

    @Test func keyReportsNeverToggleMute() {
        var d = KnobDecoder()
        for i in 2..<24 {
            var r = [UInt8](repeating: 0, count: 64); r[1] = 0x02; r[i] = 0xFF
            #expect(d.decode(r) == nil)
        }
    }
}

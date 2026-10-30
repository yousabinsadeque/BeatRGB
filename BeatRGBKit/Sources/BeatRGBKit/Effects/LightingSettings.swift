import Foundation

public enum EffectKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case spectrum, mirrorSpectrum, vuMeter, bassPulse, beatStrobe, rainbowWave, fullReact, ripple, sparkle, fire,
         screenMirror, staticColor
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .spectrum: return "Audio Spectrum"
        case .mirrorSpectrum: return "Centre EQ"
        case .vuMeter: return "VU Meter"
        case .beatStrobe: return "Beat Flash"
        case .sparkle: return "Treble Sparkle"
        case .fire: return "Bass Fire"
        case .bassPulse: return "Bass Pulse"
        case .rainbowWave: return "Rainbow Music Wave"
        case .fullReact: return "Full-Keyboard Reaction"
        case .ripple: return "Beat Ripple"
        case .screenMirror: return "Screen Mirror"
        case .staticColor: return "Static Colour"
        }
    }

    public var symbol: String {
        switch self {
        case .spectrum: return "chart.bar.fill"
        case .mirrorSpectrum: return "align.vertical.center.fill"
        case .vuMeter: return "gauge.with.needle.fill"
        case .beatStrobe: return "bolt.fill"
        case .sparkle: return "sparkles"
        case .fire: return "flame.fill"
        case .bassPulse: return "waveform.path.ecg"
        case .rainbowWave: return "rainbow"
        case .fullReact: return "circle.lefthalf.filled"
        case .ripple: return "dot.radiowaves.left.and.right"
        case .screenMirror: return "display"
        case .staticColor: return "paintpalette"
        }
    }

    /// Effects that react to music (and therefore use the idle transition).
    public var isAudioReactive: Bool { self != .screenMirror && self != .staticColor }
    public var usesAudio: Bool { isAudioReactive }
    public var usesScreen: Bool { self == .screenMirror }
    /// Effects whose look depends on the Colour picker (the rest use their own palette).
    public var usesPrimaryColor: Bool {
        switch self {
        case .spectrum, .mirrorSpectrum, .bassPulse, .fullReact, .ripple, .sparkle, .staticColor: return true
        case .vuMeter, .beatStrobe, .rainbowWave, .fire, .screenMirror: return false
        }
    }
}

public enum SpectrumStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case multicolor, gradient, single
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .multicolor: return "Multicolour spectrum"
        case .gradient: return "Two-colour gradient"
        case .single: return "Single colour"
        }
    }
}

public enum IdleKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case staticColor, breathing, rainbow, off
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .staticColor: return "Static colour"
        case .breathing: return "Breathing"
        case .rainbow: return "Rainbow"
        case .off: return "Lights off"
        }
    }
}

public struct LightingSettings: Codable, Equatable, Sendable {
    public var effect: EffectKind = .spectrum
    public var spectrumStyle: SpectrumStyle = .multicolor
    public var primaryColor = ColorValue(hex: 0xFF1E3C)
    public var secondaryColor = ColorValue(hex: 0x2A6BFF)
    /// Master brightness 0…1, applied to every effect.
    public var brightness: Double = 0.85
    /// Animation speed multiplier 0.1…3.
    public var speed: Double = 1
    public var sensitivity: Double = 1
    public var smoothing: Double = 0.45
    public var bassResponse: Double = 1
    public var pulseAttackMs: Double = 25
    public var pulseDecayMs: Double = 260
    /// Brightness floor for Bass Pulse, 0…0.6.
    public var baseline: Double = 0.08
    public var noiseGateEnabled = true
    public var noiseGateDB: Double = -60
    public var adaptiveGain = true
    public var idle: IdleKind = .breathing
    public var idleColor = ColorValue(hex: 0x6A3CFF)
    public var idleDelay: Double = 2
    /// Screen Mirror: saturation boost 0…1 and which display (0 = main).
    public var screenSaturation: Double = 0.35
    /// Screen Mirror brightness multiplier (1…4): averaged screen areas are usually dim on the keys.
    public var screenGain: Double = 2
    public var screenDisplayIndex: Int = 0
    public var targetFPS: Double = 30

    public init() {}

    public init(from decoder: Decoder) throws {
        // Missing keys fall back to defaults, so profiles saved by older versions keep loading.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LightingSettings()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        effect = v(.effect, d.effect)
        spectrumStyle = v(.spectrumStyle, d.spectrumStyle)
        primaryColor = v(.primaryColor, d.primaryColor)
        secondaryColor = v(.secondaryColor, d.secondaryColor)
        brightness = v(.brightness, d.brightness)
        speed = v(.speed, d.speed)
        sensitivity = v(.sensitivity, d.sensitivity)
        smoothing = v(.smoothing, d.smoothing)
        bassResponse = v(.bassResponse, d.bassResponse)
        pulseAttackMs = v(.pulseAttackMs, d.pulseAttackMs)
        pulseDecayMs = v(.pulseDecayMs, d.pulseDecayMs)
        baseline = v(.baseline, d.baseline)
        noiseGateEnabled = v(.noiseGateEnabled, d.noiseGateEnabled)
        noiseGateDB = v(.noiseGateDB, d.noiseGateDB)
        adaptiveGain = v(.adaptiveGain, d.adaptiveGain)
        idle = v(.idle, d.idle)
        idleColor = v(.idleColor, d.idleColor)
        idleDelay = v(.idleDelay, d.idleDelay)
        screenSaturation = v(.screenSaturation, d.screenSaturation)
        screenGain = v(.screenGain, d.screenGain)
        screenDisplayIndex = v(.screenDisplayIndex, d.screenDisplayIndex)
        targetFPS = v(.targetFPS, d.targetFPS)
    }

    public var analyzerSettings: AnalyzerSettings {
        var a = AnalyzerSettings()
        a.sensitivity = Float(sensitivity)
        a.smoothing = Float(smoothing)
        a.bassResponse = Float(bassResponse)
        a.noiseGateDB = Float(noiseGateDB)
        a.noiseGateEnabled = noiseGateEnabled
        a.adaptiveGain = adaptiveGain
        a.silenceHold = idleDelay
        return a
    }
}

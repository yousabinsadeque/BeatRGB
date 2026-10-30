import Foundation

/// Low-resolution snapshot of a display, row-major, top-left origin.
public struct ScreenGrid: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var pixels: [RGBF]

    public init(width: Int, height: Int, pixels: [RGBF]) {
        self.width = width; self.height = height; self.pixels = pixels
    }

    /// Bilinear sample at normalised (x, y).
    public func sample(x: Float, y: Float) -> RGBF {
        guard width > 0, height > 0, pixels.count == width * height else { return .black }
        let fx = min(max(x, 0), 1) * Float(width - 1), fy = min(max(y, 0), 1) * Float(height - 1)
        let x0 = Int(fx), y0 = Int(fy)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let tx = fx - Float(x0), ty = fy - Float(y0)
        let top = pixels[y0 * width + x0].mix(pixels[y0 * width + x1], tx)
        let bottom = pixels[y1 * width + x0].mix(pixels[y1 * width + x1], tx)
        return top.mix(bottom, ty)
    }
}

/// Stateful renderer: turns audio features (or screen colours) into one colour per LED.
public final class EffectRenderer {
    public var settings = LightingSettings()
    public private(set) var layout: KeyboardLayout

    private var time: Double = 0
    private var wavePhase: Double = 0
    private var pulse = Envelope(attack: 0.025, release: 0.26)
    private var idleMix: Float = 1          // 1 = fully idle, 0 = fully active
    private var ripples: [(x: Float, y: Float, age: Float, hue: Float)] = []
    private var screenColors: [RGBF] = []

    public init(layout: KeyboardLayout = .placeholderTKL) { self.layout = layout }

    public func setLayout(_ layout: KeyboardLayout) {
        self.layout = layout
        screenColors = []
    }

    public func render(features f: AudioFeatures, screen: ScreenGrid?, dt: Double) -> [RGBF] {
        time += dt
        let s = settings
        let active: [RGBF]
        switch s.effect {
        case .spectrum: active = spectrum(f)
        case .bassPulse: active = bassPulse(f, dt: dt)
        case .rainbowWave: active = rainbowWave(f, dt: dt)
        case .fullReact: active = fullReact(f)
        case .ripple: active = ripple(f, dt: dt)
        case .screenMirror: active = screenMirror(screen, dt: dt)
        case .staticColor: active = Array(repeating: RGBF(s.primaryColor), count: layout.ledCount)
        }

        var out = active
        if s.effect.isAudioReactive {
            // Crossfade between music and idle over ~1.2 s so stopping music never snaps.
            let target: Float = f.isSilent ? 1 : 0
            let step = Float(dt / 1.2)
            idleMix = target > idleMix ? min(target, idleMix + step) : max(target, idleMix - step * 3)
            if idleMix > 0 {
                let idle = idleFrame()
                out = zip(active, idle).map { $0.mix($1, idleMix) }
            }
        } else {
            idleMix = 0
        }
        let master = Float(min(1, max(0, s.brightness)))
        return out.map { ($0 * master).clamped }
    }

    /// Idle frame on its own (also used when sync stops with "show idle" selected).
    public func idleFrame() -> [RGBF] {
        let s = settings
        let n = layout.ledCount
        switch s.idle {
        case .off:
            return Array(repeating: .black, count: n)
        case .staticColor:
            return Array(repeating: RGBF(s.idleColor) * 0.6, count: n)
        case .breathing:
            let k = Float(0.12 + 0.48 * (0.5 - 0.5 * cos(time * 2 * .pi / (5.0 / max(0.1, s.speed)))))
            return Array(repeating: RGBF(s.idleColor) * k, count: n)
        case .rainbow:
            let phase = Float(time * 0.05 * s.speed)
            return layout.positions.map { RGBF.hsv(phase + $0.x * 0.6, 1, 0.45) }
        }
    }

    // MARK: Effects

    private func bandValue(_ f: AudioFeatures, at x: Float) -> Float {
        guard !f.bands.isEmpty else { return 0 }
        let pos = min(max(x, 0), 1) * Float(f.bands.count - 1)
        let i = Int(pos), j = min(i + 1, f.bands.count - 1)
        return f.bands[i] + (f.bands[j] - f.bands[i]) * (pos - Float(i))
    }

    /// Low → left, high → right; each column is an equaliser bar rising from the bottom row.
    private func spectrum(_ f: AudioFeatures) -> [RGBF] {
        let s = settings
        let rows = Float(layout.rows)
        return layout.positions.map { p in
            let v = bandValue(f, at: p.x)
            let height = 1 - p.y                         // 0 at bottom row, 1 at top
            let rowSize = 1 / max(1, rows - 1)
            // Soft edge: a key is lit if the bar reaches it, partially lit within one row.
            let lit = min(1, max(0, (v * (1 + rowSize) - height) / rowSize))
            let glow = 0.06 + 0.94 * lit
            let color: RGBF
            switch s.spectrumStyle {
            case .multicolor: color = RGBF.hsv(0.0 + p.x * 0.78, 1, 1)
            case .gradient: color = RGBF(s.primaryColor).mix(RGBF(s.secondaryColor), height)
            case .single: color = RGBF(s.primaryColor)
            }
            return color * (glow * (0.35 + 0.65 * v))
        }
    }

    private func bassPulse(_ f: AudioFeatures, dt: Double) -> [RGBF] {
        let s = settings
        pulse.attack = s.pulseAttackMs / 1000
        pulse.release = s.pulseDecayMs / 1000
        var drive = f.bass
        if f.beat { drive = max(drive, 1) }
        let e = pulse.process(drive, dt: dt)
        let base = Float(s.baseline)
        let color = RGBF(s.primaryColor)
        // Light spreads from the centre outward as the pulse grows.
        return layout.positions.map { p in
            let dx = (p.x - 0.5) * 1.6, dy = (p.y - 0.5)
            let dist = min(1, (dx * dx + dy * dy).squareRoot())
            let reach = max(0, min(1, (e * 1.3 - dist * 0.7)))
            return color * (base + (1 - base) * max(e * 0.35, reach))
        }
    }

    private func rainbowWave(_ f: AudioFeatures, dt: Double) -> [RGBF] {
        let s = settings
        wavePhase += dt * s.speed * (0.15 + 0.9 * Double(f.level) + (f.beat ? 0.4 : 0))
        let brightness = 0.25 + 0.75 * f.level
        return layout.positions.map { p in
            let ripple = 0.08 * sin((p.y * 3 + Float(wavePhase) * 2) * .pi)
            return RGBF.hsv(p.x * 0.9 + ripple - Float(wavePhase), 1, brightness)
        }
    }

    /// One colour for all keys: hue from bass/mid/treble balance, brightness from loudness.
    private func fullReact(_ f: AudioFeatures) -> [RGBF] {
        let total = f.bass + f.mid + f.treble + 1e-4
        let mixColor = RGBF(1, 0.05, 0.15) * (f.bass / total)
            + RGBF(0.1, 1, 0.3) * (f.mid / total)
            + RGBF(0.2, 0.35, 1) * (f.treble / total)
        let tinted = mixColor.mix(RGBF(settings.primaryColor), 0.25)
        let peak = max(tinted.r, tinted.g, tinted.b, 1e-4)
        let color = tinted * (1 / peak) * (0.08 + 0.92 * f.level)
        return Array(repeating: color, count: layout.ledCount)
    }

    private func ripple(_ f: AudioFeatures, dt: Double) -> [RGBF] {
        if f.beat, ripples.count < 6 {
            let seed = Float(time.truncatingRemainder(dividingBy: 97))
            ripples.append((x: 0.5 + 0.4 * sin(seed * 7.1), y: 0.5 + 0.4 * cos(seed * 3.3), age: 0, hue: seed * 0.13))
        }
        let speed = Float(settings.speed)
        for i in ripples.indices { ripples[i].age += Float(dt) * speed }
        ripples.removeAll { $0.age > 1.6 }
        let base = RGBF(settings.primaryColor) * (0.05 + 0.25 * f.level)
        return layout.positions.map { p in
            var c = base
            for r in ripples {
                let dx = (p.x - r.x) * 1.8, dy = p.y - r.y
                let d = (dx * dx + dy * dy).squareRoot()
                let ring = max(0, 1 - abs(d - r.age * 0.9) * 6) * max(0, 1 - r.age / 1.6)
                c = c + RGBF.hsv(r.hue, 0.9, 1) * ring
            }
            return c
        }
    }

    private func screenMirror(_ screen: ScreenGrid?, dt: Double) -> [RGBF] {
        let n = layout.ledCount
        if screenColors.count != n { screenColors = Array(repeating: .black, count: n) }
        guard let screen else { return screenColors }
        // ~120 ms smoothing so video doesn't strobe the keyboard.
        let k = Float(1 - exp(-dt / max(0.02, 0.12 * (1.2 - settings.smoothing))))
        let boost = Float(settings.screenSaturation)
        for i in 0..<n {
            let p = layout.positions[i]
            var c = screen.sample(x: p.x, y: p.y)
            if boost > 0 {
                let hsv = c.hsv
                c = RGBF.hsv(hsv.h, min(1, hsv.s * (1 + boost * 1.5)), hsv.v)
            }
            screenColors[i] = screenColors[i].mix(c, k)
        }
        return screenColors
    }
}

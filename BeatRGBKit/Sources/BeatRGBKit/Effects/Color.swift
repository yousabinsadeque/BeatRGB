import Foundation

/// Linear 0…1 float colour used while rendering.
public struct RGBF: Equatable, Sendable {
    public var r: Float, g: Float, b: Float
    public init(_ r: Float, _ g: Float, _ b: Float) { self.r = r; self.g = g; self.b = b }
    public static let black = RGBF(0, 0, 0)
    public static let white = RGBF(1, 1, 1)

    public static func * (c: RGBF, k: Float) -> RGBF { RGBF(c.r * k, c.g * k, c.b * k) }
    public static func + (a: RGBF, b: RGBF) -> RGBF { RGBF(a.r + b.r, a.g + b.g, a.b + b.b) }

    public func mix(_ other: RGBF, _ t: Float) -> RGBF {
        let t = min(1, max(0, t))
        return RGBF(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t)
    }

    public var clamped: RGBF { RGBF(min(1, max(0, r)), min(1, max(0, g)), min(1, max(0, b))) }
    public var luminance: Float { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    public var rgb8: RGB8 {
        let c = clamped
        return RGB8(UInt8((c.r * 255).rounded()), UInt8((c.g * 255).rounded()), UInt8((c.b * 255).rounded()))
    }

    public init(_ c: RGB8) { self.init(Float(c.r) / 255, Float(c.g) / 255, Float(c.b) / 255) }
    public init(_ c: ColorValue) { self.init(Float(c.r), Float(c.g), Float(c.b)) }

    /// h in turns (0…1), s and v 0…1.
    public static func hsv(_ h: Float, _ s: Float, _ v: Float) -> RGBF {
        let h = (h - floor(h)) * 6
        let i = Int(h) % 6
        let f = h - floor(h)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch i {
        case 0: return RGBF(v, t, p)
        case 1: return RGBF(q, v, p)
        case 2: return RGBF(p, v, t)
        case 3: return RGBF(p, q, v)
        case 4: return RGBF(t, p, v)
        default: return RGBF(v, p, q)
        }
    }

    public var hsv: (h: Float, s: Float, v: Float) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h: Float = 0
        if d > 0 {
            if mx == r { h = (g - b) / d } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
            h /= 6; if h < 0 { h += 1 }
        }
        return (h, mx > 0 ? d / mx : 0, mx)
    }
}

/// Codable colour for settings/profiles (0…1 components).
public struct ColorValue: Codable, Equatable, Hashable, Sendable {
    public var r: Double, g: Double, b: Double
    public init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
    public init(hex: UInt32) {
        self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }
    public var hexString: String {
        String(format: "#%02X%02X%02X", Int(r * 255 + 0.5), Int(g * 255 + 0.5), Int(b * 255 + 0.5))
    }
    public static let red = ColorValue(hex: 0xFF0000)
}

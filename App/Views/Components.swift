import BeatRGBKit
import SwiftUI

extension Color {
    init(_ c: RGB8) { self.init(.sRGB, red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255) }
    init(_ c: ColorValue) { self.init(.sRGB, red: c.r, green: c.g, blue: c.b) }

    var colorValue: ColorValue {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return ColorValue(Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent))
    }
}

extension Binding where Value == ColorValue {
    var color: Binding<Color> { Binding<Color>(get: { Color(wrappedValue) }, set: { wrappedValue = $0.colorValue }) }
}

enum StatusLevel {
    case ok, working, warning, error, off
    var color: Color {
        switch self {
        case .ok: return .green
        case .working: return .blue
        case .warning: return .orange
        case .error: return .red
        case .off: return .secondary
        }
    }
}

struct StatusDot: View {
    let level: StatusLevel
    var body: some View {
        Circle().fill(level.color).frame(width: 8, height: 8)
            .shadow(color: level.color.opacity(0.6), radius: level == .off ? 0 : 3)
    }
}

struct StatusCard: View {
    let title: String
    let symbol: String
    let level: StatusLevel
    let value: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(.secondary)
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                StatusDot(level: level)
            }
            Text(value).font(.headline).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct Panel<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Draws the keyboard from the real LED matrix with the colours currently being sent.
struct KeyboardPreview: View {
    let layout: KeyboardLayout
    let frame: [RGB8]

    var body: some View {
        Canvas { ctx, size in
            let gap: CGFloat = 4
            let cw = (size.width - gap * CGFloat(layout.cols - 1)) / CGFloat(layout.cols)
            let ch = min(cw, (size.height - gap * CGFloat(layout.rows - 1)) / CGFloat(layout.rows))
            let totalH = ch * CGFloat(layout.rows) + gap * CGFloat(layout.rows - 1)
            let yOffset = (size.height - totalH) / 2
            for (i, cell) in layout.cells.enumerated() {
                guard let cell else { continue }
                let rect = CGRect(x: CGFloat(cell.col) * (cw + gap), y: yOffset + CGFloat(cell.row) * (ch + gap), width: cw, height: ch)
                let key = Path(roundedRect: rect, cornerRadius: min(5, cw * 0.15))
                let c = i < frame.count ? frame[i] : RGB8(20, 20, 24)
                let color = Color(c)
                ctx.fill(key, with: .color(Color(white: 0.11)))
                ctx.fill(key, with: .color(color.opacity(0.92)))
                let lum = (0.2126 * Double(c.r) + 0.7152 * Double(c.g) + 0.0722 * Double(c.b)) / 255
                if lum > 0.05 {
                    var glow = ctx
                    glow.addFilter(.blur(radius: 6))
                    glow.fill(key, with: .color(color.opacity(min(0.8, lum))))
                }
                ctx.stroke(key, with: .color(.white.opacity(0.08)), lineWidth: 1)
            }
        }
        .aspectRatio(CGFloat(layout.cols) / CGFloat(max(1, layout.rows)) * 1.05, contentMode: .fit)
        .padding(10)
        .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityLabel("Keyboard lighting preview")
    }
}

struct SpectrumView: View {
    let bands: [Float]
    var body: some View {
        Canvas { ctx, size in
            guard !bands.isEmpty else { return }
            let gap: CGFloat = 3
            let w = (size.width - gap * CGFloat(bands.count - 1)) / CGFloat(bands.count)
            for (i, v) in bands.enumerated() {
                let h = max(2, CGFloat(v) * size.height)
                let rect = CGRect(x: CGFloat(i) * (w + gap), y: size.height - h, width: w, height: h)
                let hue = Double(i) / Double(bands.count) * 0.78
                ctx.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(Color(hue: hue, saturation: 0.85, brightness: 0.95)))
            }
        }
        .frame(height: 90)
        .accessibilityLabel("Live frequency spectrum")
    }
}

struct LevelMeter: View {
    let level: Float
    let db: Float
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(LinearGradient(colors: [.green, .yellow, .red], startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * CGFloat(min(1, max(0, level))))
                }
            }
            .frame(height: 10)
            Text(db <= -119 ? "No signal" : String(format: "%.0f dBFS", db))
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.0f%%", $0 * 100) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value)).foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.callout)
            Slider(value: $value, in: range)
        }
    }
}

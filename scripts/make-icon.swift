// Renders the BeatRGB app icon: an equaliser made of glowing RGB keycaps on a dark tile.
// Usage: swiftc -O scripts/make-icon.swift -o /tmp/make-icon && /tmp/make-icon icon-1024.png, then resize with sips.
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ h: CGFloat, _ s: CGFloat = 1, _ b: CGFloat = 1, _ a: CGFloat = 1) -> CGColor {
    NSColor(hue: h.truncatingRemainder(dividingBy: 1), saturation: s, brightness: b, alpha: a).usingColorSpace(.sRGB)!.cgColor
}

// Tile: Apple's macOS grid puts an 824 pt rounded square in the 1024 canvas.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.45))
ctx.addPath(tilePath); ctx.setFillColor(CGColor(gray: 0.05, alpha: 1)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [CGColor(srgbRed: 0.10, green: 0.09, blue: 0.20, alpha: 1),
                                              CGColor(srgbRed: 0.02, green: 0.02, blue: 0.05, alpha: 1)] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

// Equaliser: 7 columns of keycaps, rainbow left → right.
let heights = [2, 4, 6, 5, 3, 5, 3]
let cols = heights.count
let key: CGFloat = 78, gap: CGFloat = 18
let totalW = CGFloat(cols) * key + CGFloat(cols - 1) * gap
let x0 = 512 - totalW / 2, y0: CGFloat = 230
for (c, h) in heights.enumerated() {
    let hue = 0.0 + CGFloat(c) / CGFloat(cols) * 0.82
    for r in 0..<h {
        let rect = CGRect(x: x0 + CGFloat(c) * (key + gap), y: y0 + CGFloat(r) * (key + gap), width: key, height: key)
        let top = r == h - 1
        let bright: CGFloat = top ? 1 : 0.55 + 0.45 * CGFloat(r) / CGFloat(max(1, h - 1))
        let cap = CGPath(roundedRect: rect, cornerWidth: 18, cornerHeight: 18, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: top ? 46 : 26, color: rgb(hue, 1, 1, top ? 0.95 : 0.6))
        ctx.addPath(cap); ctx.setFillColor(rgb(hue, 0.9, bright)); ctx.fillPath()
        ctx.restoreGState()
        // Keycap face highlight.
        ctx.saveGState()
        ctx.addPath(cap); ctx.clip()
        let hl = CGGradient(colorsSpace: cs, colors: [CGColor(gray: 1, alpha: 0.35), CGColor(gray: 1, alpha: 0)] as CFArray,
                            locations: [0, 1])!
        ctx.drawLinearGradient(hl, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.midY), options: [])
        ctx.restoreGState()
    }
}

// Soft reflection line under the bars, like light spilling onto a desk.
let spill = CGGradient(colorsSpace: cs, colors: [rgb(0.55, 0.6, 1, 0.35), rgb(0.55, 0.6, 1, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(spill, startCenter: CGPoint(x: 512, y: 200), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 200), endRadius: 380, options: [])

// Top sheen.
let sheen = CGGradient(colorsSpace: cs, colors: [CGColor(gray: 1, alpha: 0.10), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 640), options: [])
ctx.restoreGState()

// Thin rim.
ctx.addPath(tilePath); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.12)); ctx.setLineWidth(3); ctx.strokePath()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

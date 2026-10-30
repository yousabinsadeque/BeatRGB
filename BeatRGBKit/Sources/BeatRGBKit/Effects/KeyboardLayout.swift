import Foundation

/// Physical position of every LED, derived from the matrix maps OpenRGB reports, so effects never
/// assume a fixed key arrangement.
public struct KeyboardLayout: Equatable, Sendable {
    public struct Cell: Equatable, Sendable {
        public var row: Int
        public var col: Int
    }

    public var ledCount: Int
    public var rows: Int
    public var cols: Int
    /// Grid cell per LED; nil for LEDs that aren't in any matrix (placed on an extra row).
    public var cells: [Cell?]
    /// Normalised position (x left→right, y top→bottom), 0…1.
    public var positions: [(x: Float, y: Float)]
    public var names: [String]

    public static func == (a: KeyboardLayout, b: KeyboardLayout) -> Bool {
        a.ledCount == b.ledCount && a.rows == b.rows && a.cols == b.cols && a.cells == b.cells && a.names == b.names
    }

    public init(device: RGBDevice) {
        let count = device.leds.count
        var cells = [Cell?](repeating: nil, count: count)
        var rows = 0, cols = 0
        var zoneStart = 0
        for zone in device.zones {
            if let m = zone.matrix {
                // Stack multiple matrix zones vertically.
                for r in 0..<m.height {
                    for c in 0..<m.width {
                        if let led = m.led(row: r, col: c) {
                            let index = zoneStart + Int(led)
                            if index < count { cells[index] = Cell(row: rows + r, col: c) }
                        }
                    }
                }
                rows += m.height
                cols = max(cols, m.width)
            }
            zoneStart += Int(zone.ledsCount)
        }
        // LEDs outside a matrix (logos, light bars, or a device without a matrix) go on extra rows.
        let unplaced = cells.indices.filter { cells[$0] == nil }
        if !unplaced.isEmpty {
            let width = max(cols, min(unplaced.count, 22))
            for (i, led) in unplaced.enumerated() {
                cells[led] = Cell(row: rows + i / width, col: i % width)
            }
            rows += (unplaced.count + width - 1) / width
            cols = width
        }
        self.init(cells: cells, rows: rows, cols: cols, names: device.leds.map(\.name))
    }

    public init(cells: [Cell?], rows: Int, cols: Int, names: [String]) {
        ledCount = cells.count
        self.rows = max(1, rows)
        self.cols = max(1, cols)
        self.cells = cells
        self.names = names
        let rDen = Float(max(1, self.rows - 1)), cDen = Float(max(1, self.cols - 1))
        positions = cells.map { cell in
            guard let cell else { return (0.5, 0.5) }
            return (Float(cell.col) / cDen, Float(cell.row) / rDen)
        }
    }

    /// Simple rows×cols grid layout (preview before a device is connected, and tests).
    public static func grid(rows: Int, cols: Int) -> KeyboardLayout {
        var cells: [Cell?] = []
        for r in 0..<rows { for c in 0..<cols { cells.append(Cell(row: r, col: c)) } }
        return KeyboardLayout(cells: cells, rows: rows, cols: cols, names: cells.map { _ in "" })
    }

    /// A TKL-shaped placeholder (6×17) used until the real map arrives.
    public static let placeholderTKL = grid(rows: 6, cols: 17)
}

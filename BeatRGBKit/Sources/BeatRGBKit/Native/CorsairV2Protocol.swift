import Foundation

/// Corsair "Peripheral V2" (Bragi) lighting protocol, as implemented by OpenRGB's
/// CorsairPeripheralV2Controller / CorsairPeripheralV2HWController (GPL-2.0-or-later,
/// https://gitlab.com/CalcProgrammer1/OpenRGB). Only the commands OpenRGB uses for Direct mode
/// on wired keyboards are implemented here — nothing is invented.
///
/// OpenRGB builds 65-byte hidapi buffers whose byte 0 is the report ID (0). On macOS the report
/// ID is stripped and 64 bytes are sent, so OpenRGB's `buffer[n]` is our `report[n - 1]`.
public enum CorsairV2Protocol {
    public static let vendorID = 0x1B1C
    public static let k70CoreTKLProductID = 0x2B01
    public static let usagePage = 0xFF42
    public static let commandUsage = 0x01
    public static let reportSize = 64

    public static let writeWired: UInt8 = 0x08

    public enum Command: UInt8 {
        case set = 0x01, get = 0x02, stopTransaction = 0x05, blockWriteFirst = 0x06, blockWriteNext = 0x07, startTransaction = 0x0D
    }

    public enum RenderMode: UInt8 { case hardware = 0x01, software = 0x02 }

    /// Lighting endpoint: 0x22 takes RGB triplets with a mode header; 0x01 takes R, G, B planes.
    public enum LightingEndpoint: UInt8 { case triplets = 0x22, colourBlocks = 0x01 }

    public static let valueMode: UInt8 = 0x03
    public static let propertyPID: UInt8 = 0x12
    public static let propertyLayout: UInt8 = 0x41
    public static let directModeValue: UInt16 = 0x0012
    public static let firstPacketDataOffset = 7      // OpenRGB offset1 = 8
    public static let nextPacketDataOffset = 3       // OpenRGB offset2 = 4

    static func report(_ bytes: [Int: UInt8]) -> [UInt8] {
        var r = [UInt8](repeating: 0, count: reportSize)
        r[0] = writeWired
        for (i, v) in bytes { r[i] = v }
        return r
    }

    /// GetAddress: buffer[2] = GET, buffer[3] = property.
    public static func get(_ property: UInt8) -> [UInt8] { report([1: Command.get.rawValue, 2: property]) }

    /// SetRenderMode: buffer[2] = SET, buffer[3] = VALUE_MODE, buffer[5] = mode.
    public static func setRenderMode(_ mode: RenderMode) -> [UInt8] {
        report([1: Command.set.rawValue, 2: valueMode, 4: mode.rawValue])
    }

    /// LightingControl(0x5F): a GET of property 0x5F issued after entering software mode.
    public static func lightingControl() -> [UInt8] { report([1: Command.get.rawValue, 2: 0x5F]) }

    public static func startTransaction(_ endpoint: LightingEndpoint) -> [UInt8] {
        report([1: Command.startTransaction.rawValue, 2: 0, 3: endpoint.rawValue])
    }

    public static func stopTransaction() -> [UInt8] {
        report([1: Command.stopTransaction.rawValue, 2: 0x01, 3: 0])
    }

    /// Response to a command: status in byte 2, value as little-endian u32 in bytes 3…6. Input reports
    /// carry no report-ID byte, so these are the same indices OpenRGB uses for its `read[]` buffer.
    public static func parseGet(_ response: [UInt8]) -> (status: UInt8, value: UInt32)? {
        guard response.count >= 7 else { return nil }
        let value = UInt32(response[3]) | UInt32(response[4]) << 8 | UInt32(response[5]) << 16 | UInt32(response[6]) << 24
        return (response[2], value)
    }

    /// Lays colours out in device slots (`slots[i]` = slot of LED i) in the endpoint's format.
    public static func payload(colors: [RGB8], slots: [Int], slotCount: Int, endpoint: LightingEndpoint) -> [UInt8] {
        switch endpoint {
        case .triplets:
            var p = [UInt8](repeating: 0, count: slotCount * 3 + 2)
            p[0] = UInt8(directModeValue & 0xFF)
            p[1] = UInt8(directModeValue >> 8)
            for (i, c) in colors.enumerated() where i < slots.count && slots[i] < slotCount {
                let o = 2 + slots[i] * 3
                p[o] = c.r; p[o + 1] = c.g; p[o + 2] = c.b
            }
            return p
        case .colourBlocks:
            var p = [UInt8](repeating: 0, count: slotCount * 3)
            for (i, c) in colors.enumerated() where i < slots.count && slots[i] < slotCount {
                p[slots[i]] = c.r
                p[slotCount + slots[i]] = c.g
                p[slotCount * 2 + slots[i]] = c.b
            }
            return p
        }
    }

    /// Software-mode key routing table, from OpenLinkHub's k70coretkl driver (GPL-3.0): every key keeps
    /// its normal HID function (0x39, modifiers 0x3F) and the remaining slots report to software (0x01).
    /// Without it the dial is silent in software mode; with it, dial turns arrive on the 0xFF42 usage 2
    /// interface as `00 05 60 00 <Int32 delta>` (confirmed on this keyboard 2026-10-30).
    public static let defaultKeyAssignment: [UInt8] = [
        0x01, 0x01, 0x01, 0x01, 0x39, 0x39, 0x39, 0x39, 0x39, 0x39, 0x39, 0x39, 0x39, 0x39, 0x39, 0x39,
        0x39, 0x39, 0x39, 0x39, 0x39, 0x39, 0x39, 0x39, 0x39, 0x39, 0x39, 0x39, 0x39, 0x39, 0x39, 0x39,
        0x39, 0x39, 0x39, 0x39, 0x39, 0x39, 0x39, 0x39, 0x39, 0x39, 0x39, 0x39, 0x39, 0x39, 0x39, 0x39,
        0x39, 0x39, 0x01, 0x39, 0x39, 0x39, 0x39, 0x39, 0x39, 0x39, 0x39, 0x39, 0x39, 0x39, 0x39, 0x39,
        0x39, 0x39, 0x39, 0x39, 0x39, 0x39, 0x01, 0x01, 0x01, 0x39, 0x39, 0x39, 0x39, 0x39, 0x39, 0x39,
        0x39, 0x39, 0x39, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
        0x01, 0x01, 0x01, 0x01, 0x01, 0x39, 0x01, 0x01, 0x01, 0x3F, 0x3F, 0x3F, 0x39, 0x3F, 0x3F, 0x3F,
        0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x3F, 0x01, 0x39
    ]

    /// OpenLinkHub's writeKeyAssignment: open endpoint 0x02 on handle 2, block-write the table with a
    /// 4-byte length header in 61-byte chunks (06 02 first, 07 02 after), then close.
    public static func keyAssignmentPackets(_ table: [UInt8] = defaultKeyAssignment) -> [[UInt8]] {
        var data: [UInt8] = [UInt8(table.count & 0xFF), UInt8(table.count >> 8), 0, 0] + table
        var packets = [report([1: Command.startTransaction.rawValue, 2: 0x02, 3: 0x02])]
        var first = true
        while !data.isEmpty {
            let chunk = Array(data.prefix(61))
            data.removeFirst(chunk.count)
            var r = report([1: first ? Command.blockWriteFirst.rawValue : Command.blockWriteNext.rawValue, 2: 0x02])
            r.replaceSubrange(3..<3 + chunk.count, with: chunk)
            packets.append(r)
            first = false
        }
        packets.append(report([1: Command.stopTransaction.rawValue, 2: 0x01, 3: 0x02]))
        return packets
    }

    /// SetLEDs block write: first packet carries the total size and 57 data bytes, each following
    /// packet 61 bytes (the tail of the last one zero-filled).
    public static func blockWritePackets(_ data: [UInt8]) -> [[UInt8]] {
        var packets: [[UInt8]] = []
        var first = report([1: Command.blockWriteFirst.rawValue, 3: UInt8(data.count & 0xFF), 4: UInt8(data.count >> 8)])
        let firstCount = min(data.count, reportSize - firstPacketDataOffset)
        first.replaceSubrange(firstPacketDataOffset..<firstPacketDataOffset + firstCount, with: data[0..<firstCount])
        packets.append(first)
        var index = firstCount
        // OpenRGB reuses its buffer, so bytes 2…3 (size) stay as in the first packet.
        var next = first
        next[1] = Command.blockWriteNext.rawValue
        let chunk = reportSize - nextPacketDataOffset
        while index < data.count {
            let n = min(chunk, data.count - index)
            for i in nextPacketDataOffset..<reportSize { next[i] = 0 }
            next.replaceSubrange(nextPacketDataOffset..<nextPacketDataOffset + n, with: data[index..<index + n])
            packets.append(next)
            index += n
        }
        return packets
    }
}

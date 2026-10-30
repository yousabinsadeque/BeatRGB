import Foundation

public enum ByteReaderError: Error, Equatable {
    case outOfBounds(offset: Int, needed: Int, size: Int)
    case invalidString
}

/// Little-endian reader over OpenRGB SDK payloads.
public struct ByteReader {
    public let data: [UInt8]
    public private(set) var offset: Int = 0

    public init(_ data: [UInt8]) { self.data = data }
    public init(_ data: Data) { self.data = [UInt8](data) }

    public var remaining: Int { data.count - offset }

    private mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        guard n >= 0, offset + n <= data.count else {
            throw ByteReaderError.outOfBounds(offset: offset, needed: n, size: data.count)
        }
        defer { offset += n }
        return data[offset..<offset + n]
    }

    public mutating func u8() throws -> UInt8 { try take(1).first! }

    public mutating func u16() throws -> UInt16 {
        let b = try take(2)
        return UInt16(b[b.startIndex]) | UInt16(b[b.startIndex + 1]) << 8
    }

    public mutating func u32() throws -> UInt32 {
        let b = try take(4)
        var v: UInt32 = 0
        for (i, byte) in b.enumerated() { v |= UInt32(byte) << (8 * UInt32(i)) }
        return v
    }

    public mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }

    /// OpenRGB string: u16 length (including NUL) followed by bytes.
    public mutating func string() throws -> String {
        let n = Int(try u16())
        let bytes = try take(n)
        let trimmed = bytes.prefix { $0 != 0 }
        return String(decoding: trimmed, as: UTF8.self)
    }

    public mutating func skip(_ n: Int) throws { _ = try take(n) }
}

public struct ByteWriter {
    public private(set) var bytes: [UInt8] = []
    public init() {}

    public mutating func u8(_ v: UInt8) { bytes.append(v) }
    public mutating func u16(_ v: UInt16) { bytes.append(UInt8(v & 0xFF)); bytes.append(UInt8(v >> 8)) }
    public mutating func u32(_ v: UInt32) { for i in 0..<4 { bytes.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
    public mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    public mutating func string(_ s: String) {
        let utf8 = Array(s.utf8)
        u16(UInt16(utf8.count + 1))
        bytes.append(contentsOf: utf8)
        bytes.append(0)
    }
    public mutating func append(_ other: [UInt8]) { bytes.append(contentsOf: other) }
}

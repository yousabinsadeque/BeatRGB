import Foundation

/// Constants for the OpenRGB SDK network protocol.
///
/// Verified against OpenRGB's NetworkServer.cpp / RGBController.cpp (server protocol 6 build
/// installed on this Mac). BeatRGB negotiates at most version 5: in v5 the device index in the
/// packet header is a plain controller index and the server sends no ACK packets, which keeps the
/// client compatible with OpenRGB 0.9 (v4), 1.0rc (v5) and newer servers (v6+, which downgrade).
public enum OpenRGBProtocol {
    public static let magic: [UInt8] = Array("ORGB".utf8)
    public static let headerSize = 16
    public static let maxClientVersion: UInt32 = 5
    public static let defaultPort: UInt16 = 6742

    public enum PacketID: UInt32 {
        case requestControllerCount = 0
        case requestControllerData = 1
        case requestProtocolVersion = 40
        case setClientName = 50
        case deviceListUpdated = 100
        case resizeZone = 1000
        case updateLEDs = 1050
        case updateZoneLEDs = 1051
        case updateSingleLED = 1052
        case setCustomMode = 1100
        case updateMode = 1101
        case saveMode = 1102
    }

    public struct Header: Equatable {
        public var deviceIndex: UInt32
        public var packetID: UInt32
        public var size: UInt32

        public init(deviceIndex: UInt32, packetID: UInt32, size: UInt32) {
            self.deviceIndex = deviceIndex
            self.packetID = packetID
            self.size = size
        }

        public static func decode(_ bytes: [UInt8]) throws -> Header {
            guard bytes.count >= headerSize, Array(bytes[0..<4]) == magic else {
                throw OpenRGBError.badMagic
            }
            var r = ByteReader(Array(bytes[4..<16]))
            return Header(deviceIndex: try r.u32(), packetID: try r.u32(), size: try r.u32())
        }
    }

    public static func packet(device: UInt32 = 0, id: PacketID, payload: [UInt8] = []) -> [UInt8] {
        var w = ByteWriter()
        w.append(magic)
        w.u32(device)
        w.u32(id.rawValue)
        w.u32(UInt32(payload.count))
        w.append(payload)
        return w.bytes
    }

    /// Payload for RGBCONTROLLER_UPDATELEDS: u32 data size, u16 count, count × (r,g,b,pad).
    public static func updateLEDsPayload(_ colors: [RGB8]) -> [UInt8] {
        var w = ByteWriter()
        w.u32(UInt32(4 + 2 + colors.count * 4))
        w.u16(UInt16(colors.count))
        for c in colors { w.u8(c.r); w.u8(c.g); w.u8(c.b); w.u8(0) }
        return w.bytes
    }
}

public enum OpenRGBError: Error, Equatable, CustomStringConvertible {
    case badMagic
    case notConnected
    case connectFailed(String)
    case timeout
    case closed
    case io(String)
    case malformed(String)
    case deviceNotFound
    case noDirectMode
    case directModeRejected(String)

    public var description: String {
        switch self {
        case .badMagic: return "Received a packet without the ORGB magic header."
        case .notConnected: return "Not connected to the OpenRGB SDK server."
        case .connectFailed(let s): return "Could not connect to OpenRGB SDK server: \(s)"
        case .timeout: return "OpenRGB SDK server did not respond in time."
        case .closed: return "OpenRGB closed the connection."
        case .io(let s): return "Socket error: \(s)"
        case .malformed(let s): return "Malformed controller data: \(s)"
        case .deviceNotFound: return "The keyboard is no longer reported by OpenRGB."
        case .noDirectMode: return "The keyboard does not expose a Direct mode in OpenRGB."
        case .directModeRejected(let s): return "OpenRGB did not switch the keyboard to Direct mode (active: \(s))."
        }
    }
}

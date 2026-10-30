import Foundation

public struct RGB8: Equatable, Hashable, Codable, Sendable {
    public var r: UInt8, g: UInt8, b: UInt8
    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }
    public static let black = RGB8(0, 0, 0)
}

public struct RGBMode: Equatable, Sendable {
    public var name: String
    public var value: Int32
    public var flags: UInt32
    public var speedMin: UInt32, speedMax: UInt32
    public var brightnessMin: UInt32, brightnessMax: UInt32
    public var colorsMin: UInt32, colorsMax: UInt32
    public var speed: UInt32, brightness: UInt32, direction: UInt32
    public var colorMode: UInt32
    public var colors: [RGB8]

    public init(name: String, value: Int32 = 0, flags: UInt32 = 0, speedMin: UInt32 = 0, speedMax: UInt32 = 0,
                brightnessMin: UInt32 = 0, brightnessMax: UInt32 = 0, colorsMin: UInt32 = 0, colorsMax: UInt32 = 0,
                speed: UInt32 = 0, brightness: UInt32 = 0, direction: UInt32 = 0, colorMode: UInt32 = 0, colors: [RGB8] = []) {
        self.name = name; self.value = value; self.flags = flags
        self.speedMin = speedMin; self.speedMax = speedMax
        self.brightnessMin = brightnessMin; self.brightnessMax = brightnessMax
        self.colorsMin = colorsMin; self.colorsMax = colorsMax
        self.speed = speed; self.brightness = brightness; self.direction = direction
        self.colorMode = colorMode; self.colors = colors
    }

    /// OpenRGB names the software-controlled per-LED mode "Direct" (older drivers: "Custom").
    public var isDirect: Bool {
        let n = name.lowercased()
        return n == "direct" || n == "custom"
    }
}

public struct MatrixMap: Equatable, Sendable {
    public static let noLED: UInt32 = 0xFFFF_FFFF
    public var height: Int
    public var width: Int
    /// Row-major, zone-relative LED indices (or `noLED`).
    public var map: [UInt32]

    public init(height: Int, width: Int, map: [UInt32]) {
        self.height = height; self.width = width; self.map = map
    }

    public func led(row: Int, col: Int) -> UInt32? {
        let v = map[row * width + col]
        return v == MatrixMap.noLED ? nil : v
    }
}

public struct RGBSegment: Equatable, Sendable {
    public var name: String
    public var type: Int32
    public var startIndex: UInt32
    public var count: UInt32
}

public struct RGBZone: Equatable, Sendable {
    public enum ZoneType: Int32 { case single = 0, linear = 1, matrix = 2 }
    public var name: String
    public var type: Int32
    public var ledsMin: UInt32, ledsMax: UInt32, ledsCount: UInt32
    public var matrix: MatrixMap?
    public var segments: [RGBSegment]
    public var flags: UInt32

    public init(name: String, type: Int32, ledsMin: UInt32, ledsMax: UInt32, ledsCount: UInt32,
                matrix: MatrixMap? = nil, segments: [RGBSegment] = [], flags: UInt32 = 0) {
        self.name = name; self.type = type
        self.ledsMin = ledsMin; self.ledsMax = ledsMax; self.ledsCount = ledsCount
        self.matrix = matrix; self.segments = segments; self.flags = flags
    }
}

public struct RGBLED: Equatable, Sendable {
    public var name: String
    public var value: UInt32
}

public struct RGBDevice: Equatable, Sendable {
    public var index: UInt32 = 0
    public var type: Int32
    public var name: String
    public var vendor: String
    public var description: String
    public var version: String
    public var serial: String
    public var location: String
    public var activeMode: Int32
    public var modes: [RGBMode]
    public var zones: [RGBZone]
    public var leds: [RGBLED]
    public var colors: [RGB8]
    public var ledAlternateNames: [String] = []
    public var flags: UInt32 = 0

    public static let typeKeyboard: Int32 = 5

    public var directModeIndex: Int? { modes.firstIndex { $0.isDirect } }
    public var activeModeName: String {
        modes.indices.contains(Int(activeMode)) ? modes[Int(activeMode)].name : "#\(activeMode)"
    }

    /// Stable identity used to make sure BeatRGB only ever drives the intended device.
    public var identity: DeviceIdentity { DeviceIdentity(name: name, vendor: vendor, serial: serial) }
}

public struct DeviceIdentity: Codable, Equatable, Hashable, Sendable {
    public var name: String
    public var vendor: String
    public var serial: String

    public init(name: String, vendor: String, serial: String) {
        self.name = name; self.vendor = vendor; self.serial = serial
    }
}

/// How BeatRGB picks its target among the controllers OpenRGB reports. Works with any keyboard
/// OpenRGB supports: a remembered serial wins, then a device the user picked by name, otherwise the
/// first keyboard that has a Direct (per-LED) mode.
public struct DeviceMatcher: Equatable, Sendable {
    /// Exact serial remembered from a previous session (preferred when present).
    public var serial: String?
    /// Exact device name the user picked; nil means automatic.
    public var name: String?

    public init(serial: String? = nil, name: String? = nil) {
        self.serial = serial; self.name = name
    }

    public static let automatic = DeviceMatcher()

    public func select(from devices: [RGBDevice]) -> RGBDevice? {
        if let serial, !serial.isEmpty { return devices.first { $0.serial == serial } }
        if let name, !name.isEmpty { return devices.first { $0.name == name } }
        let keyboards = devices.filter { $0.type == RGBDevice.typeKeyboard }
        return keyboards.first { $0.directModeIndex != nil } ?? keyboards.first
    }
}

import AppKit
import Foundation
import QuartzCore

public enum Backend: String, Codable, CaseIterable, Identifiable, Sendable {
    case openRGB, native
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .openRGB: return "OpenRGB — any RGB keyboard OpenRGB supports"
        case .native: return "Native USB — Corsair K70 CORE RGB TKL only"
        }
    }
}

/// What the engine knows about the keyboard it's driving.
public struct DriverDevice: Equatable, Sendable {
    public var name: String
    public var identity: DeviceIdentity
    public var layout: KeyboardLayout
    public var ledCount: Int
    public var mode: String
    public var modes: [String]
}

/// One way of putting colours on the keyboard. Confined to the engine queue.
public protocol KeyboardDriver: AnyObject {
    /// Human-readable connection description once open (e.g. protocol version or USB endpoint).
    var connectionInfo: String { get }
    var log: ((String) -> Void)? { get set }
    func open() throws -> DriverDevice
    func write(_ colors: [RGB8]) throws
    /// Returns true when the device must be re-opened (device list changed).
    func poll() throws -> Bool
    /// Called about once a second; returns a latency figure (ms) used for adaptive throttling.
    func periodicCheck() throws -> Double
    func finish(_ behavior: StopBehavior, idleFrame: [RGB8])
    func close()
}

// MARK: - OpenRGB

public final class OpenRGBDriver: KeyboardDriver {
    public var log: ((String) -> Void)?
    private let host: String
    private let port: UInt16
    private let matcher: DeviceMatcher
    private var client: OpenRGBClient?
    private var device: RGBDevice?
    private var originalColors: [String: [RGB8]] = [:]

    public init(host: String, port: UInt16, matcher: DeviceMatcher) {
        self.host = host; self.port = port; self.matcher = matcher
    }

    public var connectionInfo: String {
        guard let c = client, c.isConnected else { return "\(host):\(port)" }
        return "OpenRGB at \(host):\(port) · server protocol v\(c.serverProtocolVersion), using v\(c.protocolVersion)"
    }

    private func connectedClient() throws -> OpenRGBClient {
        if let client, client.isConnected { return client }
        let c = OpenRGBClient(host: host, port: port)
        try c.connect()
        client = c
        log?("Connected to OpenRGB SDK at \(host):\(port) (server v\(c.serverProtocolVersion), using v\(c.protocolVersion))")
        return c
    }

    public func open() throws -> DriverDevice {
        let c = try connectedClient()
        let devices = try c.allControllers()
        guard let found = matcher.select(from: devices) else {
            throw DriverError.deviceMissing(available: devices.map(\.name))
        }
        if originalColors[found.serial] == nil { originalColors[found.serial] = found.colors }
        let direct = try c.enableDirectMode(found)
        device = direct
        let layout = KeyboardLayout(device: direct)
        log?("Using \(direct.name) (index \(direct.index), \(direct.leds.count) LEDs, \(layout.rows)×\(layout.cols) map) in \(direct.activeModeName) mode")
        return DriverDevice(name: direct.name, identity: direct.identity, layout: layout, ledCount: direct.leds.count,
                            mode: direct.activeModeName, modes: direct.modes.map(\.name))
    }

    public func write(_ colors: [RGB8]) throws {
        guard let client, let device else { throw OpenRGBError.notConnected }
        try client.updateLEDs(device: device.index, colors: colors)
    }

    public func poll() throws -> Bool {
        guard let client else { throw OpenRGBError.notConnected }
        try client.pollNotifications()
        return client.deviceListChanged
    }

    /// Round-trips a controller-data request through OpenRGB's per-device queue: verifies identity
    /// and Direct mode, and its latency drives adaptive throttling.
    public func periodicCheck() throws -> Double {
        guard let client, let device else { throw OpenRGBError.notConnected }
        let t0 = CACurrentMediaTime()
        let current = try client.controller(at: device.index)
        let rtt = (CACurrentMediaTime() - t0) * 1000
        guard current.identity == device.identity else {
            throw DriverError.deviceChanged("Device at index \(device.index) changed identity")
        }
        if !current.modes.indices.contains(Int(current.activeMode)) || !current.modes[Int(current.activeMode)].isDirect {
            log?("Keyboard left Direct mode (now \(current.activeModeName)) — another app may be controlling it. Re-enabling.")
            self.device = try client.enableDirectMode(current)
        }
        return rtt
    }

    public func finish(_ behavior: StopBehavior, idleFrame: [RGB8]) {
        guard let client, client.isConnected, let device else { return }
        let colors: [RGB8]
        switch behavior {
        case .restorePrevious: colors = originalColors[device.serial] ?? Array(repeating: .black, count: device.leds.count)
        case .idleEffect: colors = idleFrame
        case .off: colors = Array(repeating: .black, count: device.leds.count)
        }
        guard colors.count == device.leds.count else { return }
        do {
            try client.updateLEDs(device: device.index, colors: colors)
            // Round-trip through OpenRGB's device queue so the frame is applied before we hang up.
            _ = try client.controller(at: device.index)
            log?("On stop: \(behavior.title.lowercased())")
        } catch {
            log?("Could not apply stop lighting: \(error)")
        }
    }

    public func close() {
        client?.disconnect()
        client = nil
        device = nil
    }

    public func scan() throws -> [RGBDevice] {
        defer { if device == nil { close() } }
        return try connectedClient().allControllers()
    }
}

public enum DriverError: Error, Equatable, CustomStringConvertible {
    case deviceMissing(available: [String])
    case deviceChanged(String)
    public var description: String {
        switch self {
        case .deviceMissing(let a):
            return "No matching RGB keyboard found" + (a.isEmpty ? " (OpenRGB reports no devices)." : ". Available: \(a.joined(separator: ", ")).")
        case .deviceChanged(let s): return s
        }
    }
}

// MARK: - Native USB

/// Drives the K70 CORE RGB TKL directly over USB HID with the Corsair Peripheral V2 protocol,
/// mirroring OpenRGB's CorsairPeripheralV2HWController step for step. No OpenRGB needed.
public final class NativeCorsairDriver: KeyboardDriver {
    public var log: ((String) -> Void)?
    public var otherSoftwareCheck: () -> String? = NativeCorsairDriver.conflictingApp
    public var pace: TimeInterval = 0.002          // OpenRGB CORSAIR_V2_WRITE_PACE
    private let makeTransport: () throws -> HIDTransport
    private var transport: HIDTransport?
    private var endpoint = CorsairV2Protocol.LightingEndpoint.triplets
    private var lastWriteMs: Double = 0
    /// Keyboard acknowledgements: frames whose stop-transaction reply carried an error status.
    public private(set) var acknowledgedFrames = 0
    public private(set) var rejectedFrames = 0
    private let ledMap: LEDMap

    /// LED → device slot mapping and physical layout for the K70 CORE RGB TKL (ANSI), taken from the
    /// controller description OpenRGB reported for this keyboard (bundled resource).
    public struct LEDMap: Sendable {
        public var names: [String]
        public var slots: [Int]
        public var slotCount: Int
        public var layout: KeyboardLayout

        public static func k70CoreTKL() throws -> LEDMap {
            guard let url = Bundle.module.url(forResource: "k70-core-tkl", withExtension: "bin") else {
                throw NativeHIDError.notFound
            }
            let d = try DeviceDescription.parse([UInt8](try Data(contentsOf: url)), protocolVersion: 5)
            let slots = d.leds.map { Int($0.value) }
            return LEDMap(names: d.leds.map(\.name), slots: slots, slotCount: (slots.max() ?? 0) + 1,
                          layout: KeyboardLayout(device: d))
        }
    }

    public init(ledMap: LEDMap, makeTransport: @escaping () throws -> HIDTransport = { try IOKitHIDTransport.open() }) {
        self.ledMap = ledMap
        self.makeTransport = makeTransport
    }

    public var connectionInfo: String {
        guard transport != nil else { return "USB 1B1C:2B01" }
        return String(format: "USB HID 1B1C:2B01 · endpoint 0x%02X · %d frames acknowledged, %d rejected",
                      endpoint.rawValue, acknowledgedFrames, rejectedFrames)
    }

    static func conflictingApp() -> String? {
        let names = NSWorkspace.shared.runningApplications.compactMap { $0.localizedName ?? $0.executableURL?.lastPathComponent }
        return names.first { $0.lowercased().hasPrefix("openrgb") }.map { _ in "OpenRGB" }
    }

    @discardableResult
    private func command(_ report: [UInt8], timeout: TimeInterval = 0.05) throws -> [UInt8]? {
        guard let t = transport else { throw NativeHIDError.notFound }
        try t.write(report)
        return t.read(timeout: timeout)
    }

    public func open() throws -> DriverDevice {
        close()
        if let app = otherSoftwareCheck() { throw NativeHIDError.otherSoftwareRunning(app) }
        let t = try makeTransport()
        transport = t
        do {
            // 1. Identify: property 0x12 is the product ID (retried like OpenRGB's GetAddressRetry).
            var pid: UInt32 = 0
            for attempt in 0..<8 {
                if let r = try command(CorsairV2Protocol.get(CorsairV2Protocol.propertyPID)),
                   let parsed = CorsairV2Protocol.parseGet(r), parsed.status == 0, parsed.value != 0 {
                    pid = parsed.value
                    break
                }
                if attempt < 7 { Thread.sleep(forTimeInterval: 0.12) }
            }
            guard pid == UInt32(CorsairV2Protocol.k70CoreTKLProductID) else { throw NativeHIDError.unexpectedDevice(pid) }
            try command(CorsairV2Protocol.get(0x11))

            // 2. Lighting endpoint: try 0x22; a non-zero status means fall back to 0x01.
            endpoint = .triplets
            let status = try command(CorsairV2Protocol.startTransaction(.triplets)).map { $0.count > 2 ? $0[2] : 0 } ?? 0
            if status > 0 {
                endpoint = .colourBlocks
                try command(CorsairV2Protocol.startTransaction(.colourBlocks))
            }
            try command(CorsairV2Protocol.stopTransaction())

            // 3. Software (Direct) render mode, as OpenRGB's HW controller constructor does.
            let layoutValue = try command(CorsairV2Protocol.get(CorsairV2Protocol.propertyLayout)).flatMap(CorsairV2Protocol.parseGet)?.value
            try command(CorsairV2Protocol.setRenderMode(.software))
            try command(CorsairV2Protocol.lightingControl())
            // 4. Key routing table so the volume dial keeps reporting in software mode.
            for packet in CorsairV2Protocol.keyAssignmentPackets() { try command(packet) }
            log?(String(format: "Native USB: K70 CORE RGB TKL (PID 0x%04X), lighting endpoint 0x%02X, layout id %@, software mode on, dial routing set",
                        pid, endpoint.rawValue, layoutValue.map { String($0) } ?? "?"))
        } catch {
            close()
            throw error
        }
        return DriverDevice(name: "Corsair K70 CORE RGB TKL", identity: DeviceIdentity(name: "Corsair K70 CORE RGB TKL", vendor: "Corsair", serial: t.serialNumber),
                            layout: ledMap.layout, ledCount: ledMap.slots.count, mode: "Direct (software)", modes: ["Direct (software)", "Hardware (on-board)"])
    }

    public func write(_ colors: [RGB8]) throws {
        guard let t = transport else { throw NativeHIDError.notFound }
        let t0 = CACurrentMediaTime()
        let data = CorsairV2Protocol.payload(colors: colors, slots: ledMap.slots, slotCount: ledMap.slotCount, endpoint: endpoint)
        let packets = CorsairV2Protocol.blockWritePackets(data)
        t.drain()
        try command(CorsairV2Protocol.startTransaction(endpoint))
        try t.write(packets[0])
        if t.read(timeout: 0.003) == nil { Thread.sleep(forTimeInterval: pace) }
        for p in packets.dropFirst() {
            try t.write(p)
            Thread.sleep(forTimeInterval: pace)
        }
        let ack = try command(CorsairV2Protocol.stopTransaction())
        lastWriteMs = (CACurrentMediaTime() - t0) * 1000
        if let ack, ack.count > 2 {
            if ack[2] == 0 {
                acknowledgedFrames += 1
            } else {
                rejectedFrames += 1
                if rejectedFrames == 1 { log?("Keyboard rejected a frame (status \(ack[2])); check that no other app is driving it") }
            }
        }
    }

    public func poll() throws -> Bool { false }

    public func periodicCheck() throws -> Double { lastWriteMs }

    public func finish(_ behavior: StopBehavior, idleFrame: [RGB8]) {
        guard transport != nil else { return }
        do {
            switch behavior {
            case .restorePrevious:
                // Hand lighting back to the keyboard's own on-board effect (OpenRGB does this on exit).
                try command(CorsairV2Protocol.setRenderMode(.hardware))
                log?("On stop: keyboard returned to its on-board lighting")
            case .idleEffect:
                try write(idleFrame)
                log?("On stop: show idle colour")
            case .off:
                try write(Array(repeating: .black, count: ledMap.slots.count))
                log?("On stop: lights off")
            }
        } catch {
            log?("Could not apply stop lighting: \(error)")
        }
    }

    public func close() {
        transport?.close()
        transport = nil
    }
}

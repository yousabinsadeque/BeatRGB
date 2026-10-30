import Darwin
import Foundation
import Testing
@testable import BeatRGBKit

/// Minimal in-process OpenRGB SDK server that speaks the same framing as the real one.
final class FakeOpenRGBServer: @unchecked Sendable {
    let port: UInt16
    private let listenFD: Int32
    private let lock = NSLock()
    private var _devices: [RGBDevice]
    private var _lastUpdate: [RGB8] = []
    private var _clientName = ""
    var serverVersion: UInt32 = 6
    var notifyDeviceListOnce = false

    var devices: [RGBDevice] { lock.withLock { _devices } }
    var lastUpdate: [RGB8] { lock.withLock { _lastUpdate } }
    var clientName: String { lock.withLock { _clientName } }

    init(devices: [RGBDevice]) throws {
        _devices = devices
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(fd, 4)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        listenFD = fd
        port = UInt16(bigEndian: addr.sin_port)
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    deinit { close(listenFD) }

    private func acceptLoop() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { return }
            Thread.detachNewThread { [self] in serve(fd) }
        }
    }

    private func readExact(_ fd: Int32, _ n: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: n)
        var got = 0
        while got < n {
            let r = buf.withUnsafeMutableBytes { recv(fd, $0.baseAddress! + got, n - got, 0) }
            if r <= 0 { return nil }
            got += r
        }
        return buf
    }

    private func reply(_ fd: Int32, dev: UInt32, id: OpenRGBProtocol.PacketID, _ payload: [UInt8]) {
        let p = OpenRGBProtocol.packet(device: dev, id: id, payload: payload)
        _ = p.withUnsafeBytes { send(fd, $0.baseAddress!, p.count, 0) }
    }

    private func serve(_ fd: Int32) {
        var version: UInt32 = 0
        defer { close(fd) }
        while let hb = readExact(fd, 16), let h = try? OpenRGBProtocol.Header.decode(hb) {
            let payload = h.size > 0 ? (readExact(fd, Int(h.size)) ?? []) : []
            switch OpenRGBProtocol.PacketID(rawValue: h.packetID) {
            case .requestProtocolVersion?:
                var r = ByteReader(payload)
                version = min(serverVersion, (try? r.u32()) ?? 0)
                var w = ByteWriter(); w.u32(serverVersion)
                reply(fd, dev: 0, id: .requestProtocolVersion, w.bytes)
            case .setClientName?:
                lock.withLock { _clientName = String(decoding: payload.prefix { $0 != 0 }, as: UTF8.self) }
            case .requestControllerCount?:
                if notifyDeviceListOnce { notifyDeviceListOnce = false; reply(fd, dev: 0, id: .deviceListUpdated, []) }
                var w = ByteWriter(); w.u32(UInt32(devices.count))
                reply(fd, dev: 0, id: .requestControllerCount, w.bytes)
            case .requestControllerData?:
                let d = devices[Int(h.deviceIndex)]
                reply(fd, dev: h.deviceIndex, id: .requestControllerData, DeviceDescription.encode(d, protocolVersion: version))
            case .setCustomMode?:
                lock.withLock {
                    if let i = _devices[Int(h.deviceIndex)].directModeIndex { _devices[Int(h.deviceIndex)].activeMode = Int32(i) }
                }
            case .updateLEDs?:
                var r = ByteReader(payload)
                _ = try? r.u32()
                let n = Int((try? r.u16()) ?? 0)
                let colors = (0..<n).compactMap { _ -> RGB8? in
                    guard let c = try? RGB8(r.u8(), r.u8(), r.u8()) else { return nil }
                    _ = try? r.u8(); return c
                }
                lock.withLock {
                    _lastUpdate = colors
                    _devices[Int(h.deviceIndex)].colors = colors
                }
            default:
                break
            }
        }
    }
}

@Suite(.serialized) struct ClientTests {
    func k70() throws -> RGBDevice {
        var d = try DeviceDescription.parse(try fixture(5), protocolVersion: 5)
        d.activeMode = 1  // start in Static so we can see the switch to Direct
        return d
    }

    func mouse() -> RGBDevice {
        RGBDevice(type: 6, name: "Other Mouse", vendor: "Acme", description: "", version: "", serial: "M1", location: "",
                  activeMode: 0, modes: [RGBMode(name: "Direct")], zones: [], leds: [RGBLED(name: "Logo", value: 0)], colors: [.black])
    }

    @Test func negotiatesDownToVersion5() throws {
        let server = try FakeOpenRGBServer(devices: [])
        let c = OpenRGBClient(port: server.port)
        try c.connect()
        #expect(c.serverProtocolVersion == 6)
        #expect(c.protocolVersion == 5)
        Thread.sleep(forTimeInterval: 0.05)
        #expect(server.clientName == "BeatRGB")
    }

    @Test func olderServerVersionIsUsed() throws {
        let server = try FakeOpenRGBServer(devices: [try k70()])
        server.serverVersion = 3
        let c = OpenRGBClient(port: server.port)
        try c.connect()
        #expect(c.protocolVersion == 3)
        #expect(try c.controller(at: 0).name == "Corsair K70 Core RGB TKL")
    }

    @Test func enumeratesAndTargetsOnlyTheKeyboard() throws {
        let server = try FakeOpenRGBServer(devices: [mouse(), try k70()])
        let c = OpenRGBClient(port: server.port)
        try c.connect()
        let all = try c.allControllers()
        #expect(all.count == 2)
        let kb = try #require(DeviceMatcher.automatic.select(from: all))
        #expect(kb.index == 1)
        let direct = try c.enableDirectMode(kb)
        #expect(direct.activeModeName == "Direct")
        let colors = Array(repeating: RGB8(0, 255, 0), count: 86)
        try c.updateLEDs(device: kb.index, colors: colors)
        _ = try c.controller(at: kb.index)  // round trip ensures the update was processed
        #expect(server.lastUpdate == colors)
        #expect(server.devices[0].colors == [.black])  // mouse untouched
    }

    @Test func directModeMissingIsReported() throws {
        var d = try k70()
        d.modes = d.modes.filter { !$0.isDirect }
        d.activeMode = 0
        let server = try FakeOpenRGBServer(devices: [d])
        let c = OpenRGBClient(port: server.port)
        try c.connect()
        #expect(throws: OpenRGBError.noDirectMode) { try c.enableDirectMode(try c.controller(at: 0)) }
    }

    @Test func deviceListUpdatedIsNoticed() throws {
        let server = try FakeOpenRGBServer(devices: [try k70()])
        server.notifyDeviceListOnce = true
        let c = OpenRGBClient(port: server.port)
        try c.connect()
        #expect(try c.controllerCount() == 1)
        #expect(c.deviceListChanged)
    }

    @Test func connectionRefusedIsReported() {
        let c = OpenRGBClient(port: 1)
        #expect(throws: OpenRGBError.self) { try c.connect(timeout: 0.5) }
        #expect(!c.isConnected)
    }

    @Test func engineDrivesDeviceEndToEnd() async throws {
        let server = try FakeOpenRGBServer(devices: [mouse(), try k70()])
        let engine = LightingEngine()
        var cfg = EngineConfig(); cfg.port = server.port; cfg.stopBehavior = .off
        engine.configure(cfg)
        var s = LightingSettings(); s.effect = .staticColor; s.primaryColor = ColorValue(hex: 0x0000FF); s.brightness = 1
        engine.update(settings: s)
        engine.start()
        try await Task.sleep(for: .milliseconds(500))
        #expect(server.devices[1].activeMode == Int32(server.devices[1].directModeIndex!))
        #expect(server.lastUpdate.count == 86)
        #expect(server.lastUpdate.allSatisfy { $0 == RGB8(0, 0, 255) })
        await withCheckedContinuation { cont in engine.stop { cont.resume() } }
        #expect(server.lastUpdate.allSatisfy { $0 == .black })   // stop behaviour "off"
        #expect(server.devices[0].colors == [.black])
    }
}

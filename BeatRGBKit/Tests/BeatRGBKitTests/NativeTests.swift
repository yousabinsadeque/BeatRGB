import Foundation
import Testing
@testable import BeatRGBKit

/// Records reports and answers like a Corsair V2 keyboard: [0x00, cmd, status, value LE…].
final class MockKeyboard: HIDTransport {
    var written: [[UInt8]] = []
    var pid: UInt32 = 0x2B01
    var rejectTriplets = false
    var failWrites = false
    var drains = 0
    private var responses: [[UInt8]] = []
    let serialNumber = "MOCK123"

    func write(_ r: [UInt8]) throws {
        if failWrites { throw NativeHIDError.writeFailed(-1) }
        written.append(r)
        let cmd = r[1]
        var resp = [UInt8](repeating: 0, count: 64)
        resp[1] = cmd
        if cmd == CorsairV2Protocol.Command.get.rawValue && r[2] == CorsairV2Protocol.propertyPID {
            resp[3] = UInt8(pid & 0xFF); resp[4] = UInt8(pid >> 8)
        }
        if cmd == CorsairV2Protocol.Command.startTransaction.rawValue && r[3] == 0x22 && rejectTriplets { resp[2] = 5 }
        if cmd != CorsairV2Protocol.Command.blockWriteNext.rawValue { responses.append(resp) }
    }

    func read(timeout: TimeInterval) -> [UInt8]? { responses.isEmpty ? nil : responses.removeFirst() }
    func drain() { drains += 1; responses.removeAll() }
    func close() {}
}

@Suite struct CorsairV2ProtocolTests {
    @Test func commandReportsMatchOpenRGBLayout() {
        // OpenRGB buffer[n] → report[n-1]
        #expect(Array(CorsairV2Protocol.setRenderMode(.software).prefix(6)) == [0x08, 0x01, 0x03, 0x00, 0x02, 0x00])
        #expect(Array(CorsairV2Protocol.setRenderMode(.hardware).prefix(6)) == [0x08, 0x01, 0x03, 0x00, 0x01, 0x00])
        #expect(Array(CorsairV2Protocol.get(0x12).prefix(4)) == [0x08, 0x02, 0x12, 0x00])
        #expect(Array(CorsairV2Protocol.lightingControl().prefix(4)) == [0x08, 0x02, 0x5F, 0x00])
        #expect(Array(CorsairV2Protocol.startTransaction(.triplets).prefix(5)) == [0x08, 0x0D, 0x00, 0x22, 0x00])
        #expect(Array(CorsairV2Protocol.stopTransaction().prefix(5)) == [0x08, 0x05, 0x01, 0x00, 0x00])
        #expect(CorsairV2Protocol.get(0x12).count == 64)
    }

    @Test func keyAssignmentMatchesOpenLinkHubBytes() {
        // The exact packets that made the dial report in software mode on the real keyboard.
        let p = CorsairV2Protocol.keyAssignmentPackets()
        #expect(p.count == 5)
        #expect(Array(p[0].prefix(4)) == [0x08, 0x0D, 0x02, 0x02])
        #expect(Array(p[1].prefix(8)) == [0x08, 0x06, 0x02, 0x7D, 0x00, 0x00, 0x00, 0x01])
        #expect(Array(p[2].prefix(8)) == [0x08, 0x07, 0x02, 0x39, 0x39, 0x39, 0x39, 0x39])
        #expect(Array(p[3].prefix(8)) == [0x08, 0x07, 0x02, 0x01, 0x01, 0x01, 0x01, 0x3F])
        #expect(Array(p[4].prefix(4)) == [0x08, 0x05, 0x01, 0x02])
        #expect(p.allSatisfy { $0.count == 64 })
        #expect(CorsairV2Protocol.defaultKeyAssignment.count == 125)
    }

    @Test func parsesGetResponse() throws {
        var r = [UInt8](repeating: 0, count: 64); r[1] = 2; r[3] = 0x01; r[4] = 0x2B
        let p = try #require(CorsairV2Protocol.parseGet(r))
        #expect(p.status == 0 && p.value == 0x2B01)
    }

    @Test func tripletPayloadPlacesColoursBySlot() {
        let p = CorsairV2Protocol.payload(colors: [RGB8(1, 2, 3), RGB8(4, 5, 6)], slots: [3, 0], slotCount: 4, endpoint: .triplets)
        #expect(p.count == 14)
        #expect(Array(p[0..<2]) == [0x12, 0x00])
        #expect(Array(p[2..<5]) == [4, 5, 6])           // slot 0
        #expect(Array(p[11..<14]) == [1, 2, 3])         // slot 3
        #expect(Array(p[5..<11]) == [0, 0, 0, 0, 0, 0]) // unused slots dark
    }

    @Test func colourBlockPayloadUsesPlanes() {
        let p = CorsairV2Protocol.payload(colors: [RGB8(10, 20, 30)], slots: [1], slotCount: 3, endpoint: .colourBlocks)
        #expect(p == [0, 10, 0, 0, 20, 0, 0, 30, 0])
    }

    @Test func blockWriteSplitsLikeOpenRGB() {
        let data = (0..<371).map { UInt8($0 & 0xFF) }
        let packets = CorsairV2Protocol.blockWritePackets(data)
        #expect(packets.count == 7)                     // 57 + 6×61 ≥ 371
        #expect(packets.allSatisfy { $0.count == 64 })
        let first = packets[0]
        #expect(Array(first[0..<7]) == [0x08, 0x06, 0x00, UInt8(371 & 0xFF), UInt8(371 >> 8), 0, 0])
        #expect(Array(first[7...]) == Array(data[0..<57]))
        #expect(Array(packets[1][0..<3]) == [0x08, 0x07, 0x00])
        #expect(Array(packets[1][3...]) == Array(data[57..<118]))
        // Reassembling the data portions gives back the payload, zero-padded at the end.
        var joined = Array(first[7...])
        for p in packets.dropFirst() { joined += p[3...] }
        #expect(Array(joined.prefix(371)) == data)
        #expect(joined.dropFirst(371).allSatisfy { $0 == 0 })
    }

    @Test func bundledLayoutCoversAllKeys() throws {
        let map = try NativeCorsairDriver.LEDMap.k70CoreTKL()
        #expect(map.slots.count == 86)
        #expect(Set(map.slots).count == 86)
        #expect(map.slotCount == 123)
        #expect(map.names[0] == "Key: Escape" && map.slots[0] == 0x29)
        #expect(map.layout.rows == 6 && map.layout.cols == 17)
    }
}

@Suite struct NativeDriverTests {
    func driver(_ kb: MockKeyboard) throws -> NativeCorsairDriver {
        let d = NativeCorsairDriver(ledMap: try .k70CoreTKL(), makeTransport: { kb })
        d.otherSoftwareCheck = { nil }
        d.pace = 0
        return d
    }

    @Test func openFollowsOpenRGBSequence() throws {
        let kb = MockKeyboard()
        let d = try driver(kb)
        let dev = try d.open()
        #expect(dev.ledCount == 86)
        #expect(dev.identity.serial == "MOCK123")
        let cmds = kb.written.map { [$0[1], $0[2]] }
        #expect(cmds == [[0x02, 0x12], [0x02, 0x11], [0x0D, 0x00], [0x05, 0x01], [0x02, 0x41], [0x01, 0x03], [0x02, 0x5F],
                         [0x0D, 0x02], [0x06, 0x02], [0x07, 0x02], [0x07, 0x02], [0x05, 0x01]])
        #expect(kb.written[5][4] == 0x02)   // software render mode
        #expect(d.connectionInfo.contains("0x22"))
    }

    @Test func refusesUnexpectedProduct() throws {
        let kb = MockKeyboard(); kb.pid = 0x1B2D
        let d = try driver(kb)
        #expect(throws: NativeHIDError.unexpectedDevice(0x1B2D)) { try d.open() }
        #expect(!kb.written.contains { $0[1] == 0x01 })   // never switched render mode
    }

    @Test func refusesWhileOpenRGBRuns() throws {
        let kb = MockKeyboard()
        let d = try driver(kb)
        d.otherSoftwareCheck = { "OpenRGB" }
        #expect(throws: NativeHIDError.otherSoftwareRunning("OpenRGB")) { try d.open() }
        #expect(kb.written.isEmpty)
    }

    @Test func fallsBackToColourBlocksEndpoint() throws {
        let kb = MockKeyboard(); kb.rejectTriplets = true
        let d = try driver(kb)
        _ = try d.open()
        #expect(d.connectionInfo.contains("0x01"))
        kb.written.removeAll()
        try d.write(Array(repeating: RGB8(255, 0, 0), count: 86))
        #expect(kb.written.first.map { [$0[1], $0[3]] } == [0x0D, 0x01])
        let size = Int(kb.written[1][3]) | Int(kb.written[1][4]) << 8
        #expect(size == 123 * 3)
    }

    @Test func frameIsOneTransaction() throws {
        let kb = MockKeyboard()
        let d = try driver(kb)
        _ = try d.open()
        kb.written.removeAll()
        var colors = Array(repeating: RGB8.black, count: 86)
        colors[0] = RGB8(9, 8, 7)   // Escape → slot 0x29
        try d.write(colors)
        let ids = kb.written.map { $0[1] }
        #expect(ids == [0x0D, 0x06, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x05])
        var data = Array(kb.written[1][7...])
        for p in kb.written[2..<8] { data += p[3...] }
        #expect(Array(data[0..<2]) == [0x12, 0x00])
        #expect(Array(data[2 + 0x29 * 3 ..< 2 + 0x29 * 3 + 3]) == [9, 8, 7])
        #expect(kb.drains >= 1)
    }

    @Test func restoreReturnsToHardwareMode() throws {
        let kb = MockKeyboard()
        let d = try driver(kb)
        _ = try d.open()
        kb.written.removeAll()
        d.finish(.restorePrevious, idleFrame: [])
        #expect(kb.written.count == 1)
        #expect(Array(kb.written[0].prefix(5)) == [0x08, 0x01, 0x03, 0x00, 0x01])
    }

    @Test func writeFailureSurfaces() throws {
        let kb = MockKeyboard()
        let d = try driver(kb)
        _ = try d.open()
        kb.failWrites = true
        #expect(throws: NativeHIDError.self) { try d.write(Array(repeating: .black, count: 86)) }
    }

    @Test func engineDrivesNativeDriver() async throws {
        let kb = MockKeyboard()
        let engine = LightingEngine()
        engine.makeDriver = { _ in try self.driver(kb) }
        var cfg = EngineConfig(); cfg.backend = .native; cfg.stopBehavior = .restorePrevious
        engine.configure(cfg)
        var s = LightingSettings(); s.effect = .staticColor; s.primaryColor = ColorValue(hex: 0x00FF00); s.brightness = 1
        engine.update(settings: s)
        engine.start()
        try await Task.sleep(for: .milliseconds(400))
        await withCheckedContinuation { cont in engine.stop { cont.resume() } }
        // Reassemble the first frame's payload and check Escape (slot 0x29) is green.
        let start = try #require(kb.written.firstIndex { $0[1] == 0x06 && $0[2] == 0x00 })   // skip the key table
        var data = Array(kb.written[start][7...])
        for p in kb.written[(start + 1)...] {
            guard p[1] == 0x07 else { break }
            data += p[3...]
        }
        #expect(Array(data[2 + 0x29 * 3 ..< 2 + 0x29 * 3 + 3]) == [0, 255, 0])
        // Stopping hands lighting back to the keyboard's hardware mode.
        #expect(Array(kb.written.last!.prefix(5)) == [0x08, 0x01, 0x03, 0x00, 0x01])
    }
}

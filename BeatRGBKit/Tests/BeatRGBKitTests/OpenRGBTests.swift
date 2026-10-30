import Foundation
import Testing
@testable import BeatRGBKit

func fixture(_ version: Int) throws -> [UInt8] {
    let url = try #require(Bundle.module.url(forResource: "k70-core-tkl-v\(version)", withExtension: "bin", subdirectory: "Fixtures"))
    return [UInt8](try Data(contentsOf: url))
}

@Suite struct ProtocolTests {
    @Test func headerRoundTrip() throws {
        let pkt = OpenRGBProtocol.packet(device: 3, id: .updateLEDs, payload: [1, 2, 3])
        #expect(Array(pkt[0..<4]) == Array("ORGB".utf8))
        let h = try OpenRGBProtocol.Header.decode(Array(pkt[0..<16]))
        #expect(h == .init(deviceIndex: 3, packetID: 1050, size: 3))
        #expect(Array(pkt[16...]) == [1, 2, 3])
    }

    @Test func badMagicRejected() {
        #expect(throws: OpenRGBError.badMagic) { try OpenRGBProtocol.Header.decode(Array(repeating: 0, count: 16)) }
    }

    @Test func updateLEDsPayloadLayout() throws {
        let p = OpenRGBProtocol.updateLEDsPayload([RGB8(255, 0, 1), RGB8(2, 3, 4)])
        var r = ByteReader(p)
        #expect(try r.u32() == UInt32(p.count))
        #expect(try r.u16() == 2)
        #expect(Array(p[6...]) == [255, 0, 1, 0, 2, 3, 4, 0])
    }

    @Test func stringsIncludeNulTerminator() throws {
        var w = ByteWriter(); w.string("K70")
        #expect(w.bytes == [4, 0, 75, 55, 48, 0])
        var r = ByteReader(w.bytes)
        #expect(try r.string() == "K70")
        #expect(r.remaining == 0)
    }

    @Test func truncatedReadThrows() {
        var r = ByteReader([1, 2])
        #expect(throws: ByteReaderError.self) { try r.u32() }
    }
}

@Suite struct DeviceDescriptionTests {
    @Test(arguments: [4, 5]) func parsesRealK70Payload(version: Int) throws {
        let d = try DeviceDescription.parse(try fixture(version), protocolVersion: UInt32(version))
        #expect(d.name == "Corsair K70 Core RGB TKL")
        #expect(d.vendor == "Corsair")
        #expect(d.type == RGBDevice.typeKeyboard)
        #expect(d.leds.count == 86)
        #expect(d.colors.count == 86)
        #expect(d.modes.map(\.name).contains("Direct"))
        #expect(d.directModeIndex != nil)
        let zone = try #require(d.zones.first)
        #expect(zone.matrix?.height == 6 && zone.matrix?.width == 17)
        #expect(d.leds.first?.name == "Key: Escape")
    }

    @Test(arguments: [4, 5]) func realPayloadReencodesIdentically(version: Int) throws {
        let raw = try fixture(version)
        let d = try DeviceDescription.parse(raw, protocolVersion: UInt32(version))
        #expect(DeviceDescription.encode(d, protocolVersion: UInt32(version)) == raw)
    }

    @Test(arguments: [0, 1, 2, 3, 4, 5]) func roundTripsAllVersions(version: Int) throws {
        var d = try DeviceDescription.parse(try fixture(5), protocolVersion: 5)
        if version < 1 { d.vendor = "" }
        if version < 3 { for i in d.modes.indices { d.modes[i].brightnessMin = 0; d.modes[i].brightnessMax = 0; d.modes[i].brightness = 0 } }
        if version < 4 { for i in d.zones.indices { d.zones[i].segments = [] } }
        if version < 5 { d.ledAlternateNames = []; d.flags = 0; for i in d.zones.indices { d.zones[i].flags = 0 } }
        let bytes = DeviceDescription.encode(d, protocolVersion: UInt32(version))
        #expect(try DeviceDescription.parse(bytes, protocolVersion: UInt32(version)) == d)
    }

    @Test func rejectsSizeMismatch() throws {
        var raw = try fixture(5)
        raw.removeLast()
        #expect(throws: OpenRGBError.self) { try DeviceDescription.parse(raw, protocolVersion: 5) }
    }

    @Test func rejectsWrongVersion() throws {
        // A v5 payload parsed as v3 must fail loudly rather than yield garbage.
        #expect(throws: OpenRGBError.self) { try DeviceDescription.parse(try fixture(5), protocolVersion: 3) }
    }
}

@Suite struct MatcherAndLayoutTests {
    func device(_ name: String, vendor: String = "Corsair", serial: String = "S") -> RGBDevice {
        RGBDevice(type: 5, name: name, vendor: vendor, description: "", version: "", serial: serial, location: "",
                  activeMode: 0, modes: [RGBMode(name: "Direct")], zones: [], leds: [], colors: [])
    }

    @Test func automaticPicksFirstKeyboardWithDirectMode() {
        var mouse = device("Logitech G502", vendor: "Logitech"); mouse.type = 6
        var noDirect = device("Razer Huntsman", vendor: "Razer"); noDirect.modes = [RGBMode(name: "Static")]
        let list = [mouse, noDirect, device("SteelSeries Apex 7", vendor: "SteelSeries", serial: "ABC")]
        #expect(DeviceMatcher.automatic.select(from: list)?.serial == "ABC")
        #expect(DeviceMatcher.automatic.select(from: [mouse, noDirect])?.name == "Razer Huntsman")
        #expect(DeviceMatcher.automatic.select(from: [mouse]) == nil)
    }

    @Test func pickedNameSelectsAnyDevice() {
        var mouse = device("Logitech G502", vendor: "Logitech"); mouse.type = 6
        let m = DeviceMatcher(name: "Logitech G502")
        #expect(m.select(from: [device("Corsair K70 Core RGB TKL"), mouse])?.name == "Logitech G502")
        #expect(m.select(from: [device("Corsair K70 Core RGB TKL")]) == nil)
    }

    @Test func serialTakesPrecedence() {
        let m = DeviceMatcher(serial: "XYZ", name: "Corsair K70 Core RGB TKL")
        #expect(m.select(from: [device("Corsair K70 Core RGB TKL", serial: "ABC"), device("Other", serial: "XYZ")])?.name == "Other")
    }

    @Test func layoutFromRealMatrix() throws {
        let d = try DeviceDescription.parse(try fixture(5), protocolVersion: 5)
        let layout = KeyboardLayout(device: d)
        #expect(layout.ledCount == 86)
        #expect(layout.rows == 6 && layout.cols == 17)
        #expect(layout.cells.allSatisfy { $0 != nil })
        #expect(layout.cells[0] == .init(row: 0, col: 0))          // Escape top-left
        let arrow = try #require(d.leds.firstIndex { $0.name == "Key: Right Arrow" })
        #expect(layout.positions[arrow].x == 1 && layout.positions[arrow].y == 1)  // bottom-right
    }

    @Test func layoutPlacesLEDsWithoutMatrix() {
        var d = device("Strip")
        d.leds = (0..<5).map { RGBLED(name: "LED \($0)", value: 0) }
        d.zones = [RGBZone(name: "Strip", type: 1, ledsMin: 5, ledsMax: 5, ledsCount: 5)]
        let l = KeyboardLayout(device: d)
        #expect(l.rows == 1 && l.cols == 5)
        #expect(l.positions.map(\.x) == [0, 0.25, 0.5, 0.75, 1])
    }
}

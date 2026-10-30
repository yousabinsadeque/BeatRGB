import Foundation

/// Decodes/encodes the REQUEST_CONTROLLER_DATA payload, following
/// RGBController::GetDeviceDescriptionData for protocol versions 0–5.
public enum DeviceDescription {
    public static func parse(_ payload: [UInt8], protocolVersion v: UInt32) throws -> RGBDevice {
        var r = ByteReader(payload)
        do {
            let declared = try r.u32()
            guard declared == payload.count else {
                throw OpenRGBError.malformed("declared size \(declared) ≠ payload \(payload.count)")
            }
            let type = try r.i32()
            let name = try r.string()
            let vendor = v >= 1 ? try r.string() : ""
            let description = try r.string()
            let version = try r.string()
            let serial = try r.string()
            let location = try r.string()

            let modeCount = Int(try r.u16())
            let activeMode = try r.i32()
            var modes: [RGBMode] = []
            modes.reserveCapacity(modeCount)
            for _ in 0..<modeCount {
                var m = RGBMode(name: try r.string())
                m.value = try r.i32()
                m.flags = try r.u32()
                m.speedMin = try r.u32()
                m.speedMax = try r.u32()
                if v >= 3 { m.brightnessMin = try r.u32(); m.brightnessMax = try r.u32() }
                m.colorsMin = try r.u32()
                m.colorsMax = try r.u32()
                m.speed = try r.u32()
                if v >= 3 { m.brightness = try r.u32() }
                m.direction = try r.u32()
                m.colorMode = try r.u32()
                let n = Int(try r.u16())
                m.colors = try (0..<n).map { _ in try readColor(&r) }
                modes.append(m)
            }

            let zoneCount = Int(try r.u16())
            var zones: [RGBZone] = []
            for _ in 0..<zoneCount {
                let zname = try r.string()
                let ztype = try r.i32()
                let lmin = try r.u32(), lmax = try r.u32(), lcount = try r.u32()
                let matrixSize = Int(try r.u16())
                var matrix: MatrixMap?
                if matrixSize > 0 {
                    let h = Int(try r.u32()), w = Int(try r.u32())
                    guard h * w * 4 + 8 == matrixSize else {
                        throw OpenRGBError.malformed("matrix \(h)x\(w) does not fit \(matrixSize) bytes")
                    }
                    matrix = MatrixMap(height: h, width: w, map: try (0..<(h * w)).map { _ in try r.u32() })
                }
                var segments: [RGBSegment] = []
                if v >= 4 {
                    let sc = Int(try r.u16())
                    for _ in 0..<sc {
                        segments.append(RGBSegment(name: try r.string(), type: try r.i32(),
                                                   startIndex: try r.u32(), count: try r.u32()))
                    }
                }
                let zflags = v >= 5 ? try r.u32() : 0
                zones.append(RGBZone(name: zname, type: ztype, ledsMin: lmin, ledsMax: lmax, ledsCount: lcount,
                                     matrix: matrix, segments: segments, flags: zflags))
            }

            let ledCount = Int(try r.u16())
            let leds = try (0..<ledCount).map { _ in RGBLED(name: try r.string(), value: try r.u32()) }
            let colorCount = Int(try r.u16())
            let colors = try (0..<colorCount).map { _ in try readColor(&r) }

            var altNames: [String] = []
            var flags: UInt32 = 0
            if v >= 5 {
                let n = Int(try r.u16())
                altNames = try (0..<n).map { _ in try r.string() }
                flags = try r.u32()
            }
            guard r.remaining == 0 else {
                throw OpenRGBError.malformed("\(r.remaining) unparsed bytes (protocol version mismatch?)")
            }
            return RGBDevice(type: type, name: name, vendor: vendor, description: description, version: version,
                             serial: serial, location: location, activeMode: activeMode, modes: modes,
                             zones: zones, leds: leds, colors: colors, ledAlternateNames: altNames, flags: flags)
        } catch let e as ByteReaderError {
            throw OpenRGBError.malformed("\(e)")
        }
    }

    private static func readColor(_ r: inout ByteReader) throws -> RGB8 {
        let c = RGB8(try r.u8(), try r.u8(), try r.u8())
        try r.skip(1)
        return c
    }

    /// Inverse of `parse`. Used by the tests' fake server and handy for diagnostics.
    public static func encode(_ d: RGBDevice, protocolVersion v: UInt32) -> [UInt8] {
        var w = ByteWriter()
        w.i32(d.type)
        w.string(d.name)
        if v >= 1 { w.string(d.vendor) }
        w.string(d.description); w.string(d.version); w.string(d.serial); w.string(d.location)
        w.u16(UInt16(d.modes.count)); w.i32(d.activeMode)
        for m in d.modes {
            w.string(m.name); w.i32(m.value); w.u32(m.flags); w.u32(m.speedMin); w.u32(m.speedMax)
            if v >= 3 { w.u32(m.brightnessMin); w.u32(m.brightnessMax) }
            w.u32(m.colorsMin); w.u32(m.colorsMax); w.u32(m.speed)
            if v >= 3 { w.u32(m.brightness) }
            w.u32(m.direction); w.u32(m.colorMode)
            w.u16(UInt16(m.colors.count)); m.colors.forEach { writeColor(&w, $0) }
        }
        w.u16(UInt16(d.zones.count))
        for z in d.zones {
            w.string(z.name); w.i32(z.type); w.u32(z.ledsMin); w.u32(z.ledsMax); w.u32(z.ledsCount)
            if let m = z.matrix {
                w.u16(UInt16(8 + m.map.count * 4)); w.u32(UInt32(m.height)); w.u32(UInt32(m.width))
                m.map.forEach { w.u32($0) }
            } else {
                w.u16(0)
            }
            if v >= 4 {
                w.u16(UInt16(z.segments.count))
                for s in z.segments { w.string(s.name); w.i32(s.type); w.u32(s.startIndex); w.u32(s.count) }
            }
            if v >= 5 { w.u32(z.flags) }
        }
        w.u16(UInt16(d.leds.count)); d.leds.forEach { w.string($0.name); w.u32($0.value) }
        w.u16(UInt16(d.colors.count)); d.colors.forEach { writeColor(&w, $0) }
        if v >= 5 {
            w.u16(UInt16(d.ledAlternateNames.count)); d.ledAlternateNames.forEach { w.string($0) }
            w.u32(d.flags)
        }
        var out = ByteWriter()
        out.u32(UInt32(w.bytes.count + 4))
        out.append(w.bytes)
        return out.bytes
    }

    private static func writeColor(_ w: inout ByteWriter, _ c: RGB8) { w.u8(c.r); w.u8(c.g); w.u8(c.b); w.u8(0) }
}

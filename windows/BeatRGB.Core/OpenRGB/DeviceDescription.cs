namespace BeatRGB.Core.OpenRGB;

/// <summary>
/// Decodes/encodes the REQUEST_CONTROLLER_DATA payload, following RGBController::GetDeviceDescriptionData
/// for protocol versions 0–5 (same layout as BeatRGBKit's DeviceDescription.swift).
/// </summary>
public static class DeviceDescription
{
    public static RGBDevice Parse(byte[] payload, uint v)
    {
        var r = new ByteReader(payload);
        uint declared = r.U32();
        if (declared != payload.Length) throw new OpenRGBException($"Malformed controller data: declared size {declared} ≠ payload {payload.Length}");
        var d = new RGBDevice { Type = r.I32(), Name = r.String() };
        d.Vendor = v >= 1 ? r.String() : "";
        d.Description = r.String();
        d.Version = r.String();
        d.Serial = r.String();
        d.Location = r.String();

        int modeCount = r.U16();
        d.ActiveMode = r.I32();
        for (int i = 0; i < modeCount; i++)
        {
            var m = new RGBMode { Name = r.String(), Value = r.I32(), Flags = r.U32(), SpeedMin = r.U32(), SpeedMax = r.U32() };
            if (v >= 3) { m.BrightnessMin = r.U32(); m.BrightnessMax = r.U32(); }
            m.ColorsMin = r.U32();
            m.ColorsMax = r.U32();
            m.Speed = r.U32();
            if (v >= 3) m.Brightness = r.U32();
            m.Direction = r.U32();
            m.ColorMode = r.U32();
            int n = r.U16();
            for (int c = 0; c < n; c++) m.Colors.Add(ReadColor(r));
            d.Modes.Add(m);
        }

        int zoneCount = r.U16();
        for (int i = 0; i < zoneCount; i++)
        {
            var z = new RGBZone { Name = r.String(), Type = r.I32(), LedsMin = r.U32(), LedsMax = r.U32(), LedsCount = r.U32() };
            int matrixSize = r.U16();
            if (matrixSize > 0)
            {
                int h = (int)r.U32(), w = (int)r.U32();
                if (h * w * 4 + 8 != matrixSize) throw new OpenRGBException($"Malformed controller data: matrix {h}x{w} does not fit {matrixSize} bytes");
                var map = new uint[h * w];
                for (int k = 0; k < map.Length; k++) map[k] = r.U32();
                z.Matrix = new MatrixMap(h, w, map);
            }
            if (v >= 4)
            {
                int sc = r.U16();
                for (int s = 0; s < sc; s++) z.Segments.Add(new RGBSegment(r.String(), r.I32(), r.U32(), r.U32()));
            }
            if (v >= 5) z.Flags = r.U32();
            d.Zones.Add(z);
        }

        int ledCount = r.U16();
        for (int i = 0; i < ledCount; i++) d.Leds.Add(new RGBLED(r.String(), r.U32()));
        int colorCount = r.U16();
        for (int i = 0; i < colorCount; i++) d.Colors.Add(ReadColor(r));

        if (v >= 5)
        {
            int n = r.U16();
            for (int i = 0; i < n; i++) d.LedAlternateNames.Add(r.String());
            d.Flags = r.U32();
        }
        if (r.Remaining != 0) throw new OpenRGBException($"Malformed controller data: {r.Remaining} unparsed bytes (protocol version mismatch?)");
        return d;
    }

    private static RGB8 ReadColor(ByteReader r)
    {
        var c = new RGB8(r.U8(), r.U8(), r.U8());
        r.Skip(1);
        return c;
    }

    /// <summary>Inverse of <see cref="Parse"/>. Used by the tests' fake server.</summary>
    public static byte[] Encode(RGBDevice d, uint v)
    {
        var w = new ByteWriter();
        w.I32(d.Type);
        w.String(d.Name);
        if (v >= 1) w.String(d.Vendor);
        w.String(d.Description); w.String(d.Version); w.String(d.Serial); w.String(d.Location);
        w.U16((ushort)d.Modes.Count); w.I32(d.ActiveMode);
        foreach (var m in d.Modes)
        {
            w.String(m.Name); w.I32(m.Value); w.U32(m.Flags); w.U32(m.SpeedMin); w.U32(m.SpeedMax);
            if (v >= 3) { w.U32(m.BrightnessMin); w.U32(m.BrightnessMax); }
            w.U32(m.ColorsMin); w.U32(m.ColorsMax); w.U32(m.Speed);
            if (v >= 3) w.U32(m.Brightness);
            w.U32(m.Direction); w.U32(m.ColorMode);
            w.U16((ushort)m.Colors.Count); m.Colors.ForEach(c => WriteColor(w, c));
        }
        w.U16((ushort)d.Zones.Count);
        foreach (var z in d.Zones)
        {
            w.String(z.Name); w.I32(z.Type); w.U32(z.LedsMin); w.U32(z.LedsMax); w.U32(z.LedsCount);
            if (z.Matrix is { } m)
            {
                w.U16((ushort)(8 + m.Map.Length * 4)); w.U32((uint)m.Height); w.U32((uint)m.Width);
                foreach (var x in m.Map) w.U32(x);
            }
            else w.U16(0);
            if (v >= 4)
            {
                w.U16((ushort)z.Segments.Count);
                foreach (var s in z.Segments) { w.String(s.Name); w.I32(s.Type); w.U32(s.StartIndex); w.U32(s.Count); }
            }
            if (v >= 5) w.U32(z.Flags);
        }
        w.U16((ushort)d.Leds.Count); d.Leds.ForEach(l => { w.String(l.Name); w.U32(l.Value); });
        w.U16((ushort)d.Colors.Count); d.Colors.ForEach(c => WriteColor(w, c));
        if (v >= 5)
        {
            w.U16((ushort)d.LedAlternateNames.Count); d.LedAlternateNames.ForEach(w.String);
            w.U32(d.Flags);
        }
        var body = w.ToArray();
        var output = new ByteWriter();
        output.U32((uint)(body.Length + 4));
        output.Append(body);
        return output.ToArray();
    }

    private static void WriteColor(ByteWriter w, RGB8 c) { w.U8(c.R); w.U8(c.G); w.U8(c.B); w.U8(0); }
}

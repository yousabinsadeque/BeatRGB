using System.Text.Json;
using BeatRGB.Core;
using BeatRGB.Core.Audio;
using BeatRGB.Core.Effects;
using BeatRGB.Core.Engine;
using BeatRGB.Core.OpenRGB;
using Xunit;

namespace BeatRGB.Core.Tests;

internal static class Fixtures
{
    public static byte[] K70(int version) =>
        File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", $"k70-core-tkl-v{version}.bin"));

    public static RGBDevice K70Device() => DeviceDescription.Parse(K70(5), 5);

    public static RGBDevice Device(string name, int type = RGBDevice.TypeKeyboard, string serial = "S", bool direct = true) => new()
    {
        Type = type, Name = name, Vendor = "Acme", Serial = serial,
        Modes = [new RGBMode { Name = direct ? "Direct" : "Static" }],
        Zones = [new RGBZone { Name = "Keys", Type = 1, LedsMin = 4, LedsMax = 4, LedsCount = 4 }],
        Leds = Enumerable.Range(0, 4).Select(i => new RGBLED($"LED {i}", (uint)i)).ToList(),
        Colors = Enumerable.Repeat(RGB8.Black, 4).ToList(),
    };
}

public class ProtocolTests
{
    [Theory]
    [InlineData(4)]
    [InlineData(5)]
    public void ParsesRealK70Payload(int version)
    {
        var d = DeviceDescription.Parse(Fixtures.K70(version), (uint)version);
        Assert.Equal("Corsair K70 Core RGB TKL", d.Name);
        Assert.Equal(86, d.Leds.Count);
        Assert.NotNull(d.DirectModeIndex);
    }

    [Theory]
    [InlineData(4)]
    [InlineData(5)]
    public void EncodeRoundTripsByteForByte(int version)
    {
        var bytes = Fixtures.K70(version);
        Assert.Equal(bytes, DeviceDescription.Encode(DeviceDescription.Parse(bytes, (uint)version), (uint)version));
    }

    [Fact]
    public void RejectsWrongVersion() =>
        Assert.Throws<OpenRGBException>(() => DeviceDescription.Parse(Fixtures.K70(5), 3));

    [Fact]
    public void UpdateLEDsPacketLayout()
    {
        var p = OpenRGBProtocol.Packet(2, OpenRGBProtocol.UpdateLEDs, OpenRGBProtocol.UpdateLEDsPayload([new RGB8(1, 2, 3)]));
        Assert.Equal("ORGB"u8.ToArray(), p[..4]);
        Assert.Equal(new byte[] { 2, 0, 0, 0, 0x1A, 0x04, 0, 0, 10, 0, 0, 0, 10, 0, 0, 0, 1, 0, 1, 2, 3, 0 }, p[4..]);
    }
}

public class MatcherAndLayoutTests
{
    [Fact]
    public void AutomaticPicksFirstKeyboardWithDirectMode()
    {
        var mouse = Fixtures.Device("Mouse", type: 6);
        var noDirect = Fixtures.Device("Razer Huntsman", direct: false);
        var apex = Fixtures.Device("SteelSeries Apex 7", serial: "ABC");
        Assert.Equal("ABC", DeviceMatcher.Automatic.Select([mouse, noDirect, apex])?.Serial);
        Assert.Equal("Razer Huntsman", DeviceMatcher.Automatic.Select([mouse, noDirect])?.Name);
        Assert.Null(DeviceMatcher.Automatic.Select([mouse]));
    }

    [Fact]
    public void PickedNameAndSerial()
    {
        var mouse = Fixtures.Device("Mouse", type: 6, serial: "M");
        Assert.Equal("Mouse", new DeviceMatcher(Name: "Mouse").Select([Fixtures.Device("KB"), mouse])?.Name);
        Assert.Equal("KB", new DeviceMatcher(Serial: "S", Name: "Mouse").Select([Fixtures.Device("KB"), mouse])?.Name);
    }

    [Fact]
    public void LayoutFromRealMatrix()
    {
        var d = Fixtures.K70Device();
        var layout = KeyboardLayout.FromDevice(d);
        Assert.Equal(86, layout.LedCount);
        Assert.Equal((6, 17), (layout.Rows, layout.Cols));
        Assert.Equal(new KeyboardLayout.Cell(0, 0), layout.Cells[0]);   // Escape top-left
        int arrow = d.Leds.FindIndex(l => l.Name == "Key: Right Arrow");
        Assert.Equal((1f, 1f), layout.Positions[arrow]);                 // bottom-right
    }

    [Fact]
    public void LayoutPlacesLEDsWithoutMatrix()
    {
        var l = KeyboardLayout.FromDevice(Fixtures.Device("Strip"));
        Assert.Equal((1, 4), (l.Rows, l.Cols));
        Assert.Equal(new[] { 0f, 1 / 3f, 2 / 3f, 1f }, l.Positions.Select(p => p.X));
    }
}

public class AnalyzerTests
{
    private static SampleRing.Snapshot Sine(double hz, float amp, int n = 2048, double rate = 48_000)
    {
        var w = Enumerable.Range(0, n).Select(i => amp * (float)Math.Sin(2 * Math.PI * hz * i / rate)).ToArray();
        return new SampleRing.Snapshot(w, amp / MathF.Sqrt(2), amp, n, rate);
    }

    [Fact]
    public void SineLightsItsBand()
    {
        var a = new AudioAnalyzer();
        AudioFeatures f = AudioFeatures.Silent(24);
        for (int i = 0; i < 60; i++) f = a.Analyze(Sine(1000, 0.5f), 1 / 30.0);
        var edges = AudioAnalyzer.BandEdges(24);
        int band = Enumerable.Range(0, 24).First(b => edges[b] <= 1000 && 1000 < edges[b + 1]);
        Assert.Equal(band, Array.IndexOf(f.Bands, f.Bands.Max()));
        Assert.True(f.Mid > f.Bass && f.Mid > f.Treble);
        Assert.False(f.IsSilent);
    }

    [Fact]
    public void KickDrumProducesBeats()
    {
        var a = new AudioAnalyzer();
        int beats = 0;
        for (int i = 0; i < 120; i++)
        {
            bool kick = i % 15 < 2;   // two loud frames every half second
            var f = a.Analyze(kick ? Sine(60, 0.9f) : Sine(60, 0.01f), 1 / 30.0);
            if (f.Beat) beats++;
        }
        Assert.InRange(beats, 6, 9);
    }

    [Fact]
    public void SilenceGoesIdleAfterHold()
    {
        var a = new AudioAnalyzer { Settings = new AnalyzerSettings { SilenceHold = 1 } };
        a.Analyze(Sine(200, 0.5f), 1 / 30.0);
        AudioFeatures f = AudioFeatures.Silent(24);
        for (int i = 0; i < 20; i++) f = a.Analyze(new SampleRing.Snapshot(new float[2048], 0, 0, 1600, 48_000), 1 / 30.0);
        Assert.False(f.IsSilent);
        for (int i = 0; i < 20; i++) f = a.Analyze(new SampleRing.Snapshot(new float[2048], 0, 0, 1600, 48_000), 1 / 30.0);
        Assert.True(f.IsSilent);
    }

    [Fact]
    public void RingKeepsMostRecentSamples()
    {
        var ring = new SampleRing(8);
        ring.Append([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
        var s = ring.Take(4);
        Assert.Equal(new float[] { 7, 8, 9, 10 }, s.Window);
        Assert.Equal(10, s.NewFrames);
        Assert.Equal(0, ring.Take(4).NewFrames);
    }
}

public class EffectTests
{
    private static AudioFeatures Loud(bool beat = false)
    {
        var f = new AudioFeatures(24) { Level = 0.8f, Bass = 0.9f, Mid = 0.5f, Treble = 0.6f, Beat = beat, IsSilent = false, HasSignal = true };
        for (int i = 0; i < 24; i++) f.Bands[i] = 0.7f;
        return f;
    }

    [Fact]
    public void EveryEffectRendersAFullFrameInRange()
    {
        var layout = KeyboardLayout.FromDevice(Fixtures.K70Device());
        var grid = new ScreenGrid(2, 1, [new RGBF(1, 0, 0), new RGBF(0, 0, 1)]);
        foreach (var effect in Enum.GetValues<EffectKind>())
        {
            var r = new EffectRenderer(layout) { Settings = new LightingSettings { Effect = effect } };
            RGBF[] frame = [];
            for (int i = 0; i < 30; i++) frame = r.Render(Loud(beat: i % 10 == 0), grid, 1 / 30.0);
            Assert.Equal(86, frame.Length);
            Assert.All(frame, c => Assert.True(c.R is >= 0 and <= 1 && c.G is >= 0 and <= 1 && c.B is >= 0 and <= 1, effect.ToString()));
            Assert.True(frame.Any(c => c.Luminance > 0.01f), $"{effect} rendered a dark frame");
        }
    }

    [Fact]
    public void ScreenMirrorFollowsTheScreen()
    {
        var layout = KeyboardLayout.Grid(1, 2);
        var r = new EffectRenderer(layout) { Settings = new LightingSettings { Effect = EffectKind.ScreenMirror, Brightness = 1, ScreenSaturation = 0, ScreenGain = 1 } };
        var grid = new ScreenGrid(2, 1, [new RGBF(1, 0, 0), new RGBF(0, 0, 1)]);
        RGBF[] frame = [];
        for (int i = 0; i < 60; i++) frame = r.Render(AudioFeatures.Silent(24), grid, 1 / 30.0);
        Assert.True(frame[0].R > 0.9f && frame[0].B < 0.1f);
        Assert.True(frame[1].B > 0.9f && frame[1].R < 0.1f);
    }

    [Fact]
    public void SilenceFadesToIdle()
    {
        var r = new EffectRenderer(KeyboardLayout.Grid(1, 4)) { Settings = new LightingSettings { Effect = EffectKind.Spectrum, Idle = IdleKind.Off } };
        RGBF[] frame = [];
        for (int i = 0; i < 90; i++) frame = r.Render(AudioFeatures.Silent(24), null, 1 / 30.0);
        Assert.All(frame, c => Assert.Equal(RGBF.Black, c));
    }

    [Fact]
    public void ScreenGridDownsamplesBGRA()
    {
        // 2×1 image: left pixel pure blue (BGRA 255,0,0), right pure red.
        var g = ScreenGrid.FromBGRA([255, 0, 0, 255, 0, 0, 255, 255], 2, 1, 8, 2, 1);
        Assert.Equal(new RGBF(0, 0, 1), g.Pixels[0]);
        Assert.Equal(new RGBF(1, 0, 0), g.Pixels[1]);
    }

    [Fact]
    public void SettingsSurviveJson()
    {
        var lib = ProfileLibrary.BuiltIn();
        var back = JsonSerializer.Deserialize<ProfileLibrary>(JsonSerializer.Serialize(lib))!;
        Assert.Equal(lib.Profiles.Select(p => p.Settings), back.Profiles.Select(p => p.Settings));
        Assert.Contains("\"BassPulse\"", JsonSerializer.Serialize(lib));
    }
}

public class ClientAndEngineTests
{
    [Fact]
    public void ClientEnumeratesAndDrivesOnlyTheKeyboard()
    {
        using var server = new FakeOpenRGBServer(Fixtures.Device("Mouse", type: 6), Fixtures.K70Device());
        using var c = new OpenRGBClient(port: server.Port);
        c.Connect();
        Assert.Equal(5u, c.ProtocolVersion);
        var all = c.AllControllers();
        var kb = DeviceMatcher.Automatic.Select(all)!;
        Assert.Equal(1u, kb.Index);
        var direct = c.EnableDirectMode(kb);
        Assert.Equal("Direct", direct.ActiveModeName);
        var colors = Enumerable.Repeat(new RGB8(0, 255, 0), 86).ToArray();
        c.UpdateLEDs(kb.Index, colors);
        c.Controller(kb.Index);   // round trip ensures the update was processed
        Assert.Equal(colors, server.LastUpdate);
        Assert.All(server.Devices[0].Colors, x => Assert.Equal(RGB8.Black, x));   // mouse untouched
    }

    [Fact]
    public void OlderServerVersionIsUsed()
    {
        using var server = new FakeOpenRGBServer(Fixtures.K70Device()) { ServerVersion = 3 };
        using var c = new OpenRGBClient(port: server.Port);
        c.Connect();
        Assert.Equal(3u, c.ProtocolVersion);
        Assert.Equal("Corsair K70 Core RGB TKL", c.Controller(0).Name);
    }

    [Fact]
    public async Task EngineDrivesDeviceAndRestoresOnStop()
    {
        var k70 = Fixtures.K70Device();
        var original = k70.Colors.ToArray();
        using var server = new FakeOpenRGBServer(k70);
        using var engine = new LightingEngine();
        EngineSnapshot? last = null;
        engine.SnapshotChanged += s => last = s;
        engine.Configure(new EngineConfig { Port = server.Port, StopBehavior = StopBehavior.RestorePrevious });
        engine.Update(new LightingSettings { Effect = EffectKind.StaticColor, PrimaryColor = ColorValue.Red, Brightness = 1 });
        engine.Start();
        for (int i = 0; i < 50 && server.UpdateCount == 0; i++) await Task.Delay(50);
        Assert.Equal(Enumerable.Repeat(new RGB8(255, 0, 0), 86), server.LastUpdate);
        Assert.Equal(ConnectionStatus.Connected, last?.Connection);
        Assert.Equal((6, 17), (last!.Layout.Rows, last.Layout.Cols));
        await engine.StopAsync();
        Assert.Equal(original, server.LastUpdate);
    }

    [Fact]
    public async Task EngineReportsMissingKeyboard()
    {
        using var server = new FakeOpenRGBServer(Fixtures.Device("Mouse", type: 6));
        using var engine = new LightingEngine();
        engine.Configure(new EngineConfig { Port = server.Port });
        var result = await engine.SendTestColorAsync(new RGB8(1, 2, 3));
        Assert.StartsWith("Failed: No matching RGB keyboard found. Available: Mouse", result);
    }
}

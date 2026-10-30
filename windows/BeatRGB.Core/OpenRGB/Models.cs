namespace BeatRGB.Core.OpenRGB;

public sealed class RGBMode
{
    public string Name { get; set; } = "";
    public int Value { get; set; }
    public uint Flags { get; set; }
    public uint SpeedMin { get; set; }
    public uint SpeedMax { get; set; }
    public uint BrightnessMin { get; set; }
    public uint BrightnessMax { get; set; }
    public uint ColorsMin { get; set; }
    public uint ColorsMax { get; set; }
    public uint Speed { get; set; }
    public uint Brightness { get; set; }
    public uint Direction { get; set; }
    public uint ColorMode { get; set; }
    public List<RGB8> Colors { get; set; } = [];

    /// <summary>OpenRGB names the software-controlled per-LED mode "Direct" (older drivers: "Custom").</summary>
    public bool IsDirect => Name.Equals("direct", StringComparison.OrdinalIgnoreCase) || Name.Equals("custom", StringComparison.OrdinalIgnoreCase);
}

public sealed class MatrixMap(int height, int width, uint[] map)
{
    public const uint NoLED = 0xFFFF_FFFF;
    public int Height { get; } = height;
    public int Width { get; } = width;
    /// <summary>Row-major, zone-relative LED indices (or <see cref="NoLED"/>).</summary>
    public uint[] Map { get; } = map;

    public uint? Led(int row, int col)
    {
        uint v = Map[row * Width + col];
        return v == NoLED ? null : v;
    }
}

public sealed record RGBSegment(string Name, int Type, uint StartIndex, uint Count);

public sealed class RGBZone
{
    public string Name { get; set; } = "";
    public int Type { get; set; }
    public uint LedsMin { get; set; }
    public uint LedsMax { get; set; }
    public uint LedsCount { get; set; }
    public MatrixMap? Matrix { get; set; }
    public List<RGBSegment> Segments { get; set; } = [];
    public uint Flags { get; set; }
}

public sealed record RGBLED(string Name, uint Value);

public sealed record DeviceIdentity(string Name, string Vendor, string Serial);

public sealed class RGBDevice
{
    public const int TypeKeyboard = 5;

    public uint Index { get; set; }
    public int Type { get; set; }
    public string Name { get; set; } = "";
    public string Vendor { get; set; } = "";
    public string Description { get; set; } = "";
    public string Version { get; set; } = "";
    public string Serial { get; set; } = "";
    public string Location { get; set; } = "";
    public int ActiveMode { get; set; }
    public List<RGBMode> Modes { get; set; } = [];
    public List<RGBZone> Zones { get; set; } = [];
    public List<RGBLED> Leds { get; set; } = [];
    public List<RGB8> Colors { get; set; } = [];
    public List<string> LedAlternateNames { get; set; } = [];
    public uint Flags { get; set; }

    public int? DirectModeIndex { get { int i = Modes.FindIndex(m => m.IsDirect); return i >= 0 ? i : null; } }
    public bool ActiveModeIsDirect => ActiveMode >= 0 && ActiveMode < Modes.Count && Modes[ActiveMode].IsDirect;
    public string ActiveModeName => ActiveMode >= 0 && ActiveMode < Modes.Count ? Modes[ActiveMode].Name : $"#{ActiveMode}";

    /// <summary>Stable identity used to make sure BeatRGB only ever drives the intended device.</summary>
    public DeviceIdentity Identity => new(Name, Vendor, Serial);
}

/// <summary>
/// How BeatRGB picks its target among the controllers OpenRGB reports. Works with any keyboard OpenRGB
/// supports: a remembered serial wins, then a device the user picked by name, otherwise the first
/// keyboard that has a Direct (per-LED) mode.
/// </summary>
public sealed record DeviceMatcher(string? Serial = null, string? Name = null)
{
    public static readonly DeviceMatcher Automatic = new();

    public RGBDevice? Select(IReadOnlyList<RGBDevice> devices)
    {
        if (!string.IsNullOrEmpty(Serial)) return devices.FirstOrDefault(d => d.Serial == Serial);
        if (!string.IsNullOrEmpty(Name)) return devices.FirstOrDefault(d => d.Name == Name);
        var keyboards = devices.Where(d => d.Type == RGBDevice.TypeKeyboard).ToList();
        return keyboards.FirstOrDefault(d => d.DirectModeIndex != null) ?? keyboards.FirstOrDefault();
    }
}

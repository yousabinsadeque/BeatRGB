using System.Text.Json;
using BeatRGB.Core.Effects;

namespace BeatRGB.Core.Engine;

public sealed class LightingProfile
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "";
    public LightingSettings Settings { get; set; } = new();
}

public sealed class ProfileLibrary
{
    public List<LightingProfile> Profiles { get; set; } = [];
    public Guid? ActiveId { get; set; }

    public LightingProfile? Active => Profiles.FirstOrDefault(p => p.Id == ActiveId) ?? Profiles.FirstOrDefault();

    /// <summary>The same ready-made profiles as the Mac app.</summary>
    public static ProfileLibrary BuiltIn()
    {
        static LightingProfile Make(string name, Action<LightingSettings> edit)
        {
            var s = new LightingSettings();
            edit(s);
            return new LightingProfile { Name = name, Settings = s };
        }
        var profiles = new List<LightingProfile>
        {
            Make("Rainbow Spectrum", s => { s.Effect = EffectKind.Spectrum; s.SpectrumStyle = SpectrumStyle.Multicolor; }),
            Make("Bass Party", s =>
            {
                s.Effect = EffectKind.BassPulse; s.PrimaryColor = ColorValue.FromHex(0xFF0040); s.BassResponse = 1.3;
                s.PulseAttackMs = 15; s.PulseDecayMs = 220; s.Baseline = 0.05; s.Brightness = 1;
            }),
            Make("Relaxed Ambient", s =>
            {
                s.Effect = EffectKind.RainbowWave; s.Speed = 0.4; s.Smoothing = 0.8; s.Brightness = 0.55;
                s.Idle = IdleKind.Breathing; s.IdleColor = ColorValue.FromHex(0x3C6CFF);
            }),
            Make("Gaming", s =>
            {
                s.Effect = EffectKind.Ripple; s.PrimaryColor = ColorValue.FromHex(0x00FFA0); s.Speed = 1.4;
                s.Idle = IdleKind.StaticColor; s.IdleColor = ColorValue.FromHex(0x00C080);
            }),
            Make("Work Mode", s =>
            {
                s.Effect = EffectKind.FullReact; s.Brightness = 0.35; s.Smoothing = 0.85; s.Sensitivity = 0.6;
                s.Idle = IdleKind.StaticColor; s.IdleColor = ColorValue.FromHex(0xFFE6C8);
            }),
            Make("Club Strobe", s => { s.Effect = EffectKind.BeatStrobe; s.Speed = 1.2; s.Idle = IdleKind.Rainbow; }),
            Make("Campfire", s =>
            {
                s.Effect = EffectKind.Fire; s.BassResponse = 1.2; s.Idle = IdleKind.Breathing; s.IdleColor = ColorValue.FromHex(0xFF5A00);
            }),
            Make("Starlight", s =>
            {
                s.Effect = EffectKind.Sparkle; s.PrimaryColor = ColorValue.FromHex(0x7FA8FF); s.Idle = IdleKind.Breathing;
                s.IdleColor = ColorValue.FromHex(0x203060);
            }),
            Make("Centre EQ", s =>
            {
                s.Effect = EffectKind.MirrorSpectrum; s.PrimaryColor = ColorValue.FromHex(0x00E5FF); s.SecondaryColor = ColorValue.FromHex(0xFF00C8);
            }),
            Make("Screen Mirror", s => { s.Effect = EffectKind.ScreenMirror; s.Brightness = 1; s.Smoothing = 0.5; }),
        };
        return new ProfileLibrary { Profiles = profiles, ActiveId = profiles[0].Id };
    }
}

/// <summary>Stores a JSON document in a folder (profiles.json, settings.json under %APPDATA%\BeatRGB on Windows).</summary>
public sealed class JsonStore<T>(string path) where T : class
{
    private static readonly JsonSerializerOptions Options = new() { WriteIndented = true };
    public string Path { get; } = path;

    public static string DefaultDirectory =>
        System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "BeatRGB");

    public T? Load()
    {
        try { return File.Exists(Path) ? JsonSerializer.Deserialize<T>(File.ReadAllText(Path), Options) : null; }
        catch (JsonException) { return null; }
    }

    public void Save(T value)
    {
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(Path)!);
        var tmp = Path + ".tmp";
        File.WriteAllText(tmp, JsonSerializer.Serialize(value, Options));
        File.Move(tmp, Path, overwrite: true);
    }
}

using System.Text.Json.Serialization;
using BeatRGB.Core.Audio;

namespace BeatRGB.Core.Effects;

[JsonConverter(typeof(JsonStringEnumConverter<EffectKind>))]
public enum EffectKind
{
    Spectrum, MirrorSpectrum, VuMeter, BassPulse, BeatStrobe, RainbowWave, FullReact, Ripple, Sparkle, Fire,
    ScreenMirror, StaticColor,
}

[JsonConverter(typeof(JsonStringEnumConverter<SpectrumStyle>))]
public enum SpectrumStyle { Multicolor, Gradient, Single }

[JsonConverter(typeof(JsonStringEnumConverter<IdleKind>))]
public enum IdleKind { StaticColor, Breathing, Rainbow, Off }

public static class EffectInfo
{
    public static string Title(this EffectKind e) => e switch
    {
        EffectKind.Spectrum => "Audio Spectrum",
        EffectKind.MirrorSpectrum => "Centre EQ",
        EffectKind.VuMeter => "VU Meter",
        EffectKind.BeatStrobe => "Beat Flash",
        EffectKind.Sparkle => "Treble Sparkle",
        EffectKind.Fire => "Bass Fire",
        EffectKind.BassPulse => "Bass Pulse",
        EffectKind.RainbowWave => "Rainbow Music Wave",
        EffectKind.FullReact => "Full-Keyboard Reaction",
        EffectKind.Ripple => "Beat Ripple",
        EffectKind.ScreenMirror => "Screen Mirror",
        EffectKind.StaticColor => "Static Colour",
        _ => e.ToString(),
    };

    /// <summary>Effects that react to music (and therefore use the idle transition).</summary>
    public static bool IsAudioReactive(this EffectKind e) => e is not (EffectKind.ScreenMirror or EffectKind.StaticColor);
    public static bool UsesScreen(this EffectKind e) => e == EffectKind.ScreenMirror;

    /// <summary>Effects whose look depends on the Colour picker (the rest use their own palette).</summary>
    public static bool UsesPrimaryColor(this EffectKind e) => e is EffectKind.Spectrum or EffectKind.MirrorSpectrum or EffectKind.BassPulse
        or EffectKind.FullReact or EffectKind.Ripple or EffectKind.Sparkle or EffectKind.StaticColor;

    public static string Title(this SpectrumStyle s) => s switch
    {
        SpectrumStyle.Multicolor => "Multicolour spectrum",
        SpectrumStyle.Gradient => "Two-colour gradient",
        _ => "Single colour",
    };

    public static string Title(this IdleKind k) => k switch
    {
        IdleKind.StaticColor => "Static colour",
        IdleKind.Breathing => "Breathing",
        IdleKind.Rainbow => "Rainbow",
        _ => "Lights off",
    };
}

/// <summary>One profile's lighting settings. Same fields and defaults as the Mac app's LightingSettings.</summary>
public sealed record LightingSettings
{
    public EffectKind Effect { get; set; } = EffectKind.Spectrum;
    public SpectrumStyle SpectrumStyle { get; set; } = SpectrumStyle.Multicolor;
    public ColorValue PrimaryColor { get; set; } = ColorValue.FromHex(0xFF1E3C);
    public ColorValue SecondaryColor { get; set; } = ColorValue.FromHex(0x2A6BFF);
    /// <summary>Master brightness 0…1, applied to every effect.</summary>
    public double Brightness { get; set; } = 0.85;
    /// <summary>Animation speed multiplier 0.1…3.</summary>
    public double Speed { get; set; } = 1;
    public double Sensitivity { get; set; } = 1;
    public double Smoothing { get; set; } = 0.45;
    public double BassResponse { get; set; } = 1;
    public double PulseAttackMs { get; set; } = 25;
    public double PulseDecayMs { get; set; } = 260;
    /// <summary>Brightness floor for Bass Pulse, 0…0.6.</summary>
    public double Baseline { get; set; } = 0.08;
    public bool NoiseGateEnabled { get; set; } = true;
    public double NoiseGateDB { get; set; } = -60;
    public bool AdaptiveGain { get; set; } = true;
    public IdleKind Idle { get; set; } = IdleKind.Breathing;
    public ColorValue IdleColor { get; set; } = ColorValue.FromHex(0x6A3CFF);
    public double IdleDelay { get; set; } = 2;
    /// <summary>Screen Mirror: saturation boost 0…1.</summary>
    public double ScreenSaturation { get; set; } = 0.35;
    /// <summary>Screen Mirror brightness multiplier (1…4): averaged screen areas are usually dim on the keys.</summary>
    public double ScreenGain { get; set; } = 2;
    public int ScreenDisplayIndex { get; set; }
    public double TargetFPS { get; set; } = 30;

    public LightingSettings Copy() => this with { };

    [JsonIgnore]
    public AnalyzerSettings AnalyzerSettings => new()
    {
        Sensitivity = (float)Sensitivity,
        Smoothing = (float)Smoothing,
        BassResponse = (float)BassResponse,
        NoiseGateDB = (float)NoiseGateDB,
        NoiseGateEnabled = NoiseGateEnabled,
        AdaptiveGain = AdaptiveGain,
        SilenceHold = IdleDelay,
    };
}

using BeatRGB.Core.Audio;

namespace BeatRGB.Core.Effects;

/// <summary>
/// Stateful renderer: turns audio features (or screen colours) into one colour per LED.
/// A port of BeatRGBKit's EffectRenderer.swift; every effect lays itself out from the keyboard's own map.
/// </summary>
public sealed class EffectRenderer(KeyboardLayout? layout = null)
{
    private struct Ripple { public float X, Y, Age, Hue; }

    public LightingSettings Settings { get; set; } = new();
    public KeyboardLayout Layout { get; private set; } = layout ?? KeyboardLayout.PlaceholderTKL;

    private double _time, _wavePhase;
    private Envelope _pulse = new(0.025, 0.26);
    private float _idleMix = 1;              // 1 = fully idle, 0 = fully active
    private readonly List<Ripple> _ripples = [];
    private RGBF[] _screenColors = [];
    private Envelope _flash = new(0.004, 0.18);
    private float _flashHue;
    private float[] _meterPeaks = [];        // VU peak-hold marker per row
    private float[] _sparkleLevel = [];      // per-LED twinkle brightness
    private float[] _sparkleHue = [];
    private float[] _heat = [];              // per-LED flame intensity
    private ulong _rng = 0x9E37_79B9_7F4A_7C15;

    public void SetLayout(KeyboardLayout layout)
    {
        Layout = layout;
        _screenColors = []; _meterPeaks = []; _sparkleLevel = []; _sparkleHue = []; _heat = [];
    }

    public RGBF[] Render(AudioFeatures f, ScreenGrid? screen, double dt)
    {
        _time += dt;
        var s = Settings;
        var active = s.Effect switch
        {
            EffectKind.Spectrum => Spectrum(f),
            EffectKind.MirrorSpectrum => MirrorSpectrum(f),
            EffectKind.VuMeter => VuMeter(f, dt),
            EffectKind.BeatStrobe => BeatStrobe(f, dt),
            EffectKind.Sparkle => Sparkle(f, dt),
            EffectKind.Fire => Fire(f, dt),
            EffectKind.BassPulse => BassPulse(f, dt),
            EffectKind.RainbowWave => RainbowWave(f, dt),
            EffectKind.FullReact => FullReact(f),
            EffectKind.Ripple => RippleEffect(f, dt),
            EffectKind.ScreenMirror => ScreenMirror(screen, dt),
            _ => Fill(RGBF.From(s.PrimaryColor)),
        };

        var output = active;
        if (s.Effect.IsAudioReactive())
        {
            // Crossfade between music and idle over ~1.2 s so stopping music never snaps.
            float target = f.IsSilent ? 1 : 0;
            float step = (float)(dt / 1.2);
            _idleMix = target > _idleMix ? MathF.Min(target, _idleMix + step) : MathF.Max(target, _idleMix - step * 3);
            if (_idleMix > 0)
            {
                var idle = IdleFrame();
                output = active.Select((c, i) => c.Mix(idle[i], _idleMix)).ToArray();
            }
        }
        else _idleMix = 0;
        float master = (float)Math.Clamp(s.Brightness, 0, 1);
        return output.Select(c => (c * master).Clamped).ToArray();
    }

    /// <summary>Idle frame on its own (also used when sync stops with "show idle" selected).</summary>
    public RGBF[] IdleFrame()
    {
        var s = Settings;
        switch (s.Idle)
        {
            case IdleKind.Off: return Fill(RGBF.Black);
            case IdleKind.StaticColor: return Fill(RGBF.From(s.IdleColor) * 0.6f);
            case IdleKind.Breathing:
                float k = (float)(0.12 + 0.48 * (0.5 - 0.5 * Math.Cos(_time * 2 * Math.PI / (5.0 / Math.Max(0.1, s.Speed)))));
                return Fill(RGBF.From(s.IdleColor) * k);
            default:
                float phase = (float)(_time * 0.05 * s.Speed);
                return Layout.Positions.Select(p => RGBF.Hsv(phase + p.X * 0.6f, 1, 0.45f)).ToArray();
        }
    }

    private RGBF[] Fill(RGBF c) => Enumerable.Repeat(c, Layout.LedCount).ToArray();

    private static float BandValue(AudioFeatures f, float x)
    {
        if (f.Bands.Length == 0) return 0;
        float pos = Math.Clamp(x, 0, 1) * (f.Bands.Length - 1);
        int i = (int)pos, j = Math.Min(i + 1, f.Bands.Length - 1);
        return f.Bands[i] + (f.Bands[j] - f.Bands[i]) * (pos - i);
    }

    /// <summary>Low → left, high → right; each column is an equaliser bar rising from the bottom row.</summary>
    private RGBF[] Spectrum(AudioFeatures f)
    {
        var s = Settings;
        float rows = Layout.Rows;
        return Layout.Positions.Select(p =>
        {
            float v = BandValue(f, p.X);
            float height = 1 - p.Y;                        // 0 at bottom row, 1 at top
            float rowSize = 1 / MathF.Max(1, rows - 1);
            float lit = Math.Clamp((v * (1 + rowSize) - height) / rowSize, 0, 1);
            float glow = 0.06f + 0.94f * lit;
            var color = s.SpectrumStyle switch
            {
                SpectrumStyle.Multicolor => RGBF.Hsv(p.X * 0.78f, 1, 1),
                SpectrumStyle.Gradient => RGBF.From(s.PrimaryColor).Mix(RGBF.From(s.SecondaryColor), height),
                _ => RGBF.From(s.PrimaryColor),
            };
            return color * (glow * (0.35f + 0.65f * v));
        }).ToArray();
    }

    private RGBF[] BassPulse(AudioFeatures f, double dt)
    {
        var s = Settings;
        _pulse.Attack = s.PulseAttackMs / 1000;
        _pulse.Release = s.PulseDecayMs / 1000;
        float drive = f.Beat ? MathF.Max(f.Bass, 1) : f.Bass;
        float e = _pulse.Process(drive, dt);
        float b = (float)s.Baseline;
        var color = RGBF.From(s.PrimaryColor);
        // Light spreads from the centre outward as the pulse grows.
        return Layout.Positions.Select(p =>
        {
            float dx = (p.X - 0.5f) * 1.6f, dy = p.Y - 0.5f;
            float dist = MathF.Min(1, MathF.Sqrt(dx * dx + dy * dy));
            float reach = Math.Clamp(e * 1.3f - dist * 0.7f, 0, 1);
            return color * (b + (1 - b) * MathF.Max(e * 0.35f, reach));
        }).ToArray();
    }

    private RGBF[] RainbowWave(AudioFeatures f, double dt)
    {
        _wavePhase += dt * Settings.Speed * (0.15 + 0.9 * f.Level + (f.Beat ? 0.4 : 0));
        float brightness = 0.25f + 0.75f * f.Level;
        float phase = (float)_wavePhase;
        return Layout.Positions.Select(p =>
        {
            float ripple = 0.08f * MathF.Sin((p.Y * 3 + phase * 2) * MathF.PI);
            return RGBF.Hsv(p.X * 0.9f + ripple - phase, 1, brightness);
        }).ToArray();
    }

    /// <summary>One colour for all keys: hue from bass/mid/treble balance, brightness from loudness.</summary>
    private RGBF[] FullReact(AudioFeatures f)
    {
        float total = f.Bass + f.Mid + f.Treble + 1e-4f;
        var mix = new RGBF(1, 0.05f, 0.15f) * (f.Bass / total) + new RGBF(0.1f, 1, 0.3f) * (f.Mid / total) + new RGBF(0.2f, 0.35f, 1) * (f.Treble / total);
        var tinted = mix.Mix(RGBF.From(Settings.PrimaryColor), 0.25f);
        float peak = MathF.Max(MathF.Max(tinted.R, tinted.G), MathF.Max(tinted.B, 1e-4f));
        return Fill(tinted * (1 / peak) * (0.08f + 0.92f * f.Level));
    }

    private RGBF[] RippleEffect(AudioFeatures f, double dt)
    {
        if (f.Beat && _ripples.Count < 6)
        {
            float seed = (float)(_time % 97);
            _ripples.Add(new Ripple { X = 0.5f + 0.4f * MathF.Sin(seed * 7.1f), Y = 0.5f + 0.4f * MathF.Cos(seed * 3.3f), Age = 0, Hue = seed * 0.13f });
        }
        float speed = (float)Settings.Speed;
        for (int i = 0; i < _ripples.Count; i++) { var r = _ripples[i]; r.Age += (float)dt * speed; _ripples[i] = r; }
        _ripples.RemoveAll(r => r.Age > 1.6f);
        var b = RGBF.From(Settings.PrimaryColor) * (0.05f + 0.25f * f.Level);
        return Layout.Positions.Select(p =>
        {
            var c = b;
            foreach (var r in _ripples)
            {
                float dx = (p.X - r.X) * 1.8f, dy = p.Y - r.Y;
                float d = MathF.Sqrt(dx * dx + dy * dy);
                float ring = MathF.Max(0, 1 - MathF.Abs(d - r.Age * 0.9f) * 6) * MathF.Max(0, 1 - r.Age / 1.6f);
                c += RGBF.Hsv(r.Hue, 0.9f, 1) * ring;
            }
            return c;
        }).ToArray();
    }

    /// <summary>Bass in the centre column, highs at both edges; bars grow up and down from the middle row.</summary>
    private RGBF[] MirrorSpectrum(AudioFeatures f)
    {
        var s = Settings;
        float rowSize = 2 / MathF.Max(1, Layout.Rows - 1);
        return Layout.Positions.Select(p =>
        {
            float v = BandValue(f, MathF.Abs(p.X - 0.5f) * 2);
            float reach = MathF.Abs(p.Y - 0.5f) * 2;          // 0 at the middle row, 1 at top/bottom
            float lit = Math.Clamp((v * (1 + rowSize) - reach) / rowSize, 0, 1);
            var color = RGBF.From(s.PrimaryColor).Mix(RGBF.From(s.SecondaryColor), reach);
            return color * ((0.05f + 0.95f * lit) * (0.35f + 0.65f * v));
        }).ToArray();
    }

    /// <summary>Each row is a level meter (bottom = bass, top = treble), green → yellow → red, with a falling peak marker.</summary>
    private RGBF[] VuMeter(AudioFeatures f, double dt)
    {
        int rows = Math.Max(1, Layout.Rows);
        if (_meterPeaks.Length != rows) _meterPeaks = new float[rows];
        var rowLevel = new float[rows];
        for (int r = 0; r < rows; r++)
        {
            float band = rows == 1 ? 0 : 1 - (float)r / (rows - 1);
            rowLevel[r] = MathF.Min(1, BandValue(f, band) * 0.7f + f.Level * 0.3f);
            _meterPeaks[r] = MathF.Max(rowLevel[r], _meterPeaks[r] - (float)dt * 0.6f * (float)Settings.Speed);
        }
        float keyWidth = 1 / MathF.Max(1, Layout.Cols);
        return Layout.Positions.Select(p =>
        {
            int r = Math.Clamp((int)MathF.Round(p.Y * (rows - 1)), 0, rows - 1);
            var zone = p.X < 0.6f ? new RGBF(0, 1, 0.15f) : p.X < 0.85f ? new RGBF(1, 0.75f, 0) : new RGBF(1, 0.05f, 0.05f);
            if (p.X <= rowLevel[r]) return zone;
            if (MathF.Abs(p.X - _meterPeaks[r]) < keyWidth) return zone * 0.7f;
            return zone * 0.04f;
        }).ToArray();
    }

    /// <summary>The whole keyboard flashes on every beat, stepping to a new hue each time.</summary>
    private RGBF[] BeatStrobe(AudioFeatures f, double dt)
    {
        _flash.Release = 0.18 / Math.Max(0.1, Settings.Speed);
        if (f.Beat) _flashHue += 0.382f;               // golden-ratio steps keep successive colours distinct
        float e = _flash.Process(f.Beat ? 1 : 0, dt);
        return Fill(RGBF.Hsv(_flashHue, 1, 1) * MathF.Max(e, 0.03f + 0.12f * f.Level));
    }

    /// <summary>Random keys twinkle: more of them with more treble, a burst on each beat.</summary>
    private RGBF[] Sparkle(AudioFeatures f, double dt)
    {
        int n = Layout.LedCount;
        if (_sparkleLevel.Length != n) { _sparkleLevel = new float[n]; _sparkleHue = new float[n]; }
        float speed = (float)Settings.Speed;
        float rate = (0.15f + 6 * f.Treble * f.Level + (f.Beat ? 0.25f / (float)Math.Max(dt, 1e-3) : 0)) * speed;
        float chance = MathF.Min(1, rate * (float)dt * 0.25f);
        float decay = (float)Math.Exp(-dt * 3.5 * speed);
        float baseHue = RGBF.From(Settings.PrimaryColor).ToHsv().H;
        for (int i = 0; i < n; i++)
        {
            _sparkleLevel[i] *= decay;
            if (Random() < chance)
            {
                _sparkleLevel[i] = 0.6f + 0.4f * Random();
                _sparkleHue[i] = baseHue + (Random() - 0.5f) * 0.3f;
            }
        }
        var glow = RGBF.From(Settings.PrimaryColor) * (0.03f + 0.1f * f.Level);
        return Enumerable.Range(0, n).Select(i => glow + RGBF.Hsv(_sparkleHue[i], 0.75f, 1) * _sparkleLevel[i]).ToArray();
    }

    /// <summary>Flames rise from the bottom row; their height follows the bass and they flicker.</summary>
    private RGBF[] Fire(AudioFeatures f, double dt)
    {
        int n = Layout.LedCount;
        if (_heat.Length != n) _heat = new float[n];
        float flameHeight = 0.12f + 0.95f * MathF.Max(f.Bass, f.Level * 0.8f);
        float k = (float)(1 - Math.Exp(-dt / 0.06 * Settings.Speed));
        for (int i = 0; i < n; i++)
        {
            float h = 1 - Layout.Positions[i].Y;          // 0 at the bottom row
            float flicker = 0.7f + 0.3f * Random();
            float target = Math.Clamp((flameHeight - h) / 0.45f, 0, 1) * flicker;
            _heat[i] += (target - _heat[i]) * k;
        }
        return _heat.Select(t => new RGBF(MathF.Min(1, t * 2.2f), MathF.Min(1, MathF.Max(0, t * 2.2f - 0.9f)) * 0.75f, MathF.Max(0, t * 3 - 2.4f) * 0.5f)).ToArray();
    }

    /// <summary>Deterministic pseudo-random number in [0, 1) (seeded, so tests are repeatable).</summary>
    private float Random()
    {
        _rng = unchecked(_rng * 6_364_136_223_846_793_005 + 1_442_695_040_888_963_407);
        return (_rng >> 40) / (float)(1 << 24);
    }

    private RGBF[] ScreenMirror(ScreenGrid? screen, double dt)
    {
        int n = Layout.LedCount;
        if (_screenColors.Length != n) _screenColors = new RGBF[n];
        if (screen == null) return [.. _screenColors];
        // ~120 ms smoothing so video doesn't strobe the keyboard.
        float k = (float)(1 - Math.Exp(-dt / Math.Max(0.02, 0.12 * (1.2 - Settings.Smoothing))));
        float boost = (float)Settings.ScreenSaturation;
        float gain = (float)Math.Max(1, Settings.ScreenGain);
        for (int i = 0; i < n; i++)
        {
            var p = Layout.Positions[i];
            var c = screen.Sample(p.X, p.Y);
            if (boost > 0 || gain > 1)
            {
                var hsv = c.ToHsv();
                c = RGBF.Hsv(hsv.H, MathF.Min(1, hsv.S * (1 + boost * 1.5f)), MathF.Min(1, hsv.V * gain));
            }
            _screenColors[i] = _screenColors[i].Mix(c, k);
        }
        return [.. _screenColors];
    }
}

namespace BeatRGB.Core;

/// <summary>8-bit colour as sent to the keyboard.</summary>
public readonly record struct RGB8(byte R, byte G, byte B)
{
    public static readonly RGB8 Black = new(0, 0, 0);
}

/// <summary>Linear 0…1 float colour used while rendering.</summary>
public readonly record struct RGBF(float R, float G, float B)
{
    public static readonly RGBF Black = new(0, 0, 0);
    public static readonly RGBF White = new(1, 1, 1);

    public static RGBF operator *(RGBF c, float k) => new(c.R * k, c.G * k, c.B * k);
    public static RGBF operator +(RGBF a, RGBF b) => new(a.R + b.R, a.G + b.G, a.B + b.B);

    public RGBF Mix(RGBF other, float t)
    {
        t = Math.Clamp(t, 0, 1);
        return new(R + (other.R - R) * t, G + (other.G - G) * t, B + (other.B - B) * t);
    }

    public RGBF Clamped => new(Math.Clamp(R, 0, 1), Math.Clamp(G, 0, 1), Math.Clamp(B, 0, 1));
    public float Luminance => 0.2126f * R + 0.7152f * G + 0.0722f * B;

    public RGB8 ToRGB8()
    {
        var c = Clamped;
        return new((byte)MathF.Round(c.R * 255), (byte)MathF.Round(c.G * 255), (byte)MathF.Round(c.B * 255));
    }

    public static RGBF From(RGB8 c) => new(c.R / 255f, c.G / 255f, c.B / 255f);
    public static RGBF From(ColorValue c) => new((float)c.R, (float)c.G, (float)c.B);

    /// <summary>h in turns (0…1), s and v 0…1.</summary>
    public static RGBF Hsv(float h, float s, float v)
    {
        h = (h - MathF.Floor(h)) * 6;
        int i = (int)h % 6;
        float f = h - MathF.Floor(h);
        float p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f));
        return i switch
        {
            0 => new(v, t, p),
            1 => new(q, v, p),
            2 => new(p, v, t),
            3 => new(p, q, v),
            4 => new(t, p, v),
            _ => new(v, p, q),
        };
    }

    public (float H, float S, float V) ToHsv()
    {
        float mx = MathF.Max(R, MathF.Max(G, B)), mn = MathF.Min(R, MathF.Min(G, B)), d = mx - mn;
        float h = 0;
        if (d > 0)
        {
            if (mx == R) h = (G - B) / d; else if (mx == G) h = (B - R) / d + 2; else h = (R - G) / d + 4;
            h /= 6; if (h < 0) h += 1;
        }
        return (h, mx > 0 ? d / mx : 0, mx);
    }
}

/// <summary>Serializable colour for settings and profiles (0…1 components).</summary>
public sealed record ColorValue(double R, double G, double B)
{
    public static ColorValue FromHex(uint hex) =>
        new(((hex >> 16) & 0xFF) / 255.0, ((hex >> 8) & 0xFF) / 255.0, (hex & 0xFF) / 255.0);

    public string Hex => $"#{(int)(R * 255 + 0.5):X2}{(int)(G * 255 + 0.5):X2}{(int)(B * 255 + 0.5):X2}";

    public static readonly ColorValue Red = FromHex(0xFF0000);
}

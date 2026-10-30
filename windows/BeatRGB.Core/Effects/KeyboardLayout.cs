using BeatRGB.Core.OpenRGB;

namespace BeatRGB.Core.Effects;

/// <summary>
/// Physical position of every LED, derived from the matrix maps OpenRGB reports, so effects never assume a
/// fixed key arrangement and work on any keyboard.
/// </summary>
public sealed class KeyboardLayout
{
    public readonly record struct Cell(int Row, int Col);

    public int LedCount { get; }
    public int Rows { get; }
    public int Cols { get; }
    /// <summary>Grid cell per LED.</summary>
    public Cell[] Cells { get; }
    /// <summary>Normalised position (x left→right, y top→bottom), 0…1.</summary>
    public (float X, float Y)[] Positions { get; }
    public string[] Names { get; }

    public KeyboardLayout(Cell?[] cells, int rows, int cols, string[] names)
    {
        LedCount = cells.Length;
        Rows = Math.Max(1, rows);
        Cols = Math.Max(1, cols);
        Cells = cells.Select(c => c ?? new Cell(0, 0)).ToArray();
        Names = names;
        float rDen = Math.Max(1, Rows - 1), cDen = Math.Max(1, Cols - 1);
        Positions = cells.Select(c => c is { } cell ? (cell.Col / cDen, cell.Row / rDen) : (0.5f, 0.5f)).ToArray();
    }

    public static KeyboardLayout FromDevice(RGBDevice device)
    {
        int count = device.Leds.Count;
        var cells = new Cell?[count];
        int rows = 0, cols = 0, zoneStart = 0;
        foreach (var zone in device.Zones)
        {
            if (zone.Matrix is { } m)
            {
                // Stack multiple matrix zones vertically.
                for (int r = 0; r < m.Height; r++)
                    for (int c = 0; c < m.Width; c++)
                        if (m.Led(r, c) is { } led && zoneStart + (int)led < count)
                            cells[zoneStart + (int)led] = new Cell(rows + r, c);
                rows += m.Height;
                cols = Math.Max(cols, m.Width);
            }
            zoneStart += (int)zone.LedsCount;
        }
        // LEDs outside a matrix (logos, light bars, or a device without a matrix) go on extra rows.
        var unplaced = Enumerable.Range(0, count).Where(i => cells[i] == null).ToList();
        if (unplaced.Count > 0)
        {
            int width = Math.Max(cols, Math.Min(unplaced.Count, 22));
            for (int i = 0; i < unplaced.Count; i++) cells[unplaced[i]] = new Cell(rows + i / width, i % width);
            rows += (unplaced.Count + width - 1) / width;
            cols = width;
        }
        return new KeyboardLayout(cells, rows, cols, device.Leds.Select(l => l.Name).ToArray());
    }

    /// <summary>Simple rows×cols grid (preview before a device is connected, and tests).</summary>
    public static KeyboardLayout Grid(int rows, int cols)
    {
        var cells = new List<Cell?>();
        for (int r = 0; r < rows; r++) for (int c = 0; c < cols; c++) cells.Add(new Cell(r, c));
        return new KeyboardLayout([.. cells], rows, cols, cells.Select(_ => "").ToArray());
    }

    /// <summary>A TKL-shaped placeholder (6×17) used until the real map arrives.</summary>
    public static readonly KeyboardLayout PlaceholderTKL = Grid(6, 17);
}

/// <summary>Low-resolution snapshot of a display, row-major, top-left origin.</summary>
public sealed class ScreenGrid(int width, int height, RGBF[] pixels)
{
    public const int DefaultWidth = 34, DefaultHeight = 12;
    public int Width { get; } = width;
    public int Height { get; } = height;
    public RGBF[] Pixels { get; } = pixels;

    /// <summary>Bilinear sample at normalised (x, y).</summary>
    public RGBF Sample(float x, float y)
    {
        if (Width <= 0 || Height <= 0 || Pixels.Length != Width * Height) return RGBF.Black;
        float fx = Math.Clamp(x, 0, 1) * (Width - 1), fy = Math.Clamp(y, 0, 1) * (Height - 1);
        int x0 = (int)fx, y0 = (int)fy;
        int x1 = Math.Min(x0 + 1, Width - 1), y1 = Math.Min(y0 + 1, Height - 1);
        float tx = fx - x0, ty = fy - y0;
        var top = Pixels[y0 * Width + x0].Mix(Pixels[y0 * Width + x1], tx);
        var bottom = Pixels[y1 * Width + x0].Mix(Pixels[y1 * Width + x1], tx);
        return top.Mix(bottom, ty);
    }

    /// <summary>Box-averages a BGRA pixel buffer into a gw × gh colour grid.</summary>
    public static ScreenGrid FromBGRA(ReadOnlySpan<byte> px, int w, int h, int stride, int gw = DefaultWidth, int gh = DefaultHeight)
    {
        var pixels = new RGBF[gw * gh];
        for (int gy = 0; gy < gh; gy++)
        {
            int y0 = gy * h / gh, y1 = Math.Max(y0 + 1, (gy + 1) * h / gh);
            for (int gx = 0; gx < gw; gx++)
            {
                int x0 = gx * w / gw, x1 = Math.Max(x0 + 1, (gx + 1) * w / gw);
                long r = 0, g = 0, b = 0;
                for (int y = y0; y < y1; y++)
                    for (int x = x0; x < x1; x++)
                    {
                        int p = y * stride + x * 4;
                        b += px[p]; g += px[p + 1]; r += px[p + 2];
                    }
                float n = (y1 - y0) * (x1 - x0) * 255f;
                pixels[gy * gw + gx] = new RGBF(r / n, g / n, b / n);
            }
        }
        return new ScreenGrid(gw, gh, pixels);
    }
}

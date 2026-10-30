using System.Drawing.Drawing2D;
using BeatRGB.Core;
using BeatRGB.Core.Effects;

namespace BeatRGB.Windows;

/// <summary>Draws the colours being sent, one rounded key per LED, laid out from the keyboard's own map.</summary>
public sealed class KeyboardPreview : Control
{
    private KeyboardLayout _layout = KeyboardLayout.PlaceholderTKL;
    private RGB8[] _frame = [];

    public KeyboardPreview()
    {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
        BackColor = Color.FromArgb(18, 18, 22);
    }

    public void Display(KeyboardLayout layout, RGB8[] frame)
    {
        _layout = layout;
        _frame = frame;
        Invalidate();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.Clear(BackColor);
        int rows = _layout.Rows, cols = _layout.Cols;
        float pad = 10, gap = 4;
        float cell = Math.Min((Width - 2 * pad) / cols, (Height - 2 * pad) / rows);
        if (cell <= gap) return;
        float ox = (Width - cell * cols) / 2, oy = (Height - cell * rows) / 2;
        for (int i = 0; i < _layout.LedCount; i++)
        {
            var c = _layout.Cells[i];
            var rgb = i < _frame.Length ? _frame[i] : new RGB8(40, 40, 46);
            var rect = new RectangleF(ox + c.Col * cell + gap / 2, oy + c.Row * cell + gap / 2, cell - gap, cell - gap);
            using var path = Rounded(rect, Math.Max(2, cell * 0.18f));
            using var fill = new SolidBrush(Color.FromArgb(Math.Max((int)rgb.R, 28), Math.Max((int)rgb.G, 28), Math.Max((int)rgb.B, 32)));
            g.FillPath(fill, path);
        }
    }

    private static GraphicsPath Rounded(RectangleF r, float radius)
    {
        var p = new GraphicsPath();
        float d = radius * 2;
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }
}

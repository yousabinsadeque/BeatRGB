using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using BeatRGB.Core.Effects;

namespace BeatRGB.Windows;

/// <summary>
/// Samples one display about 20 times a second into a coarse colour grid for the Screen Mirror effect,
/// using GDI StretchBlt with HALFTONE averaging. Nothing is recorded or stored.
/// </summary>
public sealed class ScreenSampler : IDisposable
{
    private const int SampleW = ScreenGrid.DefaultWidth * 4, SampleH = ScreenGrid.DefaultHeight * 4;
    private readonly Bitmap _bitmap = new(SampleW, SampleH, PixelFormat.Format32bppArgb);
    private readonly byte[] _pixels = new byte[SampleW * SampleH * 4];
    private volatile ScreenGrid? _latest;
    private System.Threading.Timer? _timer;
    private Rectangle _bounds;
    private int _busy;

    public ScreenGrid? Latest => _latest;
    public string Description { get; private set; } = "Stopped";

    public void Start(int displayIndex)
    {
        Stop();
        var screens = Screen.AllScreens;
        var screen = displayIndex >= 0 && displayIndex < screens.Length ? screens[displayIndex] : Screen.PrimaryScreen!;
        _bounds = screen.Bounds;
        Description = $"Display {Array.IndexOf(screens, screen) + 1} ({_bounds.Width}×{_bounds.Height})";
        _timer = new System.Threading.Timer(_ => Capture(), null, 0, 50);
    }

    public void Stop()
    {
        _timer?.Dispose();
        _timer = null;
        _latest = null;
        Description = "Stopped";
    }

    private void Capture()
    {
        if (Interlocked.Exchange(ref _busy, 1) == 1) return;
        try
        {
            using (var g = Graphics.FromImage(_bitmap))
            {
                IntPtr dest = g.GetHdc(), src = GetDC(IntPtr.Zero);
                try
                {
                    SetStretchBltMode(dest, HALFTONE);
                    SetBrushOrgEx(dest, 0, 0, IntPtr.Zero);
                    StretchBlt(dest, 0, 0, SampleW, SampleH, src, _bounds.X, _bounds.Y, _bounds.Width, _bounds.Height, SRCCOPY);
                }
                finally
                {
                    ReleaseDC(IntPtr.Zero, src);
                    g.ReleaseHdc(dest);
                }
            }
            var data = _bitmap.LockBits(new Rectangle(0, 0, SampleW, SampleH), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            try
            {
                for (int y = 0; y < SampleH; y++) Marshal.Copy(data.Scan0 + y * data.Stride, _pixels, y * SampleW * 4, SampleW * 4);
            }
            finally { _bitmap.UnlockBits(data); }
            _latest = ScreenGrid.FromBGRA(_pixels, SampleW, SampleH, SampleW * 4);
        }
        catch (Exception e)
        {
            Description = $"Screen capture failed: {e.Message}";
        }
        finally { Interlocked.Exchange(ref _busy, 0); }
    }

    public void Dispose()
    {
        Stop();
        _bitmap.Dispose();
    }

    private const int HALFTONE = 4;
    private const int SRCCOPY = 0x00CC0020;
    [DllImport("user32.dll")] private static extern IntPtr GetDC(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
    [DllImport("gdi32.dll")] private static extern int SetStretchBltMode(IntPtr hdc, int mode);
    [DllImport("gdi32.dll")] private static extern bool SetBrushOrgEx(IntPtr hdc, int x, int y, IntPtr lppt);
    [DllImport("gdi32.dll")]
    private static extern bool StretchBlt(IntPtr hdcDest, int xDest, int yDest, int wDest, int hDest,
                                          IntPtr hdcSrc, int xSrc, int ySrc, int wSrc, int hSrc, int rop);
}

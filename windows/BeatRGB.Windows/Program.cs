using System.Runtime.InteropServices;

namespace BeatRGB.Windows;

internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        using var mutex = new Mutex(true, @"Local\BeatRGB", out bool first);
        if (!first)
        {
            MessageBox.Show("BeatRGB is already running — look for its icon in the notification area.", "BeatRGB");
            return;
        }
        // 1 ms timer resolution so the lighting loop keeps an even frame rate.
        timeBeginPeriod(1);
        try
        {
            Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainForm(startInBackground: args.Contains("--background")));
        }
        finally { timeEndPeriod(1); }
    }

    [DllImport("winmm.dll")] private static extern uint timeBeginPeriod(uint period);
    [DllImport("winmm.dll")] private static extern uint timeEndPeriod(uint period);
}

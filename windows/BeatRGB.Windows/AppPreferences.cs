using System.Text.Json.Serialization;
using BeatRGB.Core.Engine;
using BeatRGB.Core.OpenRGB;
using Microsoft.Win32;

namespace BeatRGB.Windows;

/// <summary>App-wide preferences, stored in %APPDATA%\BeatRGB\settings.json.</summary>
public sealed class AppPreferences
{
    public string Host { get; set; } = "127.0.0.1";
    public int Port { get; set; } = OpenRGBProtocol.DefaultPort;
    /// <summary>OpenRGB device picked by name; null = first RGB keyboard found.</summary>
    public string? DeviceName { get; set; }
    public string? LockedSerial { get; set; }
    public bool AutoReconnect { get; set; } = true;
    [JsonConverter(typeof(JsonStringEnumConverter<StopBehavior>))]
    public StopBehavior StopBehavior { get; set; } = StopBehavior.RestorePrevious;
    public bool OpenInBackground { get; set; }
    public bool StartSyncOnLaunch { get; set; }

    [JsonIgnore]
    public EngineConfig EngineConfig => new()
    {
        Host = Host,
        Port = Port,
        Matcher = new DeviceMatcher(LockedSerial, DeviceName),
        AutoReconnect = AutoReconnect,
        StopBehavior = StopBehavior,
    };
}

/// <summary>Start BeatRGB when you sign in to Windows (per-user Run key, no admin rights needed).</summary>
public static class LaunchAtLogin
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "BeatRGB";

    public static bool Enabled
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(ValueName) is string;
        }
        set
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (value) key.SetValue(ValueName, $"\"{Environment.ProcessPath}\" --background");
            else key.DeleteValue(ValueName, throwOnMissingValue: false);
        }
    }
}

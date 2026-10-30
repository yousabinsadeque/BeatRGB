using System.Collections.Concurrent;
using System.Diagnostics;
using BeatRGB.Core.Audio;
using BeatRGB.Core.Effects;
using BeatRGB.Core.OpenRGB;

namespace BeatRGB.Core.Engine;

public enum StopBehavior { RestorePrevious, IdleEffect, Off }

public static class StopBehaviorInfo
{
    public static string Title(this StopBehavior b) => b switch
    {
        StopBehavior.RestorePrevious => "Restore previous lighting",
        StopBehavior.IdleEffect => "Show idle colour",
        _ => "Turn lights off",
    };
}

public sealed record EngineConfig
{
    public string Host { get; init; } = "127.0.0.1";
    public int Port { get; init; } = OpenRGBProtocol.DefaultPort;
    public DeviceMatcher Matcher { get; init; } = DeviceMatcher.Automatic;
    public bool AutoReconnect { get; init; } = true;
    public StopBehavior StopBehavior { get; init; } = StopBehavior.RestorePrevious;

    internal string DriverKey => $"{Host}|{Port}|{Matcher.Serial}|{Matcher.Name}";
}

public enum ConnectionStatus { Disconnected, Connecting, Connected, Failed }

/// <summary>Immutable copy of the engine's state, published to the UI about 20 times a second.</summary>
public sealed record EngineSnapshot
{
    public bool Running { get; init; }
    public ConnectionStatus Connection { get; init; }
    public string ConnectionInfo { get; init; } = "";
    public DeviceIdentity? Device { get; init; }
    public int LedCount { get; init; }
    public string Mode { get; init; } = "";
    public IReadOnlyList<string> AvailableDevices { get; init; } = [];
    public KeyboardLayout Layout { get; init; } = KeyboardLayout.PlaceholderTKL;
    public RGB8[] Frame { get; init; } = [];
    public AudioFeatures Features { get; init; } = AudioFeatures.Silent(0);
    public double Fps { get; init; }
    public double TargetFps { get; init; } = 30;
    public double LatencyMs { get; init; }
    public int FramesSent { get; init; }
    public string? LastError { get; init; }
    public IReadOnlyList<string> Log { get; init; } = [];
}

/// <summary>
/// Owns the OpenRGB connection and the render loop. All mutable state lives on one worker thread; public
/// methods post work to it.
/// </summary>
public sealed class LightingEngine : IDisposable
{
    public event Action<EngineSnapshot>? SnapshotChanged;

    private readonly BlockingCollection<Action> _queue = [];
    private readonly Thread _thread;
    private readonly Stopwatch _clock = Stopwatch.StartNew();
    private readonly AudioAnalyzer _analyzer = new();
    private readonly EffectRenderer _renderer = new();
    private readonly Dictionary<string, RGB8[]> _originalColors = [];
    private readonly List<string> _log = [];
    private EngineConfig _config = new();
    private OpenRGBClient? _client;
    private string _clientKey = "";
    private RGBDevice? _device;
    private KeyboardLayout _layout = KeyboardLayout.PlaceholderTKL;
    private SampleRing? _ring;
    private Func<ScreenGrid?>? _screen;
    private bool _running, _disposed;
    private double _lastTick, _nextFrame, _lastSendTime, _lastHealth, _nextRetry, _retryDelay = 1, _currentFps = 30, _lastPublish;
    private RGB8[] _lastSent = [], _frame = [];
    private (double Start, int Frames) _fpsWindow;
    private AudioFeatures _features = AudioFeatures.Silent(0);
    private ConnectionStatus _connection;
    private string _connectionInfo = "";
    private IReadOnlyList<string> _available = [];
    private double _fps, _latency;
    private int _framesSent;
    private string? _lastError;

    public LightingEngine()
    {
        _thread = new Thread(Loop) { IsBackground = true, Name = "BeatRGB engine", Priority = ThreadPriority.AboveNormal };
        _thread.Start();
    }

    private double Now => _clock.Elapsed.TotalSeconds;

    // Public API (thread-safe)

    public void Configure(EngineConfig c) => Post(() =>
    {
        bool changed = c.DriverKey != _config.DriverKey;
        if (changed && _device != null) Finish(_config.StopBehavior);
        _config = c;
        if (changed)
        {
            CloseClient();
            if (_running) { _nextRetry = 0; _retryDelay = 1; }
            Publish(true);
        }
    });

    public void Update(LightingSettings settings) => Post(() =>
    {
        _renderer.Settings = settings.Copy();
        _analyzer.Settings = settings.AnalyzerSettings;
        if (_currentFps > settings.TargetFPS || !_running) _currentFps = Math.Clamp(settings.TargetFPS, 5, 60);
    });

    public void SetAudioSource(SampleRing? ring) => Post(() => { _ring = ring; _analyzer.Reset(); });

    public void SetScreenSource(Func<ScreenGrid?>? screen) => Post(() => _screen = screen);

    public void Start() => Post(() =>
    {
        if (_running) return;
        _running = true;
        _nextRetry = 0; _retryDelay = 1;
        _lastTick = Now; _nextFrame = Now;
        _currentFps = Math.Clamp(_renderer.Settings.TargetFPS, 5, 60);
        _analyzer.Reset();
        Log("Sync started");
        Publish(true);
    });

    public Task StopAsync() => Run(() =>
    {
        if (_running) Log("Sync stopped");
        _running = false;
        _fps = 0;
        if (_device != null) Finish(_config.StopBehavior);
        CloseClient();
        Publish(true);
    });

    /// <summary>Hardware proof: open the keyboard if needed and paint every key one colour.</summary>
    public Task<string> SendTestColorAsync(RGB8 color) => Run(() =>
    {
        try
        {
            EnsureDevice();
            var colors = Enumerable.Repeat(color, _device!.Leds.Count).ToArray();
            _client!.UpdateLEDs(_device.Index, colors);
            _frame = colors;
            HealthCheck();   // round trip so OpenRGB has applied the frame
            var detail = $"Sent #{color.R:X2}{color.G:X2}{color.B:X2} to {colors.Length} LEDs on {_device.Name} via OpenRGB";
            Log(detail);
            Publish(true);
            return detail;
        }
        catch (Exception e)
        {
            Handle(e);
            return $"Failed: {e.Message}";
        }
    });

    /// <summary>Lists every controller OpenRGB reports (for the device picker and diagnostics).</summary>
    public Task<List<RGBDevice>> ScanAsync() => Run(() =>
    {
        using var c = new OpenRGBClient(_config.Host, _config.Port);
        c.Connect();
        return c.AllControllers();
    });

    public void Dispose()
    {
        if (_disposed) return;
        StopAsync().Wait(TimeSpan.FromSeconds(3));
        Post(() => _disposed = true);
        _thread.Join(TimeSpan.FromSeconds(2));
    }

    private void Post(Action a) { if (!_queue.IsAddingCompleted) _queue.Add(a); }

    private Task Run(Action a) => Run(() => { a(); return true; });

    private Task<T> Run<T>(Func<T> f)
    {
        var tcs = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        Post(() => { try { tcs.SetResult(f()); } catch (Exception e) { tcs.SetException(e); } });
        return tcs.Task;
    }

    // Loop

    private void Loop()
    {
        while (!_disposed)
        {
            int wait = _running ? Math.Max(0, (int)((_nextFrame - Now) * 1000)) : 250;
            if (_queue.TryTake(out var action, wait)) { action(); continue; }
            if (_running && Now >= _nextFrame)
            {
                _nextFrame = Math.Max(_nextFrame + 1 / _currentFps, Now);
                try { Tick(); } catch (Exception e) { Handle(e); }
            }
        }
    }

    private void Tick()
    {
        double now = Now;
        double dt = Math.Clamp(now - _lastTick, 0.001, 0.1);
        _lastTick = now;

        _features = _ring != null ? _analyzer.Analyze(_ring.Take(_analyzer.FftSize), dt) : AudioFeatures.Silent(_analyzer.BandCount);
        var colors = _renderer.Render(_features, _screen?.Invoke(), dt).Select(c => c.ToRGB8()).ToArray();
        _frame = colors;

        if (_device == null && now >= _nextRetry)
        {
            try { EnsureDevice(); } catch (Exception e) { Handle(e); }
        }
        if (_client != null && _device != null)
        {
            try
            {
                _client.PollNotifications();
                if (_client.DeviceListChanged)
                {
                    Log("Device list changed; re-checking the keyboard");
                    _device = null;
                    EnsureDevice();
                    Publish(true);
                    return;
                }
                if (colors.Length == _device.Leds.Count && (!colors.AsSpan().SequenceEqual(_lastSent) || now - _lastSendTime > 1))
                {
                    _client.UpdateLEDs(_device.Index, colors);
                    _lastSent = colors;
                    _lastSendTime = now;
                    _framesSent++;
                }
                _fpsWindow.Frames++;
                if (now - _lastHealth > 1)
                {
                    _lastHealth = now;
                    _latency = HealthCheck();
                    Adapt(_latency);
                }
            }
            catch (Exception e) { Handle(e); }
        }
        if (now - _fpsWindow.Start >= 1)
        {
            _fps = _fpsWindow.Start > 0 ? _fpsWindow.Frames / (now - _fpsWindow.Start) : 0;
            _fpsWindow = (now, 0);
        }
        Publish(false);
    }

    /// <summary>Lowers the frame rate when OpenRGB can't keep up, and recovers slowly.</summary>
    private void Adapt(double latencyMs)
    {
        double frameMs = 1000 / _currentFps, target = _renderer.Settings.TargetFPS;
        if (latencyMs > frameMs * 2 && _currentFps > 10)
        {
            _currentFps *= 0.8;
            Log($"Keyboard path is slow ({latencyMs:F0} ms); throttling to {_currentFps:F0} fps");
        }
        else if (latencyMs < frameMs * 0.5 && _currentFps < target) _currentFps = Math.Min(target, _currentFps * 1.1 + 1);
    }

    // Device

    private OpenRGBClient Client()
    {
        if (_client is { IsConnected: true } && _clientKey == _config.DriverKey) return _client;
        CloseClient();
        _connection = ConnectionStatus.Connecting;
        Publish(true);
        var c = new OpenRGBClient(_config.Host, _config.Port);
        c.Connect();
        _client = c;
        _clientKey = _config.DriverKey;
        Log($"Connected to OpenRGB SDK at {_config.Host}:{_config.Port} (server v{c.ServerProtocolVersion}, using v{c.ProtocolVersion})");
        return c;
    }

    private void EnsureDevice()
    {
        if (_device != null && _client is { IsConnected: true }) return;
        var c = Client();
        var devices = c.AllControllers();
        _available = devices.Select(d => d.Name).ToList();
        var found = _config.Matcher.Select(devices)
            ?? throw new OpenRGBException("No matching RGB keyboard found" + (devices.Count == 0 ? " (OpenRGB reports no devices)." : $". Available: {string.Join(", ", _available)}."));
        _originalColors.TryAdd(found.Serial, [.. found.Colors]);
        _device = c.EnableDirectMode(found);
        _layout = KeyboardLayout.FromDevice(_device);
        _renderer.SetLayout(_layout);
        _lastSent = [];
        _retryDelay = 1;
        _connection = ConnectionStatus.Connected;
        _connectionInfo = $"OpenRGB at {_config.Host}:{_config.Port} · server protocol v{c.ServerProtocolVersion}, using v{c.ProtocolVersion}";
        _lastError = null;
        Log($"Using {_device.Name} (index {_device.Index}, {_device.Leds.Count} LEDs, {_layout.Rows}×{_layout.Cols} map) in {_device.ActiveModeName} mode");
        Publish(true);
    }

    /// <summary>
    /// Round-trips a controller-data request through OpenRGB's per-device queue: verifies identity and
    /// Direct mode, and its latency drives adaptive throttling.
    /// </summary>
    private double HealthCheck()
    {
        var t0 = Now;
        var current = _client!.Controller(_device!.Index);
        double rtt = (Now - t0) * 1000;
        if (current.Identity != _device.Identity) throw new OpenRGBException($"Device at index {_device.Index} changed identity");
        if (!current.ActiveModeIsDirect)
        {
            Log($"Keyboard left Direct mode (now {current.ActiveModeName}) — another app may be controlling it. Re-enabling.");
            _device = _client.EnableDirectMode(current);
        }
        return rtt;
    }

    private void Finish(StopBehavior behavior)
    {
        if (_client is not { IsConnected: true } || _device == null) return;
        int n = _device.Leds.Count;
        var colors = behavior switch
        {
            StopBehavior.RestorePrevious => _originalColors.GetValueOrDefault(_device.Serial) ?? new RGB8[n],
            StopBehavior.IdleEffect => IdleColors(),
            _ => new RGB8[n],
        };
        if (colors.Length != n) return;
        try
        {
            _client.UpdateLEDs(_device.Index, colors);
            // Round-trip through OpenRGB's device queue so the frame is applied before we hang up.
            _client.Controller(_device.Index);
            Log($"On stop: {behavior.Title().ToLowerInvariant()}");
        }
        catch (Exception e) { Log($"Could not apply stop lighting: {e.Message}"); }
    }

    private RGB8[] IdleColors() => _renderer.IdleFrame().Select(c => (c * (float)_renderer.Settings.Brightness).ToRGB8()).ToArray();

    private void CloseClient()
    {
        _client?.Dispose();
        _client = null;
        _device = null;
        _lastSent = [];
        _connection = ConnectionStatus.Disconnected;
    }

    private void Handle(Exception error)
    {
        string message = error.Message;
        if (_lastError != message) Log($"Error: {message}");
        _lastError = message;
        CloseClient();
        _connection = ConnectionStatus.Failed;
        if (_running && _config.AutoReconnect)
        {
            _nextRetry = Now + _retryDelay;
            _retryDelay = Math.Min(5, _retryDelay * 2);
        }
        else if (_running) _nextRetry = double.PositiveInfinity;
        Publish(true);
    }

    private void Log(string line)
    {
        _log.Add($"{DateTime.Now:HH:mm:ss}  {line}");
        if (_log.Count > 200) _log.RemoveRange(0, _log.Count - 200);
    }

    private void Publish(bool force)
    {
        double now = Now;
        if (!force && now - _lastPublish < 1.0 / 20) return;
        _lastPublish = now;
        SnapshotChanged?.Invoke(new EngineSnapshot
        {
            Running = _running,
            Connection = _connection,
            ConnectionInfo = _connectionInfo,
            Device = _device?.Identity,
            LedCount = _device?.Leds.Count ?? 0,
            Mode = _device?.ActiveModeName ?? "",
            AvailableDevices = _available,
            Layout = _layout,
            Frame = _frame,
            Features = _features,
            Fps = _fps,
            TargetFps = _renderer.Settings.TargetFPS,
            LatencyMs = _latency,
            FramesSent = _framesSent,
            LastError = _lastError,
            Log = [.. _log],
        });
    }
}

using BeatRGB.Core.Audio;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace BeatRGB.Windows;

/// <summary>
/// Hears everything Windows plays through the default output device using WASAPI loopback capture.
/// Playback is unchanged and no microphone is involved. Follows the default device when it changes.
/// </summary>
public sealed class SystemAudioCapture : IDisposable
{
    public SampleRing Ring { get; } = new(16384);
    public event Action<string>? StateChanged;

    private WasapiLoopbackCapture? _capture;
    private float[] _mono = [];
    private bool _stopping;
    private readonly MMDeviceEnumerator _devices = new();
    private readonly DeviceNotifications _notifications;

    public SystemAudioCapture()
    {
        _notifications = new DeviceNotifications(() => { if (_capture != null && !_stopping) Restart(); });
        _devices.RegisterEndpointNotificationCallback(_notifications);
    }

    public void Start()
    {
        _stopping = false;
        try
        {
            var device = _devices.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
            var c = new WasapiLoopbackCapture(device);
            c.DataAvailable += OnData;
            c.RecordingStopped += (_, e) =>
            {
                if (e.Exception != null) StateChanged?.Invoke($"Audio capture stopped: {e.Exception.Message}");
            };
            Ring.SampleRate = c.WaveFormat.SampleRate;
            c.StartRecording();
            _capture = c;
            StateChanged?.Invoke($"System audio · {device.FriendlyName} · {c.WaveFormat.SampleRate / 1000.0:0.#} kHz");
        }
        catch (Exception e)
        {
            StateChanged?.Invoke($"System audio unavailable: {e.Message}");
        }
    }

    public void Stop()
    {
        _stopping = true;
        var c = _capture;
        _capture = null;
        if (c == null) return;
        c.DataAvailable -= OnData;
        try { c.StopRecording(); } catch { }
        c.Dispose();
        StateChanged?.Invoke("Stopped");
    }

    private void Restart()
    {
        Stop();
        Start();
    }

    /// <summary>Mixes the loopback buffer (normally 32-bit float) down to mono for the analyzer.</summary>
    private void OnData(object? sender, WaveInEventArgs e)
    {
        if (sender is not WasapiLoopbackCapture c) return;
        var fmt = c.WaveFormat;
        int channels = Math.Max(1, fmt.Channels);
        int bytesPerSample = fmt.BitsPerSample / 8;
        int frames = e.BytesRecorded / (bytesPerSample * channels);
        if (_mono.Length < frames) _mono = new float[frames];
        var span = e.Buffer.AsSpan(0, e.BytesRecorded);
        // The shared-mode mix format is normally 32-bit float, often wrapped in WAVE_FORMAT_EXTENSIBLE.
        bool isFloat = fmt.Encoding == WaveFormatEncoding.IeeeFloat || (fmt.Encoding == WaveFormatEncoding.Extensible && fmt.BitsPerSample == 32);
        for (int f = 0; f < frames; f++)
        {
            float sum = 0;
            for (int ch = 0; ch < channels; ch++)
            {
                int o = (f * channels + ch) * bytesPerSample;
                sum += isFloat && bytesPerSample == 4 ? BitConverter.ToSingle(span.Slice(o, 4))
                    : bytesPerSample == 2 ? BitConverter.ToInt16(span.Slice(o, 2)) / 32768f
                    : bytesPerSample == 4 ? BitConverter.ToInt32(span.Slice(o, 4)) / 2147483648f
                    : 0;
            }
            _mono[f] = sum / channels;
        }
        Ring.Append(_mono.AsSpan(0, frames));
    }

    public void Dispose()
    {
        Stop();
        try { _devices.UnregisterEndpointNotificationCallback(_notifications); } catch { }
        _devices.Dispose();
    }

    private sealed class DeviceNotifications(Action defaultChanged) : NAudio.CoreAudioApi.Interfaces.IMMNotificationClient
    {
        public void OnDefaultDeviceChanged(DataFlow flow, Role role, string defaultDeviceId)
        {
            if (flow == DataFlow.Render && role == Role.Multimedia) ThreadPool.QueueUserWorkItem(_ => defaultChanged());
        }
        public void OnDeviceStateChanged(string deviceId, DeviceState newState) { }
        public void OnDeviceAdded(string pwstrDeviceId) { }
        public void OnDeviceRemoved(string deviceId) { }
        public void OnPropertyValueChanged(string pwstrDeviceId, NAudio.CoreAudioApi.PropertyKey key) { }
    }
}

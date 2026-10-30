namespace BeatRGB.Core.Audio;

/// <summary>
/// Lock-protected mono sample ring. The capture callback only copies into it (no analysis), and the
/// lighting engine snapshots the most recent window at frame rate.
/// </summary>
public sealed class SampleRing(int capacity = 8192, double sampleRate = 48_000)
{
    private readonly float[] _buffer = new float[capacity];
    private readonly object _lock = new();
    private int _writeIndex, _filled, _framesSinceRead;
    private double _sumSquares;
    private float _peak;
    private double _sampleRate = sampleRate;

    public double SampleRate { get { lock (_lock) return _sampleRate; } set { lock (_lock) _sampleRate = value; } }

    public void Append(ReadOnlySpan<float> samples)
    {
        lock (_lock)
        {
            int cap = _buffer.Length;
            foreach (var s in samples)
            {
                _buffer[_writeIndex] = s;
                _writeIndex = (_writeIndex + 1) % cap;
                _sumSquares += s * s;
                float a = MathF.Abs(s);
                if (a > _peak) _peak = a;
            }
            _filled = Math.Min(cap, _filled + samples.Length);
            _framesSinceRead += samples.Length;
        }
    }

    public readonly record struct Snapshot(float[] Window, float Rms, float Peak, int NewFrames, double SampleRate);

    /// <summary>Copies the most recent count samples (zero-padded at the front if not yet filled).</summary>
    public Snapshot Take(int count)
    {
        var output = new float[count];
        lock (_lock)
        {
            int cap = _buffer.Length;
            int n = Math.Min(count, Math.Min(_filled, cap));
            int idx = (_writeIndex - n + cap) % cap;
            for (int i = count - n; i < count; i++)
            {
                output[i] = _buffer[idx];
                idx = (idx + 1) % cap;
            }
            int frames = _framesSinceRead;
            float rms = frames > 0 ? (float)Math.Sqrt(_sumSquares / frames) : 0;
            var snap = new Snapshot(output, rms, _peak, frames, _sampleRate);
            _sumSquares = 0; _peak = 0; _framesSinceRead = 0;
            return snap;
        }
    }

    public void Reset()
    {
        lock (_lock)
        {
            Array.Clear(_buffer);
            _writeIndex = 0; _filled = 0; _sumSquares = 0; _peak = 0; _framesSinceRead = 0;
        }
    }
}

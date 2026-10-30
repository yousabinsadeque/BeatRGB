namespace BeatRGB.Core.Audio;

/// <summary>Per-frame summary of the music handed to lighting effects. All values are 0…1 unless noted.</summary>
public sealed class AudioFeatures(int bandCount)
{
    public float[] Bands { get; } = new float[bandCount];
    public float Level { get; set; }            // smoothed, gain-normalized loudness
    public float RmsDB { get; set; } = -120;    // raw RMS in dBFS
    public float Bass { get; set; }
    public float Mid { get; set; }
    public float Treble { get; set; }
    public bool Beat { get; set; }              // bass onset detected this frame
    public bool IsSilent { get; set; } = true;  // below the noise gate long enough to go idle
    public bool HasSignal { get; set; }         // any samples arrived since last frame

    public static AudioFeatures Silent(int bandCount) => new(bandCount);
}

public sealed record AnalyzerSettings
{
    /// <summary>0.2…2. Higher = more dynamic range shown, i.e. quieter detail lights up.</summary>
    public float Sensitivity { get; init; } = 1;
    /// <summary>0…1. Higher = slower release, smoother look.</summary>
    public float Smoothing { get; init; } = 0.5f;
    /// <summary>0…2 multiplier for bass energy.</summary>
    public float BassResponse { get; init; } = 1;
    /// <summary>Noise gate in dBFS; quieter audio counts as silence.</summary>
    public float NoiseGateDB { get; init; } = -60;
    public bool NoiseGateEnabled { get; init; } = true;
    /// <summary>Seconds of silence before IsSilent becomes true.</summary>
    public double SilenceHold { get; init; } = 1.5;
    public bool AdaptiveGain { get; init; } = true;
}

/// <summary>
/// FFT spectrum analyzer: Hann window → real FFT → log-spaced bands with adaptive gain, noise gating and
/// attack/release smoothing, plus bass onset detection. A port of BeatRGBKit's AudioAnalyzer.swift.
/// </summary>
public sealed class AudioAnalyzer
{
    public int FftSize { get; }
    public int BandCount { get; }
    public AnalyzerSettings Settings { get; set; } = new();

    private readonly float[] _window;
    private readonly float[] _re, _im, _power;
    private readonly Envelope[] _bandEnvelopes;
    private Envelope _levelEnv = new(0.02, 0.25), _bassEnv = new(0.01, 0.15), _midEnv = new(0.02, 0.2), _trebleEnv = new(0.01, 0.15);
    private AdaptiveGain _spectrumGain = new(), _levelGain = new(initialDB: -25), _bassGain = new(), _midGain = new(), _trebleGain = new();
    private float _bassAverage;
    private double _lastBeat = -1, _clock, _silentFor = 10;

    public AudioAnalyzer(int fftSize = 2048, int bandCount = 24)
    {
        if (fftSize <= 0 || (fftSize & (fftSize - 1)) != 0) throw new ArgumentException("fftSize must be a power of two");
        FftSize = fftSize;
        BandCount = bandCount;
        // Same as vDSP's normalised Hann window: 0.8165 × (1 − cos 2πn/N).
        _window = Enumerable.Range(0, fftSize).Select(n => (float)(0.8165 * (1 - Math.Cos(2 * Math.PI * n / fftSize)))).ToArray();
        _re = new float[fftSize];
        _im = new float[fftSize];
        _power = new float[fftSize / 2];
        _bandEnvelopes = Enumerable.Range(0, bandCount).Select(_ => new Envelope(0.015, 0.18)).ToArray();
    }

    public void Reset()
    {
        for (int i = 0; i < _bandEnvelopes.Length; i++) _bandEnvelopes[i].Reset();
        _levelEnv.Reset(); _bassEnv.Reset(); _midEnv.Reset(); _trebleEnv.Reset();
        _bassAverage = 0; _silentFor = 10;
    }

    /// <summary>Lower/upper frequency edges (Hz) of each log-spaced band.</summary>
    public static double[] BandEdges(int count, double low = 30, double high = 16_000) =>
        Enumerable.Range(0, count + 1).Select(i => low * Math.Pow(high / low, (double)i / count)).ToArray();

    public AudioFeatures Analyze(SampleRing.Snapshot snap, double dt)
    {
        var s = Settings;
        _clock += dt;
        var f = new AudioFeatures(BandCount) { HasSignal = snap.NewFrames > 0, RmsDB = Db.FromLinear(snap.Rms) };

        // Smoothing 0…1 → release 60 ms…600 ms.
        double release = 0.06 + s.Smoothing * 0.54;
        for (int i = 0; i < _bandEnvelopes.Length; i++) _bandEnvelopes[i].Release = release;
        _levelEnv.Release = release * 1.3;
        _bassEnv.Release = release * 0.8;
        _midEnv.Release = release;
        _trebleEnv.Release = release * 0.8;

        bool gated = s.NoiseGateEnabled && f.RmsDB < s.NoiseGateDB;
        _silentFor = gated || !f.HasSignal ? _silentFor + dt : 0;
        f.IsSilent = _silentFor >= s.SilenceHold;

        ComputePower(snap.Window);
        double binHz = snap.SampleRate / FftSize;
        var edges = BandEdges(BandCount);
        float range = 20 + 25 * Math.Clamp(s.Sensitivity, 0.2f, 2f);  // 25…70 dB shown

        var bandDB = new float[BandCount];
        for (int b = 0; b < BandCount; b++) bandDB[b] = Db.FromLinear(MathF.Sqrt(BandPower(edges[b], edges[b + 1], binHz)));
        float maxBand = BandCount > 0 ? bandDB.Max() : -120;
        if (s.AdaptiveGain && !gated) _spectrumGain.Update(maxBand, dt);
        for (int b = 0; b < BandCount; b++)
        {
            float target = gated ? 0 : Normalize(bandDB[b], _spectrumGain, range);
            f.Bands[b] = _bandEnvelopes[b].Process(target, dt);
        }

        float bassDB = Db.FromLinear(MathF.Sqrt(BandPower(20, 150, binHz)));
        float midDB = Db.FromLinear(MathF.Sqrt(BandPower(150, 2_000, binHz)));
        float trebleDB = Db.FromLinear(MathF.Sqrt(BandPower(2_000, 16_000, binHz)));
        if (s.AdaptiveGain && !gated)
        {
            _bassGain.Update(bassDB, dt); _midGain.Update(midDB, dt);
            _trebleGain.Update(trebleDB, dt); _levelGain.Update(f.RmsDB, dt);
        }
        float bassRaw = gated ? 0 : MathF.Min(1, Normalize(bassDB, _bassGain, range * 0.6f) * s.BassResponse);
        f.Bass = _bassEnv.Process(bassRaw, dt);
        f.Mid = _midEnv.Process(gated ? 0 : Normalize(midDB, _midGain, range * 0.6f), dt);
        f.Treble = _trebleEnv.Process(gated ? 0 : Normalize(trebleDB, _trebleGain, range * 0.6f), dt);
        f.Level = _levelEnv.Process(gated ? 0 : Normalize(f.RmsDB, _levelGain, range * 0.7f), dt);

        // Onset: instantaneous bass well above its running mean, with a 150 ms refractory period.
        _bassAverage += (bassRaw - _bassAverage) * (float)Math.Min(1, dt / 0.6);
        if (!gated && bassRaw > 0.45f && bassRaw > _bassAverage * 1.35f + 0.08f && _clock - _lastBeat > 0.15)
        {
            f.Beat = true;
            _lastBeat = _clock;
        }
        return f;
    }

    private float Normalize(float db, AdaptiveGain gain, float range) =>
        Settings.AdaptiveGain ? gain.Normalize(db, range) : Math.Clamp((db + range) / range, 0, 1);  // fixed: 0 dBFS full, −range dark

    private void ComputePower(float[] samples)
    {
        int n = Math.Min(samples.Length, FftSize);
        for (int i = 0; i < FftSize; i++) { _re[i] = i < n ? samples[i] * _window[i] : 0; _im[i] = 0; }
        Fft(_re, _im);
        // Matches the Swift analyzer's scaling (vDSP's 2× real FFT, then 1/N² × 4): power = 16|X|²/N².
        float scale = 16f / ((float)FftSize * FftSize);
        for (int k = 0; k < FftSize / 2; k++) _power[k] = (_re[k] * _re[k] + _im[k] * _im[k]) * scale;
        _power[0] = _re[0] * _re[0] * scale;
    }

    /// <summary>Total power of bins in [lo, hi) (at least one bin).</summary>
    private float BandPower(double lo, double hi, double binHz)
    {
        int half = FftSize / 2;
        int a = (int)Math.Ceiling(lo / binHz), b = (int)Math.Ceiling(hi / binHz);
        a = Math.Max(1, Math.Min(a, half - 1)); b = Math.Max(a + 1, Math.Min(b, half));
        float sum = 0;
        for (int i = a; i < b; i++) sum += _power[i];
        return sum;
    }

    /// <summary>In-place iterative radix-2 complex FFT.</summary>
    private static void Fft(float[] re, float[] im)
    {
        int n = re.Length;
        for (int i = 1, j = 0; i < n; i++)
        {
            int bit = n >> 1;
            for (; (j & bit) != 0; bit >>= 1) j ^= bit;
            j ^= bit;
            if (i < j) { (re[i], re[j]) = (re[j], re[i]); (im[i], im[j]) = (im[j], im[i]); }
        }
        for (int len = 2; len <= n; len <<= 1)
        {
            double ang = -2 * Math.PI / len;
            double wr = Math.Cos(ang), wi = Math.Sin(ang);
            for (int i = 0; i < n; i += len)
            {
                double cr = 1, ci = 0;
                for (int k = 0; k < len / 2; k++)
                {
                    int u = i + k, v = i + k + len / 2;
                    float tr = (float)(re[v] * cr - im[v] * ci), ti = (float)(re[v] * ci + im[v] * cr);
                    re[v] = re[u] - tr; im[v] = im[u] - ti;
                    re[u] += tr; im[u] += ti;
                    double ncr = cr * wr - ci * wi;
                    ci = cr * wi + ci * wr;
                    cr = ncr;
                }
            }
        }
    }
}

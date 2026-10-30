namespace BeatRGB.Core.Audio;

/// <summary>One-pole attack/release follower with time constants in seconds.</summary>
public struct Envelope(double attack, double release, float value = 0)
{
    public double Attack = attack;
    public double Release = release;
    public float Value { get; private set; } = value;

    public float Process(float target, double dt)
    {
        double tau = target > Value ? Attack : Release;
        float k = tau <= 0 ? 1 : (float)(1 - Math.Exp(-dt / tau));
        Value += (target - Value) * k;
        return Value;
    }

    public void Reset(float v = 0) => Value = v;
}

/// <summary>
/// Slow peak tracker in dB used for adaptive gain: rises instantly, decays at DecayDBPerSecond,
/// and never drops below FloorDB so silence isn't amplified into noise.
/// </summary>
public struct AdaptiveGain(float decayDBPerSecond = 4, float floorDB = -50, float initialDB = -20)
{
    public float DecayDBPerSecond = decayDBPerSecond;
    public float FloorDB = floorDB;
    public float ReferenceDB { get; private set; } = initialDB;

    public float Update(float db, double dt)
    {
        ReferenceDB = MathF.Max(db, MathF.Max(ReferenceDB - DecayDBPerSecond * (float)dt, FloorDB));
        return ReferenceDB;
    }

    /// <summary>Maps a level in dB into 0…1 relative to the reference over rangeDB.</summary>
    public readonly float Normalize(float db, float rangeDB) => Math.Clamp((db - (ReferenceDB - rangeDB)) / rangeDB, 0, 1);
}

public static class Db
{
    public static float FromLinear(float x) => 20 * MathF.Log10(MathF.Max(x, 1e-9f));
}

using System.Text;

namespace BeatRGB.Core.OpenRGB;

/// <summary>Little-endian reader over OpenRGB SDK payloads.</summary>
public sealed class ByteReader(byte[] data)
{
    private int _offset;

    public int Remaining => data.Length - _offset;

    private ReadOnlySpan<byte> Take(int n)
    {
        if (n < 0 || _offset + n > data.Length)
            throw new OpenRGBException($"Malformed controller data: read of {n} bytes at {_offset} exceeds {data.Length}");
        var span = new ReadOnlySpan<byte>(data, _offset, n);
        _offset += n;
        return span;
    }

    public byte U8() => Take(1)[0];
    public ushort U16() { var b = Take(2); return (ushort)(b[0] | b[1] << 8); }
    public uint U32() { var b = Take(4); return (uint)(b[0] | b[1] << 8 | b[2] << 16 | b[3] << 24); }
    public int I32() => unchecked((int)U32());

    /// <summary>OpenRGB string: u16 length (including NUL) followed by bytes.</summary>
    public string String()
    {
        var bytes = Take(U16());
        int end = bytes.IndexOf((byte)0);
        return Encoding.UTF8.GetString(end >= 0 ? bytes[..end] : bytes);
    }

    public void Skip(int n) => Take(n);
}

public sealed class ByteWriter
{
    private readonly List<byte> _bytes = [];

    public int Count => _bytes.Count;
    public byte[] ToArray() => [.. _bytes];

    public void U8(byte v) => _bytes.Add(v);
    public void U16(ushort v) { _bytes.Add((byte)v); _bytes.Add((byte)(v >> 8)); }
    public void U32(uint v) { for (int i = 0; i < 4; i++) _bytes.Add((byte)(v >> (8 * i))); }
    public void I32(int v) => U32(unchecked((uint)v));

    public void String(string s)
    {
        var utf8 = Encoding.UTF8.GetBytes(s);
        U16((ushort)(utf8.Length + 1));
        _bytes.AddRange(utf8);
        _bytes.Add(0);
    }

    public void Append(IEnumerable<byte> other) => _bytes.AddRange(other);
}

public sealed class OpenRGBException(string message) : Exception(message);

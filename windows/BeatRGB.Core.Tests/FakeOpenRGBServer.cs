using System.Net;
using System.Net.Sockets;
using BeatRGB.Core;
using BeatRGB.Core.OpenRGB;

namespace BeatRGB.Core.Tests;

/// <summary>Minimal in-process OpenRGB SDK server for tests.</summary>
public sealed class FakeOpenRGBServer : IDisposable
{
    private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
    private readonly object _lock = new();
    private readonly List<RGB8[]> _updates = [];
    public List<RGBDevice> Devices { get; }
    public uint ServerVersion { get; set; } = 5;
    public int Port => ((IPEndPoint)_listener.LocalEndpoint).Port;

    public FakeOpenRGBServer(params RGBDevice[] devices)
    {
        Devices = [.. devices];
        _listener.Start();
        new Thread(Accept) { IsBackground = true }.Start();
    }

    public RGB8[]? LastUpdate { get { lock (_lock) return _updates.LastOrDefault(); } }
    public int UpdateCount { get { lock (_lock) return _updates.Count; } }

    private void Accept()
    {
        try
        {
            while (true)
            {
                var client = _listener.AcceptTcpClient();
                new Thread(() => Serve(client)) { IsBackground = true }.Start();
            }
        }
        catch (SocketException) { }
        catch (ObjectDisposedException) { }
    }

    private void Serve(TcpClient client)
    {
        using var stream = client.GetStream();
        uint version = 0;
        try
        {
            while (true)
            {
                var header = ReadExact(stream, 16);
                var r = new ByteReader(header[4..]);
                uint device = r.U32(), id = r.U32(), size = r.U32();
                var payload = ReadExact(stream, (int)size);
                switch (id)
                {
                    case OpenRGBProtocol.RequestProtocolVersion:
                        version = Math.Min(new ByteReader(payload).U32(), ServerVersion);
                        Reply(stream, 0, id, U32(ServerVersion));
                        break;
                    case OpenRGBProtocol.RequestControllerCount:
                        Reply(stream, 0, id, U32((uint)Devices.Count));
                        break;
                    case OpenRGBProtocol.RequestControllerData:
                        uint v = payload.Length >= 4 ? new ByteReader(payload).U32() : 0;
                        lock (_lock) Reply(stream, device, id, DeviceDescription.Encode(Devices[(int)device], v));
                        break;
                    case OpenRGBProtocol.SetCustomMode:
                        lock (_lock) { var d = Devices[(int)device]; d.ActiveMode = d.DirectModeIndex ?? d.ActiveMode; }
                        break;
                    case OpenRGBProtocol.UpdateLEDs:
                        var pr = new ByteReader(payload);
                        pr.U32();
                        int n = pr.U16();
                        var colors = new RGB8[n];
                        for (int i = 0; i < n; i++) { colors[i] = new RGB8(pr.U8(), pr.U8(), pr.U8()); pr.Skip(1); }
                        lock (_lock) { Devices[(int)device].Colors = [.. colors]; _updates.Add(colors); }
                        break;
                }
            }
        }
        catch (IOException) { }   // includes EndOfStreamException when the client hangs up
        _ = version;
    }

    private static byte[] U32(uint v) { var w = new ByteWriter(); w.U32(v); return w.ToArray(); }

    private static void Reply(NetworkStream s, uint device, uint id, byte[] payload)
    {
        var bytes = OpenRGBProtocol.Packet(device, id, payload);
        s.Write(bytes);
    }

    private static byte[] ReadExact(NetworkStream s, int n)
    {
        var buf = new byte[n];
        s.ReadExactly(buf);
        return buf;
    }

    public void Dispose() => _listener.Stop();
}

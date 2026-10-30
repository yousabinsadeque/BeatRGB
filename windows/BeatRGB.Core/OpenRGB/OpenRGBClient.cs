using System.Diagnostics;
using System.Net.Sockets;
using System.Text;

namespace BeatRGB.Core.OpenRGB;

/// <summary>
/// Constants for the OpenRGB SDK network protocol (same as BeatRGBKit's OpenRGBProtocol.swift).
/// BeatRGB negotiates at most version 5: device indices in the header are plain controller indices and the
/// server sends no ACK packets, which keeps the client compatible with OpenRGB 0.9 (v4), 1.0 (v5) and newer.
/// </summary>
public static class OpenRGBProtocol
{
    public static readonly byte[] Magic = "ORGB"u8.ToArray();
    public const int HeaderSize = 16;
    public const uint MaxClientVersion = 5;
    public const int DefaultPort = 6742;

    public const uint RequestControllerCount = 0;
    public const uint RequestControllerData = 1;
    public const uint RequestProtocolVersion = 40;
    public const uint SetClientName = 50;
    public const uint DeviceListUpdated = 100;
    public const uint UpdateLEDs = 1050;
    public const uint SetCustomMode = 1100;

    public static byte[] Packet(uint device, uint id, byte[]? payload = null)
    {
        payload ??= [];
        var w = new ByteWriter();
        w.Append(Magic);
        w.U32(device);
        w.U32(id);
        w.U32((uint)payload.Length);
        w.Append(payload);
        return w.ToArray();
    }

    /// <summary>Payload for RGBCONTROLLER_UPDATELEDS: u32 data size, u16 count, count × (r,g,b,pad).</summary>
    public static byte[] UpdateLEDsPayload(IReadOnlyList<RGB8> colors)
    {
        var w = new ByteWriter();
        w.U32((uint)(4 + 2 + colors.Count * 4));
        w.U16((ushort)colors.Count);
        foreach (var c in colors) { w.U8(c.R); w.U8(c.G); w.U8(c.B); w.U8(0); }
        return w.ToArray();
    }
}

/// <summary>Blocking OpenRGB SDK client. Not thread-safe: confine each instance to one thread.</summary>
public sealed class OpenRGBClient(string host = "127.0.0.1", int port = OpenRGBProtocol.DefaultPort, string clientName = "BeatRGB") : IDisposable
{
    public string Host { get; } = host;
    public int Port { get; } = port;
    public TimeSpan IoTimeout { get; set; } = TimeSpan.FromSeconds(2);
    public uint ServerProtocolVersion { get; private set; }
    public uint ProtocolVersion { get; private set; }
    /// <summary>Set when the server announced DEVICE_LIST_UPDATED; device indices must be re-resolved.</summary>
    public bool DeviceListChanged { get; private set; }

    private Socket? _socket;
    public bool IsConnected => _socket != null;

    public void Connect(int timeoutMs = 1500)
    {
        Disconnect();
        var s = new Socket(SocketType.Stream, ProtocolType.Tcp) { NoDelay = true };
        try
        {
            var task = s.ConnectAsync(Host, Port);
            if (!task.Wait(timeoutMs)) throw new OpenRGBException($"Could not connect to OpenRGB SDK server at {Host}:{Port}: timed out");
        }
        catch (AggregateException e)
        {
            s.Dispose();
            throw new OpenRGBException($"Could not connect to OpenRGB SDK server at {Host}:{Port}: {e.InnerException?.Message ?? e.Message}");
        }
        catch (OpenRGBException)
        {
            s.Dispose();
            throw;
        }
        _socket = s;
        DeviceListChanged = false;
        try { Negotiate(); }
        catch { Disconnect(); throw; }
    }

    public void Disconnect()
    {
        _socket?.Dispose();
        _socket = null;
    }

    public void Dispose() => Disconnect();

    private void Negotiate()
    {
        var w = new ByteWriter(); w.U32(OpenRGBProtocol.MaxClientVersion);
        Send(OpenRGBProtocol.RequestProtocolVersion, 0, w.ToArray());
        // Protocol-0 servers never answer this request; treat a timeout as version 0.
        try { ServerProtocolVersion = new ByteReader(Receive(OpenRGBProtocol.RequestProtocolVersion, TimeSpan.FromSeconds(1))).U32(); }
        catch (TimeoutException) { ServerProtocolVersion = 0; }
        ProtocolVersion = Math.Min(ServerProtocolVersion, OpenRGBProtocol.MaxClientVersion);
        Send(OpenRGBProtocol.SetClientName, 0, [.. Encoding.UTF8.GetBytes(clientName), 0]);
    }

    public int ControllerCount()
    {
        Send(OpenRGBProtocol.RequestControllerCount);
        return (int)new ByteReader(Receive(OpenRGBProtocol.RequestControllerCount)).U32();
    }

    public RGBDevice Controller(uint index)
    {
        var w = new ByteWriter();
        if (ProtocolVersion >= 1) w.U32(ProtocolVersion);
        Send(OpenRGBProtocol.RequestControllerData, index, w.ToArray());
        var d = DeviceDescription.Parse(Receive(OpenRGBProtocol.RequestControllerData), ProtocolVersion);
        d.Index = index;
        return d;
    }

    public List<RGBDevice> AllControllers()
    {
        DeviceListChanged = false;
        int n = ControllerCount();
        var list = new List<RGBDevice>(n);
        for (uint i = 0; i < n; i++) list.Add(Controller(i));
        return list;
    }

    /// <summary>Switches the controller to its Direct/Custom mode and verifies it took effect.</summary>
    public RGBDevice EnableDirectMode(RGBDevice device)
    {
        if (device.DirectModeIndex == null) throw new OpenRGBException($"{device.Name} does not expose a Direct mode in OpenRGB.");
        Send(OpenRGBProtocol.SetCustomMode, device.Index);
        var updated = Controller(device.Index);
        if (updated.Identity != device.Identity) throw new OpenRGBException("The keyboard is no longer reported by OpenRGB.");
        if (!updated.ActiveModeIsDirect) throw new OpenRGBException($"OpenRGB did not switch the keyboard to Direct mode (active: {updated.ActiveModeName}).");
        return updated;
    }

    public void UpdateLEDs(uint device, IReadOnlyList<RGB8> colors) =>
        Send(OpenRGBProtocol.UpdateLEDs, device, OpenRGBProtocol.UpdateLEDsPayload(colors));

    /// <summary>Reads (without blocking) any unsolicited packets, e.g. DEVICE_LIST_UPDATED.</summary>
    public void PollNotifications()
    {
        var s = _socket ?? throw new OpenRGBException("Not connected to the OpenRGB SDK server.");
        while (s.Available > 0 || Readable(s, 0))
        {
            var (id, _) = ReadPacket(IoTimeout);
            if (id == OpenRGBProtocol.DeviceListUpdated) DeviceListChanged = true;
        }
    }

    // Framing

    private void Send(uint id, uint device = 0, byte[]? payload = null)
    {
        var s = _socket ?? throw new OpenRGBException("Not connected to the OpenRGB SDK server.");
        var bytes = OpenRGBProtocol.Packet(device, id, payload);
        try
        {
            s.SendTimeout = (int)IoTimeout.TotalMilliseconds;
            int sent = 0;
            while (sent < bytes.Length) sent += s.Send(bytes, sent, bytes.Length - sent, SocketFlags.None);
        }
        catch (SocketException e) { throw Fail($"Socket error: {e.Message}"); }
    }

    private byte[] Receive(uint id, TimeSpan? timeout = null)
    {
        var deadline = Stopwatch.StartNew();
        var limit = timeout ?? IoTimeout;
        while (true)
        {
            var left = limit - deadline.Elapsed;
            if (left <= TimeSpan.Zero) throw new TimeoutException("OpenRGB SDK server did not respond in time.");
            var (got, payload) = ReadPacket(left);
            if (got == id) return payload;
            if (got == OpenRGBProtocol.DeviceListUpdated) DeviceListChanged = true;
        }
    }

    private (uint Id, byte[] Payload) ReadPacket(TimeSpan timeout)
    {
        var header = ReadExact(OpenRGBProtocol.HeaderSize, timeout);
        if (!header.AsSpan(0, 4).SequenceEqual(OpenRGBProtocol.Magic)) throw Fail("Received a packet without the ORGB magic header.");
        var r = new ByteReader(header[4..]);
        r.U32();
        uint id = r.U32(), size = r.U32();
        if (size >= 16 * 1024 * 1024) throw Fail($"Malformed controller data: packet too large: {size}");
        return (id, ReadExact((int)size, timeout > IoTimeout ? timeout : IoTimeout));
    }

    private byte[] ReadExact(int count, TimeSpan timeout)
    {
        var s = _socket ?? throw new OpenRGBException("Not connected to the OpenRGB SDK server.");
        var output = new byte[count];
        int got = 0;
        var clock = Stopwatch.StartNew();
        while (got < count)
        {
            var left = timeout - clock.Elapsed;
            if (left <= TimeSpan.Zero || !Readable(s, (int)left.TotalMilliseconds))
            {
                // A partially read packet leaves the stream unusable.
                if (got > 0) throw Fail("OpenRGB SDK server did not respond in time.");
                throw new TimeoutException("OpenRGB SDK server did not respond in time.");
            }
            int n;
            try { n = s.Receive(output, got, count - got, SocketFlags.None); }
            catch (SocketException e) { throw Fail($"Socket error: {e.Message}"); }
            if (n == 0) throw Fail("OpenRGB closed the connection.");
            got += n;
        }
        return output;
    }

    private static bool Readable(Socket s, int timeoutMs) => s.Poll(Math.Max(0, timeoutMs) * 1000, SelectMode.SelectRead);

    private OpenRGBException Fail(string message)
    {
        Disconnect();
        return new OpenRGBException(message);
    }
}

import Darwin
import Foundation

/// Blocking OpenRGB SDK client. Not thread-safe: confine each instance to one serial queue
/// (BeatRGB's LightingEngine owns it on its engine queue).
public final class OpenRGBClient {
    public let host: String
    public let port: UInt16
    public let clientName: String
    public var ioTimeout: TimeInterval = 2.0

    public private(set) var serverProtocolVersion: UInt32 = 0
    public private(set) var protocolVersion: UInt32 = 0
    /// Set when the server announced DEVICE_LIST_UPDATED; device indices must be re-resolved.
    public private(set) var deviceListChanged = false

    private var fd: Int32 = -1

    public init(host: String = "127.0.0.1", port: UInt16 = OpenRGBProtocol.defaultPort, clientName: String = "BeatRGB") {
        self.host = host; self.port = port; self.clientName = clientName
    }

    deinit { disconnect() }

    public var isConnected: Bool { fd >= 0 }

    // MARK: Connection

    public func connect(timeout: TimeInterval = 1.5) throws {
        disconnect()
        var hints = addrinfo(ai_flags: AI_NUMERICSERV, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        let gai = getaddrinfo(host, String(port), &hints, &res)
        guard gai == 0, let info = res else {
            throw OpenRGBError.connectFailed(String(cString: gai_strerror(gai)))
        }
        defer { freeaddrinfo(res) }

        let s = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard s >= 0 else { throw OpenRGBError.connectFailed(errnoString()) }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))

        // Non-blocking connect with timeout, then switch back to blocking.
        let flags = fcntl(s, F_GETFL)
        _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)
        var rc = Darwin.connect(s, info.pointee.ai_addr, info.pointee.ai_addrlen)
        if rc != 0 && errno == EINPROGRESS {
            var pfd = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
            rc = poll(&pfd, 1, Int32(timeout * 1000))
            if rc == 1 {
                var err: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &len)
                rc = err == 0 ? 0 : -1
                if err != 0 { errno = err }
            } else {
                if rc == 0 { errno = ETIMEDOUT }
                rc = -1
            }
        }
        guard rc == 0 else {
            let msg = errnoString()
            close(s)
            throw OpenRGBError.connectFailed(msg)
        }
        _ = fcntl(s, F_SETFL, flags & ~O_NONBLOCK)
        fd = s
        deviceListChanged = false

        do {
            try negotiate()
        } catch {
            disconnect()
            throw error
        }
    }

    public func disconnect() {
        if fd >= 0 { close(fd); fd = -1 }
    }

    private func negotiate() throws {
        var w = ByteWriter(); w.u32(OpenRGBProtocol.maxClientVersion)
        try send(.requestProtocolVersion, payload: w.bytes)
        // Protocol-0 servers never answer this request; treat a timeout as version 0.
        do {
            var r = ByteReader(try receive(.requestProtocolVersion, timeout: 1.0))
            serverProtocolVersion = try r.u32()
        } catch OpenRGBError.timeout {
            serverProtocolVersion = 0
        }
        protocolVersion = min(serverProtocolVersion, OpenRGBProtocol.maxClientVersion)
        var name = ByteWriter(); name.append(Array(clientName.utf8)); name.u8(0)
        try send(.setClientName, payload: name.bytes)
    }

    // MARK: Requests

    public func controllerCount() throws -> Int {
        try send(.requestControllerCount)
        var r = ByteReader(try receive(.requestControllerCount))
        return Int(try r.u32())
    }

    public func controller(at index: UInt32) throws -> RGBDevice {
        var w = ByteWriter()
        if protocolVersion >= 1 { w.u32(protocolVersion) }
        try send(.requestControllerData, device: index, payload: w.bytes)
        var d = try DeviceDescription.parse(try receive(.requestControllerData), protocolVersion: protocolVersion)
        d.index = index
        return d
    }

    public func allControllers() throws -> [RGBDevice] {
        deviceListChanged = false
        return try (0..<controllerCount()).map { try controller(at: UInt32($0)) }
    }

    /// Switches the controller to its Direct/Custom mode and verifies it took effect.
    @discardableResult
    public func enableDirectMode(_ device: RGBDevice) throws -> RGBDevice {
        guard device.directModeIndex != nil else { throw OpenRGBError.noDirectMode }
        try send(.setCustomMode, device: device.index)
        let updated = try controller(at: device.index)
        guard updated.identity == device.identity else { throw OpenRGBError.deviceNotFound }
        guard updated.modes.indices.contains(Int(updated.activeMode)), updated.modes[Int(updated.activeMode)].isDirect else {
            throw OpenRGBError.directModeRejected(updated.activeModeName)
        }
        return updated
    }

    public func updateLEDs(device index: UInt32, colors: [RGB8]) throws {
        try send(.updateLEDs, device: index, payload: OpenRGBProtocol.updateLEDsPayload(colors))
    }

    /// Reads (without blocking) any unsolicited packets, e.g. DEVICE_LIST_UPDATED.
    public func pollNotifications() throws {
        guard fd >= 0 else { throw OpenRGBError.notConnected }
        while try readable(timeout: 0) {
            let (header, _) = try readPacket(timeout: ioTimeout)
            if header.packetID == OpenRGBProtocol.PacketID.deviceListUpdated.rawValue { deviceListChanged = true }
        }
    }

    // MARK: Framing

    private func send(_ id: OpenRGBProtocol.PacketID, device: UInt32 = 0, payload: [UInt8] = []) throws {
        guard fd >= 0 else { throw OpenRGBError.notConnected }
        let bytes = OpenRGBProtocol.packet(device: device, id: id, payload: payload)
        var sent = 0
        try bytes.withUnsafeBytes { buf in
            while sent < bytes.count {
                guard try writable(timeout: ioTimeout) else { throw fail(.timeout) }
                let n = Darwin.send(fd, buf.baseAddress! + sent, bytes.count - sent, 0)
                if n <= 0 {
                    if n < 0 && errno == EINTR { continue }
                    throw fail(.io(errnoString()))
                }
                sent += n
            }
        }
    }

    private func receive(_ id: OpenRGBProtocol.PacketID, timeout: TimeInterval? = nil) throws -> [UInt8] {
        let deadline = Date().addingTimeInterval(timeout ?? ioTimeout)
        while true {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { throw OpenRGBError.timeout }
            let (header, payload) = try readPacket(timeout: left)
            if header.packetID == id.rawValue { return payload }
            if header.packetID == OpenRGBProtocol.PacketID.deviceListUpdated.rawValue { deviceListChanged = true }
        }
    }

    private func readPacket(timeout: TimeInterval) throws -> (OpenRGBProtocol.Header, [UInt8]) {
        let header = try OpenRGBProtocol.Header.decode(try readExact(OpenRGBProtocol.headerSize, timeout: timeout))
        guard header.size < 16 * 1024 * 1024 else { throw fail(.malformed("packet too large: \(header.size)")) }
        return (header, try readExact(Int(header.size), timeout: max(timeout, ioTimeout)))
    }

    private func readExact(_ count: Int, timeout: TimeInterval) throws -> [UInt8] {
        guard fd >= 0 else { throw OpenRGBError.notConnected }
        var out = [UInt8](repeating: 0, count: count)
        var got = 0
        let deadline = Date().addingTimeInterval(timeout)
        while got < count {
            let left = deadline.timeIntervalSinceNow
            guard left > 0, try readable(timeout: left) else {
                // A partially read packet leaves the stream unusable.
                if got > 0 { throw fail(.timeout) }
                throw OpenRGBError.timeout
            }
            let n = out.withUnsafeMutableBytes { recv(fd, $0.baseAddress! + got, count - got, 0) }
            if n == 0 { throw fail(.closed) }
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw fail(.io(errnoString()))
            }
            got += n
        }
        return out
    }

    private func readable(timeout: TimeInterval) throws -> Bool { try waitFor(Int16(POLLIN), timeout) }
    private func writable(timeout: TimeInterval) throws -> Bool { try waitFor(Int16(POLLOUT), timeout) }

    private func waitFor(_ events: Int16, _ timeout: TimeInterval) throws -> Bool {
        var pfd = pollfd(fd: fd, events: events, revents: 0)
        let rc = poll(&pfd, 1, Int32(max(0, timeout) * 1000))
        if rc < 0 { if errno == EINTR { return false }; throw fail(.io(errnoString())) }
        if rc > 0 && (pfd.revents & Int16(POLLHUP | POLLERR | POLLNVAL)) != 0 && (pfd.revents & Int16(POLLIN)) == 0 {
            throw fail(.closed)
        }
        return rc > 0
    }

    private func fail(_ e: OpenRGBError) -> OpenRGBError { disconnect(); return e }
}

func errnoString() -> String { String(cString: strerror(errno)) }

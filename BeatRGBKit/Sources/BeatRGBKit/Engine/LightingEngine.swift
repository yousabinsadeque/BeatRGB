import Foundation
import QuartzCore

public enum StopBehavior: String, Codable, CaseIterable, Identifiable, Sendable {
    case restorePrevious, idleEffect, off
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .restorePrevious: return "Restore previous lighting"
        case .idleEffect: return "Show idle colour"
        case .off: return "Turn lights off"
        }
    }
}

public struct EngineConfig: Equatable, Sendable {
    public var backend = Backend.openRGB
    public var host = "127.0.0.1"
    public var port: UInt16 = OpenRGBProtocol.defaultPort
    public var matcher = DeviceMatcher.automatic
    public var autoReconnect = true
    public var stopBehavior = StopBehavior.restorePrevious
    public init() {}

    var driverKey: String { "\(backend.rawValue)|\(host)|\(port)|\(matcher.serial ?? "")|\(matcher.name ?? "")" }
}

public enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected(String)
    case failed(String)
}

public enum DeviceState: Equatable, Sendable {
    case none
    case searching
    case ready(name: String, leds: Int, mode: String)
    case notFound(available: [String])
    case failed(String)
}

public struct EngineSnapshot: Sendable {
    public var running = false
    public var backend = Backend.openRGB
    public var connection = ConnectionState.disconnected
    public var device = DeviceState.none
    public var identity: DeviceIdentity?
    public var modes: [String] = []
    public var layout = KeyboardLayout.placeholderTKL
    public var frame: [RGB8] = []
    public var features = AudioFeatures(bandCount: 0)
    public var fps: Double = 0
    public var targetFPS: Double = 30
    public var latencyMs: Double = 0
    public var framesSent = 0
    public var lastError: String?
    public var log: [String] = []

    public init() {}
}

/// Owns the keyboard driver and the render loop. All mutable state lives on `queue`.
public final class LightingEngine: @unchecked Sendable {
    public var onSnapshot: (@Sendable (EngineSnapshot) -> Void)?

    private let queue = DispatchQueue(label: "BeatRGB.engine", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var config = EngineConfig()
    private var driver: KeyboardDriver?
    private var driverKey = ""
    private var device: DriverDevice?
    private let analyzer = AudioAnalyzer()
    private let renderer = EffectRenderer()
    private var ring: SampleRing?
    private var screen: ScreenSampler?
    private var snapshot = EngineSnapshot()
    private var running = false
    private var lastTick: CFTimeInterval = 0
    private var lastSent: [RGB8] = []
    private var lastSendTime: CFTimeInterval = 0
    private var lastHealth: CFTimeInterval = 0
    private var nextRetry: CFTimeInterval = 0
    private var retryDelay: Double = 1
    private var currentFPS: Double = 30
    private var fpsWindow: (start: CFTimeInterval, frames: Int) = (0, 0)
    private var lastPublish: CFTimeInterval = 0

    /// Lets tests (or a future device) supply their own driver.
    public var makeDriver: (EngineConfig) throws -> KeyboardDriver = LightingEngine.defaultDriver

    public init() {}

    public static func defaultDriver(_ c: EngineConfig) throws -> KeyboardDriver {
        switch c.backend {
        case .openRGB: return OpenRGBDriver(host: c.host, port: c.port, matcher: c.matcher)
        case .native: return NativeCorsairDriver(ledMap: try .k70CoreTKL())
        }
    }

    // MARK: Public API (thread-safe)

    public func configure(_ c: EngineConfig) {
        queue.async {
            let changed = c.driverKey != self.config.driverKey
            let wasRunning = self.running
            if changed && self.device != nil {
                // Hand the keyboard back properly before switching backend/endpoint.
                self.driver?.finish(self.config.stopBehavior, idleFrame: self.idleColors())
            }
            self.config = c
            self.snapshot.backend = c.backend
            if changed {
                self.closeDriver()
                self.snapshot.device = .none
                if wasRunning { self.nextRetry = 0; self.retryDelay = 1 }
                self.publish(force: true)
            }
        }
    }

    public func update(settings: LightingSettings) {
        queue.async {
            self.renderer.settings = settings
            self.analyzer.settings = settings.analyzerSettings
            self.snapshot.targetFPS = settings.targetFPS
            if self.currentFPS > settings.targetFPS || !self.running { self.setFPS(settings.targetFPS) }
        }
    }

    public func setAudioSource(_ ring: SampleRing?) {
        queue.async { self.ring = ring; self.analyzer.reset() }
    }

    public func setScreenSampler(_ sampler: ScreenSampler?) {
        queue.async { self.screen = sampler }
    }

    public func start() {
        queue.async {
            guard !self.running else { return }
            self.running = true
            self.snapshot.running = true
            self.nextRetry = 0
            self.retryDelay = 1
            self.lastTick = CACurrentMediaTime()
            self.analyzer.reset()
            self.log("Sync started (\(self.config.backend.title))")
            self.setFPS(self.renderer.settings.targetFPS)
            self.publish(force: true)
        }
    }

    public func stop(completion: (@Sendable () -> Void)? = nil) {
        queue.async {
            if self.running { self.log("Sync stopped") }
            self.running = false
            self.timer?.cancel(); self.timer = nil
            self.snapshot.running = false
            self.snapshot.fps = 0
            if self.device != nil {
                self.driver?.finish(self.config.stopBehavior, idleFrame: self.idleColors())
            }
            self.closeDriver()
            if case .ready = self.snapshot.device { self.snapshot.device = .none }
            self.publish(force: true)
            completion?()
        }
    }

    /// Hardware proof: open the keyboard if needed and paint every key one colour.
    public func sendTestColor(_ color: RGB8, completion: (@Sendable (Result<String, Error>) -> Void)? = nil) {
        queue.async {
            do {
                try self.ensureDevice()
                guard let driver = self.driver, let device = self.device else { throw DriverError.deviceMissing(available: []) }
                let colors = Array(repeating: color, count: device.ledCount)
                try driver.write(colors)
                self.snapshot.frame = colors
                var detail = "Sent to \(device.ledCount) LEDs"
                if let orgb = driver as? OpenRGBDriver {
                    // Read back what OpenRGB now holds for the keyboard.
                    _ = try orgb.periodicCheck()
                    detail += " via OpenRGB"
                } else if let native = driver as? NativeCorsairDriver {
                    detail += native.rejectedFrames == 0 && native.acknowledgedFrames > 0
                        ? " over USB; the keyboard acknowledged the frame" : " over USB; the keyboard did not acknowledge the frame"
                    self.snapshot.connection = .connected(native.connectionInfo)
                }
                self.log(String(format: "Test colour #%02X%02X%02X: %@", color.r, color.g, color.b, detail))
                self.publish(force: true)
                completion?(.success(detail))
            } catch {
                self.handle(error)
                completion?(.failure(error))
            }
        }
    }

    /// Lists OpenRGB controllers for diagnostics (OpenRGB backend only).
    public func scanDevices(completion: @escaping @Sendable (Result<[RGBDevice], Error>) -> Void) {
        queue.async {
            do {
                let d = OpenRGBDriver(host: self.config.host, port: self.config.port, matcher: self.config.matcher)
                defer { d.close() }
                completion(.success(try d.scan()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    // MARK: Loop

    private func setFPS(_ fps: Double) {
        currentFPS = min(60, max(5, fps))
        guard running else { return }
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0 / currentFPS, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        guard running else { return }
        let now = CACurrentMediaTime()
        let dt = min(0.1, max(0.001, now - lastTick))
        lastTick = now

        let features: AudioFeatures
        if let ring {
            features = analyzer.analyze(ring.snapshot(count: analyzer.fftSize), dt: dt)
        } else {
            var silent = AudioFeatures(bandCount: analyzer.bandCount)
            silent.isSilent = true
            features = silent
        }
        snapshot.features = features
        let colors = renderer.render(features: features, screen: screen?.latest, dt: dt).map(\.rgb8)
        snapshot.frame = colors

        if device == nil, now >= nextRetry {
            do { try ensureDevice() } catch { handle(error) }
        }
        if let driver, device != nil {
            do {
                if try driver.poll() {
                    log("Device list changed; re-checking the keyboard")
                    device = nil
                    try ensureDevice()
                    publish(force: true)
                    return
                }
                if colors != lastSent || now - lastSendTime > 1 {
                    try driver.write(colors)
                    lastSent = colors
                    lastSendTime = now
                    snapshot.framesSent += 1
                }
                fpsWindow.frames += 1
                if now - lastHealth > 1 {
                    lastHealth = now
                    let latency = try driver.periodicCheck()
                    snapshot.latencyMs = latency
                    snapshot.connection = .connected(driver.connectionInfo)
                    adapt(latency)
                }
            } catch {
                handle(error)
            }
        }
        if now - fpsWindow.start >= 1 {
            snapshot.fps = fpsWindow.start > 0 ? Double(fpsWindow.frames) / (now - fpsWindow.start) : 0
            fpsWindow = (now, 0)
        }
        publish(force: false)
    }

    /// Lowers the frame rate when the device path can't keep up, and recovers slowly.
    private func adapt(_ latencyMs: Double) {
        let frameMs = 1000 / currentFPS
        let target = renderer.settings.targetFPS
        if latencyMs > frameMs * 2, currentFPS > 10 {
            setFPS(currentFPS * 0.8)
            log(String(format: "Keyboard path is slow (%.0f ms); throttling to %.0f fps", latencyMs, currentFPS))
        } else if latencyMs < frameMs * 0.5, currentFPS < target {
            setFPS(min(target, currentFPS * 1.1 + 1))
        }
    }

    // MARK: Device

    private func ensureDevice() throws {
        if device != nil, driver != nil { return }
        if driver == nil || driverKey != config.driverKey {
            closeDriver()
            let d = try makeDriver(config)
            d.log = { [weak self] in self?.log($0) }
            driver = d
            driverKey = config.driverKey
        }
        snapshot.connection = .connecting
        snapshot.device = .searching
        publish(force: true)
        let opened = try driver!.open()
        device = opened
        renderer.setLayout(opened.layout)
        lastSent = []
        retryDelay = 1
        snapshot.connection = .connected(driver!.connectionInfo)
        snapshot.layout = opened.layout
        snapshot.identity = opened.identity
        snapshot.modes = opened.modes
        snapshot.device = .ready(name: opened.name, leds: opened.ledCount, mode: opened.mode)
        snapshot.lastError = nil
    }

    private func idleColors() -> [RGB8] {
        renderer.idleFrame().map { ($0 * Float(renderer.settings.brightness)).rgb8 }
    }

    private func closeDriver() {
        driver?.close()
        driver = nil
        device = nil
        lastSent = []
        snapshot.connection = .disconnected
    }

    private func handle(_ error: Error) {
        let message = String(describing: error)
        if snapshot.lastError != message { log("Error: \(message)") }
        snapshot.lastError = message
        driver?.close()
        device = nil
        switch error {
        case DriverError.deviceMissing(let available):
            snapshot.device = .notFound(available: available)
            snapshot.connection = .disconnected
        case OpenRGBError.noDirectMode, OpenRGBError.directModeRejected, NativeHIDError.unexpectedDevice, NativeHIDError.notFound:
            snapshot.device = .failed(message)
            snapshot.connection = .disconnected
        default:
            snapshot.connection = .failed(message)
            snapshot.device = .none
        }
        if running && config.autoReconnect {
            nextRetry = CACurrentMediaTime() + retryDelay
            retryDelay = min(5, retryDelay * 2)
        } else if running {
            nextRetry = .infinity
        }
        publish(force: true)
    }

    private func log(_ line: String) {
        let stamp = Self.timeFormatter.string(from: Date())
        snapshot.log.append("\(stamp)  \(line)")
        if snapshot.log.count > 200 { snapshot.log.removeFirst(snapshot.log.count - 200) }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    private func publish(force: Bool) {
        let now = CACurrentMediaTime()
        guard force || now - lastPublish >= 1.0 / 20 else { return }
        lastPublish = now
        let snap = snapshot
        onSnapshot?(snap)
    }
}

import AppKit
import BeatRGBKit
import Combine
import ServiceManagement
import SwiftUI

/// UI-facing state. Owns the engine, capture and screen sampler; all mutations happen on the main actor.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    // Live state
    @Published private(set) var snapshot = EngineSnapshot()
    @Published private(set) var isSyncing = false
    @Published private(set) var captureState: CaptureState = .stopped
    @Published private(set) var screenState: ScreenSampler.State = .stopped
    @Published private(set) var screenError: String?
    @Published private(set) var knobState: KnobController.State = .off
    @Published private(set) var knobLastEvent = "—"
    @Published private(set) var otherRGBApps: [String] = []
    @Published private(set) var silentFor: TimeInterval = 0
    @Published private(set) var inputDevices: [AudioDeviceInfo] = []
    /// Devices OpenRGB reported in the last scan (for the keyboard picker).
    @Published private(set) var openRGBDevices: [RGBDevice] = []
    @Published private(set) var deviceScanError: String?
    @Published var testResult: String?

    // Profiles
    @Published var library: ProfileLibrary {
        didSet { scheduleSave(); pushSettings(old: oldValue.active?.settings) }
    }

    // Preferences
    @Published var prefs: Preferences { didSet { prefs.save(); applyPrefs(old: oldValue) } }

    private let engine = LightingEngine()
    private let store = ProfileStore()
    private var capture: AudioCapture?
    private var screen: ScreenSampler?
    private let knob = KnobController()
    private var saveWork: DispatchWorkItem?
    /// Keeps App Nap from throttling the lighting loop while BeatRGB has no visible window.
    private var syncActivity: NSObjectProtocol?
    private var timers: Set<AnyCancellable> = []

    var settings: LightingSettings {
        get { library.active?.settings ?? LightingSettings() }
        set {
            guard let id = library.active?.id, let i = library.profiles.firstIndex(where: { $0.id == id }) else { return }
            library.profiles[i].settings = newValue
        }
    }

    private init() {
        library = store.load()
        prefs = Preferences.load()
        engine.onSnapshot = { [weak self] snap in
            Task { @MainActor in self?.snapshot = snap }
        }
        engine.configure(prefs.engineConfig)
        engine.update(settings: settings)
        knob.onState = { [weak self] s in self?.knobState = s }
        knob.onEvent = { [weak self] event, result in
            switch event {
            case .rotate(let d): self?.knobLastEvent = "\(d > 0 ? "Clockwise" : "Counter-clockwise") → \(result)"
            case .press: self?.knobLastEvent = "Press → \(result)"
            }
        }
        if prefs.knobEnabled { knob.start() }
        applyDockPolicy()
        refreshInputDevices()
        Timer.publish(every: 2, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.periodicChecks() }
            .store(in: &timers)
        periodicChecks()
        if prefs.startSyncOnLaunch { start() }
    }

    // MARK: Sync

    func toggle() { isSyncing ? stop() : start() }

    func start() {
        guard !isSyncing else { return }
        isSyncing = true
        syncActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Syncing keyboard lighting")
        startCapture()
        updateScreenSampler()
        engine.start()
    }

    func stop(completion: (() -> Void)? = nil) {
        guard isSyncing else { completion?(); return }
        isSyncing = false
        if let a = syncActivity { ProcessInfo.processInfo.endActivity(a); syncActivity = nil }
        stopCapture()
        stopScreen()
        engine.stop { Task { @MainActor in completion?() } }
    }

    /// Called from applicationShouldTerminate: restore lighting, release audio, then quit.
    func shutdown(_ done: @escaping () -> Void) {
        knob.stop()
        stop(completion: done)
    }

    func sendTestColor(_ color: Color) {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .red
        let rgb = RGB8(UInt8(c.redComponent * 255), UInt8(c.greenComponent * 255), UInt8(c.blueComponent * 255))
        testResult = "Sending…"
        engine.sendTestColor(rgb) { result in
            Task { @MainActor in
                switch result {
                case .success(let detail): self.testResult = "\(detail). Check that the physical keys changed."
                case .failure(let e): self.testResult = "Failed: \((e as? OpenRGBError)?.description ?? "\(e)")"
                }
            }
        }
    }

    /// Refreshes the keyboard picker's list from OpenRGB.
    func refreshOpenRGBDevices() {
        engine.scanDevices { result in
            Task { @MainActor in
                switch result {
                case .success(let devices): self.openRGBDevices = devices; self.deviceScanError = nil
                case .failure(let e): self.deviceScanError = (e as? OpenRGBError)?.description ?? "\(e)"
                }
            }
        }
    }

    func scanDevices(_ done: @escaping (String) -> Void) {
        engine.scanDevices { result in
            let text: String
            switch result {
            case .success(let devices):
                text = devices.isEmpty ? "OpenRGB reports no devices." : devices.map {
                    "[\($0.index)] \($0.name) — \($0.vendor), \($0.leds.count) LEDs, modes: \($0.modes.map(\.name).joined(separator: ", ")), active: \($0.activeModeName), serial \($0.serial)"
                }.joined(separator: "\n")
            case .failure(let e):
                text = (e as? OpenRGBError)?.description ?? "\(e)"
            }
            Task { @MainActor in done(text) }
        }
    }

    // MARK: Audio capture

    private func startCapture() {
        stopCapture()
        let c: AudioCapture
        switch prefs.captureSource {
        case .systemAudio: c = SystemAudioCapture()
        case .inputDevice(let uid, _): c = InputDeviceCapture(uid: uid)
        }
        c.onStateChange = { [weak self] state in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.captureState = state }
            } else {
                Task { @MainActor in self?.captureState = state }
            }
        }
        capture = c
        let begin = { [weak self] in
            do {
                try c.start()
                self?.engine.setAudioSource(c.ring)
            } catch {
                self?.engine.setAudioSource(nil)
            }
        }
        if case .inputDevice = prefs.captureSource {
            AVCaptureAuthorization.request { granted in
                if granted { begin() } else { self.captureState = .failed("Microphone permission is required for input devices.") }
            }
        } else {
            begin()
        }
    }

    private func stopCapture() {
        engine.setAudioSource(nil)
        capture?.stop()
        capture = nil
        silentFor = 0
    }

    // MARK: Screen

    private func updateScreenSampler() {
        if isSyncing && settings.effect.usesScreen {
            let display = settings.screenDisplayIndex
            if screen == nil {
                let s = ScreenSampler()
                s.onStateChange = { [weak self, weak s] state in
                    let error = s?.lastError
                    Task { @MainActor in self?.screenState = state; self?.screenError = error }
                }
                screen = s
                engine.setScreenSampler(s)
                Task { await s.start(displayIndex: display) }
            }
        } else {
            stopScreen()
        }
    }

    private func stopScreen() {
        guard let s = screen else { return }
        screen = nil
        engine.setScreenSampler(nil)
        Task { await s.stop() }
    }

    func restartScreen() {
        stopScreen()
        updateScreenSampler()
    }

    // MARK: Settings plumbing

    private func pushSettings(old: LightingSettings?) {
        let new = settings
        guard new != old else { return }
        engine.update(settings: new)
        if old?.effect != new.effect || old?.screenDisplayIndex != new.screenDisplayIndex {
            if old?.screenDisplayIndex != new.screenDisplayIndex { stopScreen() }
            updateScreenSampler()
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let lib = library, store = store
        let work = DispatchWorkItem { try? store.save(lib) }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func applyPrefs(old: Preferences) {
        engine.configure(prefs.engineConfig)
        if prefs.knobEnabled != old.knobEnabled { prefs.knobEnabled ? knob.start() : knob.stop() }
        if prefs.hideDockIcon != old.hideDockIcon { applyDockPolicy() }
        if prefs.captureSource != old.captureSource && isSyncing { startCapture() }
    }

    func applyDockPolicy() {
        NSApp?.setActivationPolicy(prefs.hideDockIcon ? .accessory : .regular)
    }

    func lockToCurrentKeyboard(_ lock: Bool) {
        prefs.lockedSerial = lock ? snapshot.identity?.serial : nil
    }

    // MARK: Profiles

    func selectProfile(_ id: UUID) { library.activeID = id }

    func addProfile(copying source: LightingProfile? = nil) {
        let base = source ?? library.active
        let p = LightingProfile(name: base.map { "\($0.name) copy" } ?? "New Profile", settings: base?.settings ?? LightingSettings())
        library.profiles.append(p)
        library.activeID = p.id
    }

    func deleteProfile(_ id: UUID) {
        guard library.profiles.count > 1 else { return }
        library.profiles.removeAll { $0.id == id }
        if library.activeID == id { library.activeID = library.profiles.first?.id }
    }

    func renameProfile(_ id: UUID, to name: String) {
        guard let i = library.profiles.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        library.profiles[i].name = trimmed.isEmpty ? "Untitled" : trimmed
    }

    func restoreBuiltInProfiles() {
        let existing = Set(library.profiles.map(\.name))
        library.profiles += ProfileLibrary.builtIn.profiles.filter { !existing.contains($0.name) }
    }

    // MARK: Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                testResult = "Launch at login: \(error.localizedDescription)"
            }
            objectWillChange.send()
        }
    }

    var launchAtLoginStatus: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "Enabled"
        case .requiresApproval: return "Needs approval in System Settings → General → Login Items"
        case .notRegistered: return "Off"
        case .notFound: return "Off"
        @unknown default: return "Unknown"
        }
    }

    // MARK: Periodic checks

    func refreshInputDevices() { inputDevices = AudioDevices.inputDevices() }

    private func periodicChecks() {
        otherRGBApps = NSWorkspace.shared.runningApplications.compactMap { app in
            let id = (app.bundleIdentifier ?? "").lowercased(), name = app.localizedName ?? ""
            if id.contains("corsair") || name.lowercased().contains("icue") { return "Corsair iCUE" }
            if id.contains("signalrgb") { return "SignalRGB" }
            let lower = name.lowercased()
            if lower.contains("razer synapse") { return "Razer Synapse" }
            if id.contains("com.logi.ghub") || lower.contains("g hub") { return "Logitech G HUB" }
            if lower.contains("steelseries") { return "SteelSeries GG" }
            if prefs.backend == .native && name.lowercased().hasPrefix("openrgb") { return "OpenRGB" }
            return nil
        }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        if isSyncing, case .running = captureState, snapshot.features.rmsDB < -100 {
            silentFor += 2
        } else {
            silentFor = 0
        }
    }
}

/// Persisted app preferences (UserDefaults, JSON-encoded).
struct Preferences: Codable, Equatable {
    var backend = Backend.openRGB
    var host = "127.0.0.1"
    var port: Int = 6742
    var autoReconnect = true
    var stopBehavior = StopBehavior.restorePrevious
    var captureSource = CaptureSource.systemAudio
    var lockedSerial: String?
    /// OpenRGB device picked in Settings; nil = first RGB keyboard found.
    var deviceName: String?
    var knobEnabled = true
    var hideDockIcon = false
    var startSyncOnLaunch = false
    var openInBackground = false

    var engineConfig: EngineConfig {
        var c = EngineConfig()
        c.host = host
        c.port = UInt16(clamping: port)
        c.autoReconnect = autoReconnect
        c.stopBehavior = stopBehavior
        c.backend = backend
        c.matcher = DeviceMatcher(serial: lockedSerial, name: deviceName)
        return c
    }

    private static let key = "BeatRGB.preferences"

    static func load() -> Preferences {
        guard let data = UserDefaults.standard.data(forKey: key),
              let p = try? JSONDecoder().decode(Preferences.self, from: data) else { return Preferences() }
        return p
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        host = v(.host, d.host); port = v(.port, d.port); autoReconnect = v(.autoReconnect, d.autoReconnect)
        backend = v(.backend, d.backend)
        stopBehavior = v(.stopBehavior, d.stopBehavior); captureSource = v(.captureSource, d.captureSource)
        lockedSerial = v(.lockedSerial, d.lockedSerial); deviceName = v(.deviceName, d.deviceName); knobEnabled = v(.knobEnabled, d.knobEnabled)
        hideDockIcon = v(.hideDockIcon, d.hideDockIcon); startSyncOnLaunch = v(.startSyncOnLaunch, d.startSyncOnLaunch)
        openInBackground = v(.openInBackground, d.openInBackground)
    }
}

import AVFoundation

enum AVCaptureAuthorization {
    @MainActor static func request(_ done: @escaping @MainActor (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in Task { @MainActor in done(ok) } }
        default: done(false)
        }
    }
}

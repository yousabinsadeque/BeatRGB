import BeatRGBKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Panel(title: "Run in the background") {
                Toggle("Open in the background (no window, menu bar icon only)", isOn: $model.prefs.openInBackground)
                Toggle("Hide Dock icon", isOn: $model.prefs.hideDockIcon)
                Toggle("Start sync when BeatRGB opens", isOn: $model.prefs.startSyncOnLaunch)
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                Text(model.launchAtLoginStatus).font(.caption).foregroundStyle(.secondary)
                Button("Set up full background mode") {
                    model.prefs.openInBackground = true
                    model.prefs.hideDockIcon = true
                    model.prefs.startSyncOnLaunch = true
                    model.launchAtLogin = true
                }
                Text("Closing the window keeps BeatRGB running and lighting the keyboard from the menu bar icon; use Quit there to exit. Full background mode turns on all four options above, so lighting starts by itself when you log in.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Panel(title: "Keyboard connection") {
                Picker("Control the keyboard with", selection: $model.prefs.backend) {
                    ForEach(Backend.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Text(model.prefs.backend == .native
                     ? "Only for the Corsair K70 CORE RGB TKL: BeatRGB talks to it over USB itself using the Corsair Peripheral V2 protocol (as implemented by OpenRGB's open-source driver). Quit OpenRGB and iCUE first — only one program can drive the lighting. On stop, “Restore previous lighting” hands the keyboard back to its own on-board effect. For any other keyboard, choose OpenRGB."
                     : "Works with any RGB keyboard OpenRGB supports (Corsair, Razer, Logitech, SteelSeries, ASUS, HyperX, Redragon and many more — see openrgb.org/devices). BeatRGB sends colours through OpenRGB's SDK server, which must be running, and lays effects out using the key map OpenRGB reports.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if model.prefs.backend == .openRGB {
            Panel(title: "OpenRGB connection") {
                HStack {
                    TextField("Host", text: $model.prefs.host).frame(width: 180)
                    TextField("Port", value: $model.prefs.port, format: .number.grouping(.never)).frame(width: 80)
                }
                .textFieldStyle(.roundedBorder)
                HStack {
                    Picker("Keyboard", selection: $model.prefs.deviceName) {
                        Text("Automatic — first RGB keyboard").tag(String?.none)
                        ForEach(pickerNames, id: \.self) { name in Text(name).tag(String?.some(name)) }
                    }
                    .frame(maxWidth: 420)
                    Button("Refresh") { model.refreshOpenRGBDevices() }
                }
                .onAppear { model.refreshOpenRGBDevices() }
                if let e = model.deviceScanError { Text(e).font(.caption).foregroundStyle(.secondary) }
                Toggle("Only control this exact keyboard (match serial number)", isOn: Binding(
                    get: { model.prefs.lockedSerial != nil },
                    set: { model.lockToCurrentKeyboard($0) }))
                    .disabled(model.snapshot.identity == nil && model.prefs.lockedSerial == nil)
                Text(model.prefs.lockedSerial.map { "Locked to serial \($0)" }
                     ?? (model.prefs.deviceName.map { "BeatRGB drives “\($0)”." }
                         ?? "BeatRGB drives the first keyboard OpenRGB reports that has a Direct (per-key) mode. Pick one above to choose another device."))
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("How to enable the OpenRGB SDK server") {
                    Text("""
                    1. Open OpenRGB and go to the SDK Server tab.
                    2. Click Start Server (port 6742). To start it automatically, launch OpenRGB with --server --startminimized, or enable “Start Server” under Settings → General.
                    3. Do not run an effect from the OpenRGB Effects plugin at the same time — BeatRGB renders all effects itself.
                    4. Quit Corsair iCUE (or disable its lighting) so it doesn't overwrite BeatRGB's colours.
                    """)
                    .font(.callout).textSelection(.enabled).padding(.top, 4)
                }
            }
            }

            Panel(title: "When sync stops") {
                Picker("When sync stops", selection: $model.prefs.stopBehavior) {
                    ForEach(StopBehavior.allCases) { Text($0.title).tag($0) }
                }
                .frame(maxWidth: 360)
                Toggle("Reconnect automatically", isOn: $model.prefs.autoReconnect)
            }

            Panel(title: "Audio source") {
                Picker("Capture from", selection: $model.prefs.captureSource) {
                    Text(CaptureSource.systemAudio.displayName).tag(CaptureSource.systemAudio)
                    ForEach(model.inputDevices) { d in
                        Text("\(d.name)\(d.isLikelyLoopback ? " (loopback)" : " — microphone/input")")
                            .tag(CaptureSource.inputDevice(uid: d.uid, name: d.name))
                    }
                }
                .frame(maxWidth: 460)
                HStack {
                    Button("Refresh devices") { model.refreshInputDevices() }
                    Spacer()
                }
                Text("System audio uses a Core Audio process tap: it hears Spotify, Apple Music, browsers and everything else the Mac plays, on built-in or external outputs, without changing playback and excluding BeatRGB's own sounds. An input device is only used if you pick it here — e.g. a BlackHole loopback as a fallback. Picking a real microphone makes the lights react to the room, not the music.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Panel(title: "Permissions & troubleshooting") {
                PermissionRow(title: "System Audio Recording",
                              detail: "Requested the first time sync starts. If audio stays silent while music plays, enable BeatRGB under Screen & System Audio Recording → System Audio Recording Only.",
                              url: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")
                PermissionRow(title: "Screen Recording (Screen Mirror only)",
                              detail: ScreenSampler.hasPermission ? "Granted." : "Not granted. Needed only for the Screen Mirror effect.",
                              url: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
                PermissionRow(title: "Microphone (input-device source only)",
                              detail: "Needed only if you choose an input device such as BlackHole.",
                              url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                PermissionRow(title: "Input Monitoring (volume knob only)",
                              detail: "May be needed for the experimental volume knob.",
                              url: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
            }

            Panel(title: "Volume knob") {
                Toggle("Use the K70 CORE's rotary dial for Mac volume", isOn: $model.prefs.knobEnabled)
                Text("When sync is stopped the dial changes volume on its own. While BeatRGB drives the lights over USB, the keyboard reports the dial to BeatRGB instead, and BeatRGB changes the default output's volume through Core Audio. No keyboard events are injected. Pressing the dial isn't supported yet.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.prefs.knobEnabled {
                    LabeledContent("Status", value: knobText)
                    LabeledContent("Last event", value: model.knobLastEvent)
                }
            }
        }
    }

    /// Names from the last scan, plus the saved pick so the picker never shows a blank selection.
    private var pickerNames: [String] {
        var names = model.openRGBDevices.map(\.name)
        if let n = model.prefs.deviceName, !names.contains(n) { names.append(n) }
        return names.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    private var knobText: String {
        switch model.knobState {
        case .off: return "Off"
        case .waiting: return "Waiting for the keyboard…"
        case .listening(let s): return "Listening (\(s))"
        case .failed(let e): return e
        }
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let url: String
    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Open Settings") { if let u = URL(string: url) { NSWorkspace.shared.open(u) } }
        }
    }
}

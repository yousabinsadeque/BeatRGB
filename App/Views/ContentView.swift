import BeatRGBKit
import SwiftUI

enum Section: String, CaseIterable, Identifiable {
    case dashboard, studio, profiles, settings, diagnostics
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .studio: return "Lighting Studio"
        case .profiles: return "Profiles"
        case .settings: return "Settings"
        case .diagnostics: return "Diagnostics"
        }
    }
    var symbol: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.67percent"
        case .studio: return "paintbrush.pointed"
        case .profiles: return "square.stack"
        case .settings: return "gearshape"
        case .diagnostics: return "stethoscope"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var section: Section? = .dashboard

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $section) { s in
                Label(s.title, systemImage: s.symbol).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .bottom) {
                SyncButton().padding(12)
            }
        } detail: {
            ScrollView {
                Group {
                    switch section ?? .dashboard {
                    case .dashboard: DashboardView()
                    case .studio: StudioView()
                    case .profiles: ProfilesView()
                    case .settings: SettingsView()
                    case .diagnostics: DiagnosticsView()
                    }
                }
                .padding(20)
                .frame(maxWidth: 1000, alignment: .topLeading)
            }
            .navigationTitle((section ?? .dashboard).title)
        }
    }
}

struct SyncButton: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Button {
            model.toggle()
        } label: {
            Label(model.isSyncing ? "Stop Sync" : "Start Sync", systemImage: model.isSyncing ? "stop.fill" : "play.fill")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .tint(model.isSyncing ? .red : .accentColor)
        .controlSize(.large)
    }
}

// MARK: - Status text shared by dashboard and menu bar

extension AppModel {
    var connectionTitle: String { prefs.backend == .native ? "USB (native)" : "OpenRGB SDK" }

    var connectionStatus: (StatusLevel, String, String?) {
        let target = prefs.backend == .native ? "Direct USB to the keyboard" : "\(prefs.host):\(prefs.port)"
        switch snapshot.connection {
        case .disconnected: return (.off, isSyncing ? "Connecting…" : "Not connected", target)
        case .connecting: return (.working, "Connecting…", target)
        case .connected(let info): return (.ok, "Connected", info)
        case .failed(let e): return (.error, "Unavailable", e)
        }
    }

    var keyboardStatus: (StatusLevel, String, String?) {
        switch snapshot.device {
        case .none: return (.off, "Not checked", "Start sync or send a test colour")
        case .searching: return (.working, "Searching…", nil)
        case .ready(let name, let leds, let mode): return (.ok, name, "\(leds) LEDs · \(mode) mode")
        case .notFound(let available):
            return (.error, "Keyboard not found", available.isEmpty ? "OpenRGB reports no devices" : "OpenRGB sees: \(available.joined(separator: ", "))")
        case .failed(let e): return (.error, "Unsupported", e)
        }
    }

    var audioStatus: (StatusLevel, String, String?) {
        switch captureState {
        case .stopped: return (.off, "Stopped", prefs.captureSource.displayName)
        case .starting: return (.working, "Starting…", nil)
        case .running(let fmt):
            if silentFor >= 8 {
                return (.warning, "Running — silent", "Nothing audible for \(Int(silentFor)) s. If music is playing, check System Audio Recording permission.")
            }
            return (.ok, "Capturing", "\(fmt) · output: \(AudioDevices.defaultOutputName() ?? "unknown")")
        case .failed(let e): return (.error, "Failed", e)
        }
    }
}

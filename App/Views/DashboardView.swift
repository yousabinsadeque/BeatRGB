import BeatRGBKit
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !model.otherRGBApps.isEmpty {
                WarningBanner(text: "\(model.otherRGBApps.joined(separator: ", ")) is running. It can fight BeatRGB for the keyboard's lighting — quit it (or disable its lighting control) while syncing.")
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                let kb = model.keyboardStatus, sdk = model.connectionStatus, audio = model.audioStatus
                StatusCard(title: "Keyboard", symbol: "keyboard", level: kb.0, value: kb.1, detail: kb.2)
                StatusCard(title: model.connectionTitle, symbol: model.prefs.backend == .native ? "cable.connector" : "network", level: sdk.0, value: sdk.1, detail: sdk.2)
                StatusCard(title: "System audio", symbol: "waveform", level: audio.0, value: audio.1, detail: audio.2)
                StatusCard(title: "Effect", symbol: model.settings.effect.symbol, level: model.isSyncing ? .ok : .off,
                           value: model.settings.effect.title,
                           detail: model.isSyncing ? String(format: "%.0f fps · %.0f ms device latency", model.snapshot.fps, model.snapshot.latencyMs)
                                                   : "Profile: \(model.library.active?.name ?? "—")")
            }

            KeyboardPreview(layout: model.snapshot.layout, frame: model.snapshot.frame)
                .frame(maxHeight: 260)

            HStack(alignment: .top, spacing: 12) {
                Panel(title: "Audio level") {
                    LevelMeter(level: model.snapshot.features.level, db: model.snapshot.features.rmsDB)
                    HStack(spacing: 16) {
                        Meter(label: "Bass", value: model.snapshot.features.bass)
                        Meter(label: "Mid", value: model.snapshot.features.mid)
                        Meter(label: "Treble", value: model.snapshot.features.treble)
                    }
                }
                .frame(maxWidth: 320)
                Panel(title: "Frequency spectrum") {
                    SpectrumView(bands: model.snapshot.features.bands)
                }
            }

            Panel(title: "Controls") {
                HStack(spacing: 20) {
                    SyncButton().frame(width: 180)
                    LabeledSlider(title: "Master brightness", value: $model.settings.brightness, range: 0...1)
                }
                if model.settings.effect == .screenMirror, case .permissionDenied = model.screenState {
                    WarningBanner(text: "Screen Mirror needs Screen Recording permission. Enable BeatRGB in System Settings → Privacy & Security → Screen & System Audio Recording, then restart sync.")
                }
            }

            if let err = model.snapshot.lastError, model.isSyncing {
                WarningBanner(text: err, isError: true)
            }
        }
    }
}

struct Meter: View {
    let label: String
    let value: Float
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            ProgressView(value: Double(min(1, max(0, value)))).progressViewStyle(.linear)
        }
    }
}

struct WarningBanner: View {
    let text: String
    var isError = false
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(isError ? .red : .orange)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background((isError ? Color.red : Color.orange).opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

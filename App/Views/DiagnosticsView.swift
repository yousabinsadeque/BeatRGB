import BeatRGBKit
import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject var model: AppModel
    @State private var scan = ""
    @State private var scanning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Panel(title: "Compatibility") {
                LabeledContent("macOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
                LabeledContent("System audio capture", value: "Core Audio process tap (macOS 14.2+) — supported")
                LabeledContent("Screen Mirror", value: "ScreenCaptureKit — \(ScreenSampler.hasPermission ? "permission granted" : "permission not granted")")
                LabeledContent(model.connectionTitle, value: model.connectionStatus.1 + (model.connectionStatus.2.map { " · \($0)" } ?? ""))
                LabeledContent("Target keyboard", value: model.prefs.backend == .native
                               ? "Corsair K70 CORE RGB TKL (USB 1B1C:2B01)"
                               : model.snapshot.identity.map { "\($0.name) (\($0.vendor))" } ?? model.prefs.deviceName ?? "First RGB keyboard OpenRGB reports")
                LabeledContent("Other RGB software", value: model.otherRGBApps.isEmpty ? "None detected" : model.otherRGBApps.joined(separator: ", "))
            }

            Panel(title: "Device scan") {
                HStack {
                    Button(scanning ? "Scanning…" : "Scan OpenRGB devices") {
                        scanning = true
                        model.scanDevices { scan = $0; scanning = false }
                    }
                    .disabled(scanning)
                    Spacer()
                }
                if !scan.isEmpty {
                    Text(scan).font(.caption.monospaced()).textSelection(.enabled)
                }
                if !model.snapshot.modes.isEmpty {
                    LabeledContent("Reported modes", value: model.snapshot.modes.joined(separator: ", "))
                    LabeledContent("LED map", value: "\(model.snapshot.layout.ledCount) LEDs on a \(model.snapshot.layout.rows)×\(model.snapshot.layout.cols) matrix")
                }
            }

            Panel(title: "Performance") {
                LabeledContent("Update rate", value: String(format: "%.1f fps (target %.0f)", model.snapshot.fps, model.snapshot.targetFPS))
                LabeledContent("Device round trip", value: String(format: "%.1f ms", model.snapshot.latencyMs))
                LabeledContent("Frames sent", value: "\(model.snapshot.framesSent) (unchanged frames are skipped)")
            }

            Panel(title: "Log") {
                HStack {
                    Spacer()
                    Button("Copy diagnostics") { copyDiagnostics() }
                }
                ScrollView {
                    Text(model.snapshot.log.reversed().joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 220)
            }
        }
    }

    private func copyDiagnostics() {
        let text = """
        BeatRGB diagnostics
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Backend: \(model.prefs.backend.title) — \(model.connectionStatus.1) \(model.connectionStatus.2 ?? "")
        Keyboard: \(model.keyboardStatus.1) \(model.keyboardStatus.2 ?? "")
        Audio: \(model.audioStatus.1) \(model.audioStatus.2 ?? "")
        Effect: \(model.settings.effect.title)
        FPS: \(model.snapshot.fps) latency: \(model.snapshot.latencyMs) ms
        Other RGB apps: \(model.otherRGBApps)

        \(scan)

        Log:
        \(model.snapshot.log.joined(separator: "\n"))
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

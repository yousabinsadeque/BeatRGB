import BeatRGBKit
import SwiftUI

struct StudioView: View {
    @EnvironmentObject var model: AppModel
    @State private var testColor = Color.red

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            KeyboardPreview(layout: model.snapshot.layout, frame: model.snapshot.frame)
                .frame(maxHeight: 240)

            Panel(title: "Effect") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    ForEach(EffectKind.allCases) { kind in
                        EffectTile(kind: kind, selected: model.settings.effect == kind) { model.settings.effect = kind }
                    }
                }
            }

            HStack(alignment: .top, spacing: 12) {
                Panel(title: "Colour") { colourControls }
                Panel(title: "Response") { responseControls }
            }

            if model.settings.effect == .bassPulse {
                Panel(title: "Bass pulse") {
                    LabeledSlider(title: "Attack", value: $model.settings.pulseAttackMs, range: 5...200, format: { "\(Int($0)) ms" })
                    LabeledSlider(title: "Decay", value: $model.settings.pulseDecayMs, range: 50...1500, format: { "\(Int($0)) ms" })
                    LabeledSlider(title: "Baseline brightness", value: $model.settings.baseline, range: 0...0.6)
                }
            }

            if model.settings.effect == .screenMirror {
                Panel(title: "Screen Mirror") {
                    Text("Keys take the colour of the matching area of your display: the top row follows the top of the screen, the left keys the left edge.")
                        .font(.callout).foregroundStyle(.secondary)
                    LabeledSlider(title: "Colour boost", value: $model.settings.screenSaturation, range: 0...1)
                    Stepper("Display \(model.settings.screenDisplayIndex + 1)", value: $model.settings.screenDisplayIndex, in: 0...5)
                    HStack {
                        Button("Restart screen capture") { model.restartScreen() }
                        Text(screenStateText).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if model.settings.effect.isAudioReactive {
                Panel(title: "When music stops") {
                    Picker("Idle effect", selection: $model.settings.idle) {
                        ForEach(IdleKind.allCases) { Text($0.title).tag($0) }
                    }
                    ColorPicker("Idle colour", selection: $model.settings.idleColor.color, supportsOpacity: false)
                    LabeledSlider(title: "Go idle after", value: $model.settings.idleDelay, range: 0.5...10, format: { String(format: "%.1f s", $0) })
                }
            }

            Panel(title: "Hardware test") {
                Text(model.prefs.backend == .native
                     ? "Paints every key one colour directly over USB and checks the keyboard acknowledged it. Look at the keyboard to confirm the physical LEDs changed."
                     : "Paints every key one colour through OpenRGB, then reads the colours back from OpenRGB. Look at the keyboard to confirm the physical LEDs changed.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    ColorPicker("Test colour", selection: $testColor, supportsOpacity: false).fixedSize()
                    Button("Send to keyboard") { model.sendTestColor(testColor) }
                        .disabled(model.isSyncing)
                    if model.isSyncing { Text("Stop sync first").font(.caption).foregroundStyle(.secondary) }
                }
                if let r = model.testResult { Text(r).font(.callout) }
            }
        }
    }

    private var screenStateText: String {
        switch model.screenState {
        case .stopped: return model.isSyncing ? "Starting…" : "Starts with sync"
        case .starting: return "Starting…"
        case .running(let s): return s
        case .permissionDenied: return "Screen Recording permission needed"
        case .failed(let e): return e
        }
    }

    @ViewBuilder private var colourControls: some View {
        let e = model.settings.effect
        if e == .spectrum {
            Picker("Style", selection: $model.settings.spectrumStyle) {
                ForEach(SpectrumStyle.allCases) { Text($0.title).tag($0) }
            }
        }
        if e != .rainbowWave && e != .screenMirror && !(e == .spectrum && model.settings.spectrumStyle == .multicolor) {
            ColorPicker(e == .spectrum && model.settings.spectrumStyle == .gradient ? "Bottom colour" : "Colour",
                        selection: $model.settings.primaryColor.color, supportsOpacity: false)
        }
        if e == .spectrum && model.settings.spectrumStyle == .gradient {
            ColorPicker("Top colour", selection: $model.settings.secondaryColor.color, supportsOpacity: false)
        }
        LabeledSlider(title: "Brightness", value: $model.settings.brightness, range: 0...1)
        LabeledSlider(title: "Speed", value: $model.settings.speed, range: 0.1...3, format: { String(format: "%.1f×", $0) })
    }

    @ViewBuilder private var responseControls: some View {
        LabeledSlider(title: "Sensitivity", value: $model.settings.sensitivity, range: 0.2...2, format: { String(format: "%.1f×", $0) })
        LabeledSlider(title: "Smoothing", value: $model.settings.smoothing, range: 0...1)
        LabeledSlider(title: "Bass responsiveness", value: $model.settings.bassResponse, range: 0...2, format: { String(format: "%.1f×", $0) })
        Toggle("Adaptive gain (auto-level)", isOn: $model.settings.adaptiveGain)
        Toggle("Noise gate", isOn: $model.settings.noiseGateEnabled)
        if model.settings.noiseGateEnabled {
            LabeledSlider(title: "Gate threshold", value: $model.settings.noiseGateDB, range: -90 ... -30, format: { "\(Int($0)) dBFS" })
        }
        LabeledSlider(title: "Target update rate", value: $model.settings.targetFPS, range: 10...60, format: { "\(Int($0)) fps" })
    }
}

struct EffectTile: View {
    let kind: EffectKind
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: kind.symbol).font(.title2)
                Text(kind.title).font(.caption).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .padding(6)
            .background(selected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }
}

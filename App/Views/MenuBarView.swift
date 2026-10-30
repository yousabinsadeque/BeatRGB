import BeatRGBKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("BeatRGB").font(.headline)
                Spacer()
                StatusDot(level: model.keyboardStatus.0)
                Text(model.keyboardStatus.0 == .ok ? "Keyboard ready" : model.keyboardStatus.1)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            SyncButton()
            Picker("Effect", selection: $model.settings.effect) {
                ForEach(EffectKind.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            Picker("Profile", selection: Binding(get: { model.library.active?.id ?? UUID() }, set: { model.selectProfile($0) })) {
                ForEach(model.library.profiles) { Text($0.name).tag($0.id) }
            }
            LabeledSlider(title: "Brightness", value: $model.settings.brightness, range: 0...1)
            LevelMeter(level: model.snapshot.features.level, db: model.snapshot.features.rmsDB)
            Divider()
            HStack {
                Button("Open BeatRGB") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

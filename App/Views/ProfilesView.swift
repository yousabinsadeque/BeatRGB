import BeatRGBKit
import SwiftUI

struct ProfilesView: View {
    @EnvironmentObject var model: AppModel
    @State private var editingID: UUID?
    @State private var draftName = ""
    @State private var pendingDelete: LightingProfile?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { model.addProfile() } label: { Label("New from current", systemImage: "plus") }
                Button { model.restoreBuiltInProfiles() } label: { Label("Restore built-in profiles", systemImage: "arrow.counterclockwise") }
                Spacer()
            }
            Text("Profiles are saved automatically in ~/Library/Application Support/BeatRGB.")
                .font(.caption).foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(model.library.profiles) { profile in
                    row(profile)
                    if profile.id != model.library.profiles.last?.id { Divider() }
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        }
        .confirmationDialog("Delete “\(pendingDelete?.name ?? "")”?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let p = pendingDelete { model.deleteProfile(p.id) }
                pendingDelete = nil
            }
        }
    }

    @ViewBuilder private func row(_ profile: LightingProfile) -> some View {
        let active = model.library.active?.id == profile.id
        HStack(spacing: 12) {
            Image(systemName: profile.settings.effect.symbol)
                .frame(width: 28, height: 28)
                .background(Color(profile.settings.primaryColor).opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
            if editingID == profile.id {
                TextField("Name", text: $draftName, onCommit: commitRename)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Button("Save", action: commitRename)
            } else {
                VStack(alignment: .leading) {
                    Text(profile.name).font(.body.weight(active ? .semibold : .regular))
                    Text(profile.settings.effect.title).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if active {
                Label("Active", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
            } else {
                Button("Load") { model.selectProfile(profile.id) }
            }
            Menu {
                Button("Rename") { editingID = profile.id; draftName = profile.name }
                Button("Duplicate") { model.addProfile(copying: profile) }
                Divider()
                Button("Delete", role: .destructive) { pendingDelete = profile }
                    .disabled(model.library.profiles.count <= 1)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.selectProfile(profile.id) }
    }

    private func commitRename() {
        if let id = editingID { model.renameProfile(id, to: draftName) }
        editingID = nil
    }
}

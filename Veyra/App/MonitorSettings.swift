import SwiftUI
import AppKit

struct MonitorSettings: View {
    @Bindable var store: MonitorStore
    @Bindable var updates: UpdateStore
    @State private var home = ""
    @State private var executable = ""
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                VeyraIcon(size: 32)
                Text("Uses your existing Codex sign-in and local task records.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            pathField(L10n.text("Codex data directory"), value: $home, placeholder: CodexLocation.resolve().home.path, folder: true)
            pathField(L10n.text("Codex executable"), value: $executable, placeholder: CodexLocation.resolve().executable?.path ?? L10n.text("Auto-detect"), folder: false)
            Text("Leave blank to auto-detect. Checks run every 5 seconds while the menu is open or tasks are running, and every 30 seconds when idle. Quotas use local snapshots; account quotas are requested only when you click “Sync quota”. The app never starts model requests.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                if saved { Label("Saved, refreshing", systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary) }
                Spacer()
                Button("Restore auto-detection") { home = ""; executable = ""; saved = false }
                Button("Save") { store.saveSettings(home: home, executable: executable); saved = true }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
            Divider()
            UpdateSettingsSection(updates: updates)
        }
        .padding(26).frame(width: 570)
        .onAppear { home = store.homePath; executable = store.executablePath }
    }

    private func pathField(_ title: String, value: Binding<String>, placeholder: String, folder: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.callout.weight(.medium))
            HStack {
                TextField(placeholder, text: value).textFieldStyle(.roundedBorder)
                    .onChange(of: value.wrappedValue) { saved = false }
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = folder; panel.canChooseFiles = !folder
                    panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
                    panel.message = title
                    if panel.runModal() == .OK, let url = panel.url { value.wrappedValue = url.path; saved = false }
                }
            }
        }
    }
}

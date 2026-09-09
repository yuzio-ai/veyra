import SwiftUI
import AppKit

// Settings owns its rhythm; native controls own their drawing and focus appearance.
enum SettingsLayout {
    static let width: CGFloat = 570
    static let horizontalPadding: CGFloat = 32
    static let verticalPadding: CGFloat = 28
    static let sectionSpacing: CGFloat = 32
    static let descriptionSpacing: CGFloat = 6
    static let contentSpacing: CGFloat = 20
    static let rowSpacing: CGFloat = 18
    static let labelSpacing: CGFloat = 8
}

struct MonitorSettings: View {
    @Bindable var store: MonitorStore
    @Bindable var updates: UpdateStore
    var shortcuts: ShortcutStore?
    @State private var previewShortcuts = ShortcutStore(registrar: CarbonHotKeyRegistrar())

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing / 2) {
            ShortcutSettingsSection(shortcuts: shortcuts ?? previewShortcuts)
            Divider()
            CodexSettingsSection(store: store)
            Divider()
            UpdateSettingsSection(updates: updates)
        }
        .padding(.horizontal, SettingsLayout.horizontalPadding)
        .padding(.vertical, SettingsLayout.verticalPadding)
        .frame(width: SettingsLayout.width)
        .task { await store.detectConfiguration() }
    }
}

private struct CodexSettingsSection: View {
    @Bindable var store: MonitorStore

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.contentSpacing) {
            VStack(alignment: .leading, spacing: SettingsLayout.descriptionSpacing) {
                Text("Codex").font(.headline)
                Text("Veyra uses your local Codex sign-in and task data.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: SettingsLayout.rowSpacing) {
                PathSettingRow(store: store, field: .home)
                PathSettingRow(store: store, field: .executable)
                CodexStatusRow(store: store)
            }
        }
    }
}

private struct PathSettingRow: View {
    @Bindable var store: MonitorStore
    let field: CodexPathField
    @State private var draft: String?
    @State private var error: CodexPathError?
    @State private var submission = 0

    private var title: String { field == .home ? L10n.text("Data directory") : L10n.text("Executable") }
    private var selectionLabel: String {
        field == .home ? L10n.text("Choose data directory…") : L10n.text("Choose executable…")
    }
    private var text: Binding<String> {
        Binding(get: { draft ?? store.displayedPath(for: field) }, set: { value in
            draft = value
            error = nil
            submission += 1
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.labelSpacing) {
            Text(title).font(.body.weight(.medium))
            HStack(spacing: SettingsLayout.labelSpacing) {
                NativePathField(text: text, title: title, identifier: "settings.path.\(field.rawValue)",
                                commit: commit, discardDraft: resetDraft)
                    .frame(maxWidth: .infinity)
                Button("Choose…", action: choose)
                    .accessibilityLabel(selectionLabel)
                    .accessibilityIdentifier("settings.choose.\(field.rawValue)")
            }
            if let error {
                Label(error.message, systemImage: "exclamationmark.circle")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
            }
        }
        .onChange(of: store.pathResetRevision) { resetDraft() }
        .onAppear { resetDraft() }
        .onDisappear { resetDraft() }
    }

    private func resetDraft() {
        submission += 1
        draft = nil
        error = nil
    }

    private func commit() {
        guard let value = draft else { return }
        if value == store.displayedPath(for: field) { resetDraft(); return }
        submission += 1
        let request = submission, resetVersion = store.pathResetRevision
        Task {
            let result = await store.commitPath(value, field: field, resetVersion: resetVersion)
            guard request == submission else { return }
            switch result {
            case .applied, .unchanged: draft = nil; error = nil
            case .rejected(let failure): error = failure
            case .superseded: break
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = field == .home
        panel.canChooseFiles = field == .executable
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = field == .executable
        panel.message = title
        guard panel.runModal() == .OK, let url = panel.url else { return }
        text.wrappedValue = url.path
        commit()
    }
}

private struct CodexStatusRow: View {
    @Bindable var store: MonitorStore

    private var message: String {
        switch store.configurationState {
        case .detecting: L10n.text("Detecting Codex…")
        case .valid: store.hasManualPaths ? L10n.text("Codex configuration is valid") : L10n.text("Codex detected automatically")
        case .notFound: L10n.text("Codex executable not found")
        case .invalid(.home): L10n.text("Codex data directory is unavailable")
        case .invalid(.executable): L10n.text("Codex executable is invalid")
        }
    }

    var body: some View {
        HStack(spacing: SettingsLayout.labelSpacing) {
            HStack(spacing: 6) {
                if store.configurationState == .detecting {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                } else {
                    Image(systemName: store.configurationState == .valid ? "checkmark.circle" : "exclamationmark.circle")
                        .foregroundStyle(store.configurationState == .valid ? Color.secondary : Color.orange)
                        .accessibilityHidden(true)
                }
                Text(message).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(message)
            .accessibilityIdentifier("settings.codex.status")
            Spacer(minLength: SettingsLayout.labelSpacing)
            if store.hasManualPaths {
                Button("Restore automatic detection") {
                    // End native editing before invalidating any blur-triggered submission.
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    Task { await store.restoreAutomaticPaths() }
                }
            } else {
                Button("Detect Again") { Task { await store.detectConfiguration() } }
            }
        }
        .font(.subheadline).foregroundStyle(.secondary)
    }
}

/// A native field editor preserves macOS keyboard behavior while its cell truncates idle paths.
private struct NativePathField: NSViewRepresentable {
    @Binding var text: String
    let title: String
    let identifier: String
    let commit: () -> Void
    let discardDraft: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> PathTextField {
        let field = PathTextField(string: text)
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingMiddle
        field.font = .preferredFont(forTextStyle: .body)
        field.textColor = .secondaryLabelColor
        field.placeholderString = L10n.text("Auto-detect")
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel(title)
        field.setAccessibilityIdentifier(identifier)
        field.delegate = context.coordinator
        field.onClose = { [weak coordinator = context.coordinator] in
            coordinator?.parent.commit()
            coordinator?.parent.discardDraft()
        }
        return field
    }

    func updateNSView(_ field: PathTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
            if let editor = field.currentEditor() { editor.string = text }
        }
        field.toolTip = text
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PathTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: nsView.intrinsicContentSize.height)
    }

    final class PathTextField: NSTextField {
        var onClose: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
            if let window {
                NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose),
                                                       name: NSWindow.willCloseNotification, object: window)
            }
        }

        @objc private func windowWillClose(_ notification: Notification) {
            onClose?()
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NativePathField
        init(_ parent: NativePathField) { self.parent = parent }

        func controlTextDidBeginEditing(_ notification: Notification) {
            (notification.object as? NSTextField)?.textColor = .labelColor
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            (notification.object as? NSTextField)?.textColor = .secondaryLabelColor
            parent.commit()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertTab(_:)) || selector == #selector(NSResponder.insertBacktab(_:)) {
                // SwiftUI can replace surrounding rows when validation or window visibility changes.
                // Refresh AppKit's loop, then let the field editor perform its normal navigation.
                control.window?.recalculateKeyViewLoop()
                return false
            }
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            parent.commit()
            return true
        }
    }
}

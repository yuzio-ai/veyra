import AppKit
import SwiftUI
import Carbon

struct ShortcutSettingsSection: View {
    @Bindable var shortcuts: ShortcutStore
    @State private var layoutRevision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.contentSpacing) {
            VStack(alignment: .leading, spacing: SettingsLayout.descriptionSpacing) {
                Text("Keyboard Shortcut").font(.headline)
                Text("Show or hide Veyra from any app.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            HStack {
                Toggle("Enable global shortcut", isOn: Binding(get: { shortcuts.preferences.enabled },
                                                               set: { shortcuts.setEnabled($0) }))
                    .accessibilityIdentifier("settings.shortcut.enabled")
                Spacer()
                ShortcutRecorder(shortcuts: shortcuts, layoutRevision: layoutRevision)
                    .frame(width: 170, height: 26)
                Button("Restore Default") { shortcuts.restoreDefault() }
                    .disabled(shortcuts.isRecording)
                    .accessibilityIdentifier("settings.shortcut.reset")
            }
            if let error = shortcuts.errorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.shortcut.error")
            }
        }
        .onReceive(DistributedNotificationCenter.default().publisher(
            for: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String))) { _ in
                layoutRevision += 1
            }
        .onDisappear { shortcuts.cancelRecording() }
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    var shortcuts: ShortcutStore
    var layoutRevision: Int

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.shortcuts = shortcuts
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.target = button
        button.action = #selector(RecorderButton.beginRecording)
        button.setAccessibilityIdentifier("settings.shortcut.recorder")
        button.setAccessibilityLabel(L10n.text("Record shortcut"))
        return button
    }

    func updateNSView(_ button: RecorderButton, context: Context) {
        button.title = shortcuts.isRecording ? L10n.text("Press shortcut…") : shortcuts.preferences.shortcut.displayName
        button.toolTip = L10n.text("Click to record. Press Escape to cancel.")
        if !shortcuts.isRecording { button.removeMonitor() }
    }

    static func dismantleNSView(_ button: RecorderButton, coordinator: ()) { button.cancel() }

    final class RecorderButton: NSButton {
        var shortcuts: ShortcutStore?
        private var monitor: Any?
        override var acceptsFirstResponder: Bool { true }

        @objc func beginRecording() {
            guard let shortcuts, let window else { return }
            window.makeFirstResponder(self)
            shortcuts.beginRecording()
            guard monitor == nil else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(cancel),
                name: NSWindow.didResignKeyNotification, object: window)
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    guard let self, let shortcuts = self.shortcuts, shortcuts.isRecording,
                          event.window === self.window else { return false }
                    if event.isARepeat { return true }
                    if event.keyCode == 53 { self.cancel(); return true }
                    shortcuts.record(GlobalShortcut(keyCode: UInt32(event.keyCode), modifiers: ShortcutModifiers(event.modifierFlags)))
                    if !shortcuts.isRecording { self.removeMonitor() }
                    return true
                }
                return consumed ? nil : event
            }
        }

        override func resignFirstResponder() -> Bool {
            cancel()
            return super.resignFirstResponder()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { cancel() }
        }

        @objc func cancel() {
            removeMonitor()
            shortcuts?.cancelRecording()
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            NotificationCenter.default.removeObserver(self)
        }
    }
}

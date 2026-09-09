import AppKit
import SwiftUI

/// Opt-in native-control checks using isolated settings and temporary filesystem fixtures.
@MainActor
enum SettingsInteractionChecks {
    static func run(to directory: URL) async throws {
        let files = FileManager.default
        let home = files.temporaryDirectory.appendingPathComponent("veyra-settings-ui-\(UUID().uuidString)")
        try files.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: home) }
        let executable = home.appendingPathComponent("codex")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let suite = "veyra-settings-ui-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let location = CodexLocation(home: home, executable: executable)
        let store = MonitorStore(defaults: defaults, inspectConfiguration: { _, _ in
            CodexConfigurationReport(location: location, state: .valid)
        })
        store.isPreview = true
        let hosting = NSHostingView(rootView: MonitorSettings(store: store, updates: .preview(.idle)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsLayout.width, height: 1),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = L10n.text("Veyra Settings")
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.close() }
        try await wait { store.configurationState == .valid && fields(in: hosting).count == 2 }
        hosting.layoutSubtreeIfNeeded()
        window.setContentSize(hosting.fittingSize)
        let pathFields = fields(in: hosting)
        let homeField = pathFields[0], executableField = pathFields[1]
        try require(homeField.accessibilityLabel() == L10n.text("Data directory"), "directory accessibility label")
        try require(executableField.accessibilityLabel() == L10n.text("Executable"), "executable accessibility label")
        try require(abs(homeField.frame.width - executableField.frame.width) < 1, "matching path widths")
        try require(homeField.lineBreakMode == .byTruncatingMiddle, "native middle truncation")

        // Focusing, selecting and submitting an unchanged detected path must not create an override.
        let homeEditor = try focus(homeField, in: window)
        homeEditor.selectAll(nil)
        try require(homeEditor.selectedRange().length == home.path.utf16.count, "select full detected path")
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try require(homeEditor.writeSelection(to: pasteboard, types: homeEditor.writablePasteboardTypes), "copy full path")
        try require(pasteboard.string(forType: .string) == home.path, "clipboard contains full path")
        try require(homeEditor.readSelection(from: pasteboard), "paste full path")
        homeEditor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try await pause()
        try require(!store.hasManualPaths, "focus and Return preserve automatic mode")

        // Return validates and persists; replacing text uses the actual native field editor.
        let chosen = home.appendingPathComponent("chosen directory")
        try files.createDirectory(at: chosen, withIntermediateDirectories: true)
        replace(homeEditor, with: chosen.path)
        homeEditor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try await wait { defaults.string(forKey: "codexHome") == chosen.path }
        try require(homeField.toolTip == chosen.path, "complete path tooltip")

        let selectedExecutable = home.appendingPathComponent("selected-codex")
        try files.createSymbolicLink(at: selectedExecutable, withDestinationURL: executable)
        let executableEditor = try focus(executableField, in: window)
        replace(executableEditor, with: selectedExecutable.path)
        window.makeFirstResponder(nil)
        try await wait { defaults.string(forKey: "codexExecutable") == selectedExecutable.path }

        // Invalid committed text remains visible, without altering the last applied value.
        replace(try focus(homeField, in: window), with: "invalid/relative-path")
        window.makeFirstResponder(nil)
        try await pause()
        hosting.layoutSubtreeIfNeeded()
        window.setContentSize(hosting.fittingSize)
        try require(homeField.stringValue == "invalid/relative-path", "invalid draft remains editable")
        try require(defaults.string(forKey: "codexHome") == chosen.path, "invalid draft is not persisted")
        try PreviewSupport.saveBitmap(hosting, to: directory.appendingPathComponent("settings-native-invalid.png"))

        // Closing a retained Settings view drops its invalid draft on reopening.
        window.close()
        try await pause()
        window.makeKeyAndOrderFront(nil)
        try await wait { homeField.stringValue == chosen.path }

        // Native Tab leaves the field; the full system key-view loop decides the next control.
        let editor = try focus(homeField, in: window)
        editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
        try await pause()
        try require(homeField.currentEditor() == nil, "native Tab advances focus")
        if let nextEditor = window.firstResponder as? NSTextView {
            nextEditor.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
            try await pause()
            try require(homeField.currentEditor() != nil, "native Shift-Tab returns focus")
        }

        await store.restoreAutomaticPaths()
        try await wait { homeField.stringValue == home.path && executableField.stringValue == executable.path }
        try require(!store.hasManualPaths, "restore clears both overrides and drafts")
        let checks = ["matching-widths", "accessibility-labels", "native-middle-truncation", "focus-without-override",
                      "select-all", "copy-paste", "return-commit", "focus-loss-commit", "invalid-draft", "close-and-reopen", "tab-navigation", "restore"]
        try JSONSerialization.data(withJSONObject: ["passed": checks], options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("settings-native-checks.json"))
        print("Passed \(checks.count) native Settings interaction checks")
    }

    private static func fields(in view: NSView) -> [NSTextField] {
        if let field = view as? NSTextField, field.isEditable { return [field] }
        return view.subviews.flatMap { fields(in: $0) }
    }

    private static func focus(_ field: NSTextField, in window: NSWindow) throws -> NSTextView {
        window.makeFirstResponder(field)
        guard let editor = field.currentEditor() as? NSTextView else { throw CheckError.failed("native field focus") }
        return editor
    }

    private static func replace(_ editor: NSTextView, with text: String) {
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    private static func require(_ condition: Bool, _ check: String) throws {
        if !condition { throw CheckError.failed(check) }
    }

    private static func pause() async throws { try await Task.sleep(for: .milliseconds(120)) }

    private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<50 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(40))
        }
        throw CheckError.failed("timed out waiting for settings update")
    }

    private enum CheckError: Error { case failed(String) }
}

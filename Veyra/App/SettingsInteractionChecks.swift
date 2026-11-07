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
        let registrar = SettingsHotKeyFixture()
        let shortcuts = ShortcutStore(registrar: registrar, defaults: defaults)
        shortcuts.start()
        defer { shortcuts.stop() }
        let updates = UpdateStore.preview(.idle)
        try checkWindowRestoration()
        let bundledVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        try require(bundledVersion != nil && updates.currentVersion == bundledVersion, "preview uses built app version")
        let available = UpdateStore.preview(.available).availableRelease
        guard let current = AppVersion(updates.currentVersion), let available,
              let next = AppVersion(available.version), next > current else {
            throw CheckError.failed("preview update is newer than built app")
        }
        let hosting = NSHostingView(rootView: MonitorSettings(store: store, updates: updates, shortcuts: shortcuts)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = SettingsWindow.make(hosting: hosting)
        let constructionMinimum = window.contentMinSize
        window.appearance = NSAppearance(named: .aqua)
        window.isReleasedWhenClosed = false
        window.title = L10n.text("Veyra Settings")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.close() }
        try await wait { store.configurationState == .valid && fields(in: hosting).count == 2 }
        hosting.layoutSubtreeIfNeeded()
        let layoutMinimum = window.contentMinSize
        let layoutFrameMinimum = window.minSize
        try require(layoutMinimum == constructionMinimum,
                    "minimum survives first hosting layout")
        try require(layoutFrameMinimum == window.frameRect(forContentRect: NSRect(origin: .zero, size: constructionMinimum)).size,
                    "frame minimum includes native window chrome")
        window.setContentSize(NSSize(width: SettingsLayout.width, height: 720))
        try require(window.toolbar == nil, "single-page settings have no tabs")
        window.setContentSize(NSSize(width: SettingsLayout.width, height: 440))
        try await pause()
        hosting.layoutSubtreeIfNeeded()
        guard let scroll = scrollView(in: hosting), let document = scroll.documentView else {
            throw CheckError.failed("settings scroll view exists")
        }
        try require(document.bounds.height > scroll.contentView.bounds.height, "short settings window scrolls")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.height - scroll.contentView.bounds.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await pause()
        try PreviewSupport.saveBitmap(hosting, to: directory.appendingPathComponent("settings-native-scroll.png"))
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        window.setContentSize(NSSize(width: SettingsLayout.width, height: 720))
        try await pause()
        let pathFields = fields(in: hosting)
        guard let homeField = pathFields.first(where: { $0.accessibilityIdentifier() == "settings.path.home" }),
              let executableField = pathFields.first(where: { $0.accessibilityIdentifier() == "settings.path.executable" }) else {
            throw CheckError.failed("Codex path fields are available")
        }
        try require(pathFields.count == 2, "only Codex paths are editable")
        try require(homeField.accessibilityLabel() == L10n.text("Data directory"), "directory accessibility label")
        try require(executableField.accessibilityLabel() == L10n.text("Executable"), "executable accessibility label")
        try require(abs(homeField.frame.width - executableField.frame.width) < 1, "matching path widths")
        try require(homeField.lineBreakMode == .byTruncatingMiddle, "native middle truncation")

        let defaultFieldWidth = homeField.frame.width
        let originalRecorder = recorder(in: hosting)
        let editorBeforeResize = try focus(homeField, in: window)
        window.setContentSize(NSSize(width: 900, height: 720))
        try await pause()
        hosting.layoutSubtreeIfNeeded()
        try require(homeField.frame.width > defaultFieldWidth + 80, "wide window expands path fields")
        let cappedWidth = homeField.frame.width
        window.setContentSize(NSSize(width: 1100, height: 720))
        try await pause()
        hosting.layoutSubtreeIfNeeded()
        try require(abs(homeField.frame.width - cappedWidth) < 1, "form width remains capped")
        try require(homeField.currentEditor() === editorBeforeResize, "resizing preserves native field editor")
        window.contentMinSize = NSSize(width: 320, height: 300)
        window.setContentSize(NSSize(width: 400, height: 400))
        try await pause()
        hosting.layoutSubtreeIfNeeded()
        try require(recorder(in: hosting) === originalRecorder, "compact layout preserves recorder identity")
        try require(homeField.currentEditor() === editorBeforeResize, "compact layout preserves editing")
        try require(document.bounds.width <= scroll.contentView.bounds.width + 1, "compact form has no horizontal overflow")
        try require(homeField.frame.width > 0 && executableField.frame.width > 0, "compact paths remain editable")
        try PreviewSupport.saveBitmap(hosting, to: directory.appendingPathComponent("settings-native-compact.png"))
        window.makeFirstResponder(nil)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.height - scroll.contentView.bounds.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await pause()
        try require(abs(scroll.contentView.bounds.maxY - document.bounds.maxY) < 1,
                    "compact viewport reaches document bottom")
        try PreviewSupport.saveBitmap(hosting, to: directory.appendingPathComponent("settings-native-compact-bottom.png"))
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        window.makeFirstResponder(nil)
        SettingsWindow.prepareForDisplay(window)
        window.setContentSize(NSSize(width: SettingsLayout.width, height: 720))
        try await pause()

        guard let recorder = recorder(in: hosting) else { throw CheckError.failed("shortcut recorder exists") }
        recorder.performClick(nil)
        try await wait { shortcuts.isRecording }
        try require(!shortcuts.isRegistered, "recording suspends registration")
        sendKey(9, flags: [], in: window)
        try await pause()
        try require(shortcuts.isRecording && shortcuts.errorMessage != nil, "bare key rejected")
        sendKey(53, flags: [], in: window)
        try await wait { !shortcuts.isRecording && shortcuts.isRegistered }
        recorder.performClick(nil)
        sendKey(40, flags: [.command, .shift, .capsLock], in: window)
        try await wait { shortcuts.preferences.shortcut.keyCode == 40 }
        try require(shortcuts.preferences.shortcut.modifiers == [.command, .shift], "Caps Lock ignored")
        recorder.performClick(nil)
        window.makeFirstResponder(homeField)
        try await wait { !shortcuts.isRecording && shortcuts.isRegistered }
        recorder.performClick(nil)
        window.resignKey()
        try await wait { !shortcuts.isRecording && shortcuts.isRegistered }
        window.makeKeyAndOrderFront(nil)

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
        window.setContentSize(NSSize(width: SettingsLayout.width, height: 720))
        try require(homeField.stringValue == "invalid/relative-path", "invalid draft remains editable")
        try require(defaults.string(forKey: "codexHome") == chosen.path, "invalid draft is not persisted")
        try await pause()
        hosting.layoutSubtreeIfNeeded()
        try require(window.contentMinSize == constructionMinimum, "minimum survives validation layout")
        try PreviewSupport.saveBitmap(hosting, to: directory.appendingPathComponent("settings-native-invalid.png"))

        // Closing a retained Settings view drops its invalid draft on reopening.
        window.close()
        try await pause()
        window.makeKeyAndOrderFront(nil)
        try await wait { homeField.stringValue == chosen.path }
        try await pause()
        hosting.layoutSubtreeIfNeeded()
        try require(window.contentMinSize == constructionMinimum, "minimum survives window reopen")

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
        let checks = ["preview-build-version", "preview-newer-version", "single-page-settings", "settings-overflow-scroll", "matching-widths", "accessibility-labels", "native-middle-truncation", "focus-without-override",
                      "select-all", "copy-paste", "return-commit", "focus-loss-commit", "invalid-draft", "close-and-reopen", "tab-navigation", "restore",
                      "shortcut-recording", "shortcut-validation", "shortcut-escape", "shortcut-caps-lock", "shortcut-focus-loss", "shortcut-window-blur",
                      "window-frame-restoration", "window-frame-invalid", "window-frame-missing", "wide-path-fields", "form-width-cap",
                      "resize-preserves-editor", "compact-preserves-controls", "compact-no-horizontal-overflow", "compact-bottom-scroll",
                      "minimum-after-hosting-layout", "minimum-after-validation-layout", "minimum-after-reopen"]
        try JSONSerialization.data(withJSONObject: ["passed": checks, "currentVersion": updates.currentVersion,
            "exampleAvailableVersion": available.version,
            "minimumContentAfterLayout": [layoutMinimum.width, layoutMinimum.height],
            "minimumFrameAfterLayout": [layoutFrameMinimum.width, layoutFrameMinimum.height]], options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("settings-native-checks.json"))
        print("Passed \(checks.count) native Settings interaction checks")
    }

    private static func checkWindowRestoration() throws {
        let name = "veyra.settings.fixture.\(UUID().uuidString)"
        defer { NSWindow.removeFrame(usingName: name) }
        let original = SettingsWindow.make(hosting: NSHostingView(rootView: Color.clear), autosaveName: name)
        try require(original.contentMinSize == SettingsWindowGeometry.minimumContentSize, "normal content minimum")
        let defaultSize = original.contentRect(forFrameRect: original.frame).size
        let screen = original.screen ?? NSScreen.main
        let chrome = original.frame.height - defaultSize.height
        let expectedSize = screen.map {
            NSSize(width: min(SettingsWindowGeometry.defaultContentSize.width, $0.visibleFrame.width),
                   height: min(SettingsWindowGeometry.defaultContentSize.height, $0.visibleFrame.height - chrome))
        } ?? SettingsWindowGeometry.defaultContentSize
        try require(defaultSize == expectedSize, "missing frame uses default size bounded by screen")
        original.setContentSize(NSSize(width: 680, height: 500))
        let saved = original.frame
        original.close()
        original.setFrameAutosaveName("")
        let restored = SettingsWindow.make(hosting: NSHostingView(rootView: Color.clear), autosaveName: name)
        try require(abs(restored.frame.width - saved.width) < 1 && abs(restored.frame.height - saved.height) < 1,
                    "recreated window restores size")
        try require(abs(restored.frame.minX - saved.minX) < 1 && abs(restored.frame.minY - saved.minY) < 1,
                    "recreated window restores position")
        let before = restored.frame
        SettingsWindow.prepareForDisplay(restored)
        restored.close()
        SettingsWindow.prepareForDisplay(restored)
        try require(restored.frame == before, "reopening does not recenter")
        restored.close()
        restored.setFrameAutosaveName("")
        NSWindow.removeFrame(usingName: name)
        UserDefaults.standard.set("invalid fixture", forKey: "NSWindow Frame \(name)")
        let invalid = SettingsWindow.make(hosting: NSHostingView(rootView: Color.clear), autosaveName: name)
        defer { invalid.close(); invalid.setFrameAutosaveName("") }
        try require(SettingsWindowGeometry.isValid(invalid.frame), "invalid saved frame recovers")
        try require(invalid.contentRect(forFrameRect: invalid.frame).size == defaultSize, "invalid frame uses default size")
        if let screen = invalid.screen ?? NSScreen.main {
            try require(screen.visibleFrame.insetBy(dx: -1, dy: -1).contains(invalid.frame), "recovered frame stays visible")
        }
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }

    private static func fields(in view: NSView) -> [NSTextField] {
        if let field = view as? NSTextField,
           field.isEditable || field.accessibilityIdentifier().hasPrefix("settings.path.") { return [field] }
        return view.subviews.flatMap { fields(in: $0) }
    }

    private static func recorder(in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.accessibilityIdentifier() == "settings.shortcut.recorder" { return button }
        return view.subviews.lazy.compactMap { recorder(in: $0) }.first
    }

    private static func sendKey(_ code: UInt16, flags: NSEvent.ModifierFlags, in window: NSWindow) {
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code) {
            NSApp.sendEvent(event)
        }
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

@MainActor
private final class SettingsHotKeyFixture: HotKeyRegistering {
    private var nextID = 0
    func register(_ shortcut: GlobalShortcut, handler: @escaping @MainActor (HotKeyEvent) -> Void) throws -> Int {
        nextID += 1
        return nextID
    }
    func unregister(_ token: Int) {}
}

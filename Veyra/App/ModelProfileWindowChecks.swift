import AppKit
import SwiftUI

@MainActor
final class ModelProfileSettingsWindowDelegate: NSObject, NSWindowDelegate {
    let profiles: CodexModelProfilesStore
    init(profiles: CodexModelProfilesStore) { self.profiles = profiles }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !profiles.busy else { return false }
        profiles.cancelModelDiscovery(); profiles.cancelConnectionTest()
        if profiles.hasUnsavedChanges {
            profiles.navigate { [weak sender] in sender?.performClose(nil) }
            return false
        }
        return true
    }
}

/// Exercises native controls against in-memory fixtures. Never opens a real Codex home.
@MainActor
enum ModelProfileWindowChecks {
    private enum CheckFailure: Error { case failed(String) }

    static func run(to directory: URL) async throws {
        try await checkProviderMenu()
        let profiles = CodexModelProfilesStore.preview("preset-empty")
        let monitor = MonitorStore(); monitor.isPreview = true
        let host = NSHostingView(rootView: MonitorSettings(store: monitor, updates: .preview(.idle), profiles: profiles)
            .frame(width: 1100, height: 780).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        let delegate = ModelProfileSettingsWindowDelegate(profiles: profiles); window.delegate = delegate
        let toolbar = SettingsToolbarController(profiles: profiles, window: window)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        defer { profiles.cancelWorkspaceEdits(); window.close(); withExtendedLifetime(delegate) {}; withExtendedLifetime(toolbar) {} }
        try await wait { fields(host).contains { $0 is NSSecureTextField } && profiles.workspaceEnabled }
        let key = try require(fields(host).first { $0 is NSSecureTextField }, "secure key field")
        key.selectText(nil)
        let editor = try require(window.firstResponder as? NSTextView, "native secure editor")
        editor.insertText("native-fixture-key", replacementRange: editor.selectedRange()); window.makeFirstResponder(nil)
        try await wait { profiles.apiKeyInput == "native-fixture-key" }
        let original = profiles.snapshot
        try await click("providers.save", host: host)
        try await wait { !profiles.hasUnsavedChanges && profiles.apiKeyInput.isEmpty }
        try await wait { buttons(host).first { $0.accessibilityIdentifier() == "providers.save" }?.isEnabled == false }
        try expect(profiles.snapshot == original, "saving never changes Codex defaults")
        try await wait { !fields(host).contains { $0 is NSSecureTextField } }
        try expect(profiles.providerDraft?.model == "", "saving does not invent a default model")
        let save = try require(buttons(host).first { $0.accessibilityIdentifier() == "providers.save" }, "fixed Save action")
        let originalActionFrame = save.convert(save.bounds, to: host)
        profiles.expandedProviders.insert("deepseek")
        try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
        let expandedActionFrame = save.convert(save.bounds, to: host)
        try expect(abs(originalActionFrame.minY - expandedActionFrame.minY) < 1, "expanding advanced options does not move the Action Bar")
        profiles.expandedProviders.remove("deepseek")
        try edit("", to: "native-model", host: host, window: window)
        try await wait { profiles.providerDraft?.model == "native-model" }
        profiles.chooseWorkspace(.connection("kimi"))
        try expect(profiles.showUnsavedPrompt, "provider navigation protects the draft")
        profiles.cancelNavigation()
        try expect(profiles.providerDraft?.model == "native-model", "Cancel retains the draft")
        window.performClose(nil)
        try await wait { profiles.showUnsavedPrompt && window.attachedSheet != nil }
        try expect(window.isVisible, "dirty close is blocked")
        let cancel = try require(buttons(window.attachedSheet!.contentView!).first { $0.title == L10n.text("Cancel") }, "close Cancel")
        cancel.performClick(nil)
        try await wait { !profiles.showUnsavedPrompt }
        profiles.chooseWorkspace(.connection("kimi")); await profiles.resolveNavigation(save: false)
        try expect(profiles.providerDraft?.id == "kimi" && !profiles.hasUnsavedChanges, "Discard selects a clean provider")
        profiles.chooseWorkspace(.official)
        try expect(profiles.snapshot == original, "selecting OpenAI is read-only")
        profiles.chooseWorkspace(.create)
        profiles.providerDraft?.name = "Native custom"
        profiles.providerDraft?.baseURL = "http://127.0.0.1:11434/v1"
        profiles.providerDraft?.authentication = ModelProfileAuthentication.none
        profiles.providerDraft?.model = "local-model"
        try await click("providers.save", host: host)
        try await wait { !profiles.hasUnsavedChanges }
        try expect(profiles.customConnections.contains { $0.displayName == "Native custom" }, "new provider enters the unified sidebar")
        try await wait { buttons(host).first { $0.accessibilityIdentifier() == "providers.apply" }?.isEnabled == false }
        profiles.setAsDefault = true
        try await click("providers.apply", host: host)
        try await wait { profiles.showUnverifiedPrompt }
        profiles.showUnverifiedPrompt = false
        profiles.cancelWorkspaceEdits()
        let record: [String: Any] = ["fixtureOnly": true, "nativeTextEditing": true, "saveDoesNotApply": true,
            "keyNotRefilled": true, "dirtyCloseBlocked": true, "cancelAndDiscard": true,
            "unifiedCustomCreation": true, "officialSelectionReadOnly": true, "unverifiedApplyConfirmation": true, "defaultOptInRequired": true,
            "nativeToolbar": window.toolbar != nil, "providerMenuActions": true, "advancedKeepsActionBarFixed": true, "savedActionDisabled": true,
            "evidence": "native-control-interaction", "codexWrites": 0]
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("model-profile-native-checks.json"))
    }

    private static func checkProviderMenu() async throws {
        let profiles = CodexModelProfilesStore.preview()
        var managed = false
        let coordinator = ProviderQuickSwitchButton.Coordinator(profiles: profiles, manage: { managed = true })
        let menu = coordinator.makeMenu()
        let connections = menu.items
        try expect(connections.count == profiles.profiles.count && connections.allSatisfy { $0.representedObject != nil },
                   "the native menu contains only saved providers in their original order")
        try expect(connections.compactMap { $0.representedObject as? String } == profiles.profiles.map { $0.id.uuidString },
                   "provider ordering matches settings")
        try expect(menu.minimumWidth == 0, "provider menu width follows its content")
        try expect(connections.allSatisfy { $0.image?.size == NSSize(width: 16, height: 16) }, "native menu icons are 16 pt")
        let current = try require(connections.first { $0.state == .on }, "current provider")
        try expect(connections.filter { $0.state == .on }.count == 1 && !current.isEnabled, "only the current provider is checked and disabled")
        coordinator.selectProvider(current)
        try await Task.sleep(for: .milliseconds(20))
        try expect(profiles.message == nil, "selecting the current provider does not reapply configuration")
        let custom = try require(connections.dropFirst().first, "custom provider menu item")
        try expect(custom.isEnabled && NSApp.sendAction(custom.action!, to: custom.target, from: custom), "native provider action is wired")
        try await wait { profiles.message != nil }
        try expect(profiles.message == L10n.text("Preview only. Codex configuration was not changed."), "native provider action is isolated")
        try expect(!managed, "quick switching does not open settings for a saved draft")

        profiles.message = nil
        profiles.busy = true
        try expect(coordinator.makeMenu().items.allSatisfy { !$0.isEnabled }, "busy provider actions are disabled")
        coordinator.selectProvider(custom)
        try await Task.sleep(for: .milliseconds(20))
        try expect(profiles.message == nil, "a stale menu action cannot switch while busy")
        profiles.busy = false
        profiles.library.profiles[1].baseURL = "invalid"
        try expect(coordinator.makeMenu().items.count == 2, "invalid saved connections are omitted")
        coordinator.selectProvider(custom)
        try await Task.sleep(for: .milliseconds(20))
        try expect(profiles.message == nil, "a stale menu action cannot apply an invalid connection")

        profiles.draft = nil
        profiles.newProfile()
        try expect(profiles.hasUnsavedChanges, "new provider remains an unsaved draft")
        try expect(coordinator.makeMenu().items.count == 2, "unsaved drafts never appear in the menu")
        profiles.cancelNavigation()
        profiles.draft = nil
        profiles.library.profiles = profiles.profiles.filter { $0.validation.isEmpty }
        profiles.library.profiles.removeFirst()
        try expect(coordinator.makeMenu().items.filter { ($0.representedObject as? String) != "openai" }.allSatisfy { $0.state == .off }, "an unsaved current provider is not fabricated as a saved connection")
        try expect(profiles.defaultProviderIdentity.name == "OpenAI", "current identity is still read from configuration")
        profiles.library.profiles = []; profiles.snapshot = nil
        let empty = coordinator.makeMenu()
        try expect(empty.items.count == 1 && empty.items[0].title == L10n.text("No providers available. Add one in Settings.")
                   && !empty.items[0].isEnabled && empty.items[0].representedObject == nil, "empty menu directs users to Settings")
        var invalid = CodexModelProfile(name: "Invalid", kind: .custom)
        invalid.baseURL = "invalid"
        profiles.library.profiles = [invalid]
        try expect(coordinator.makeMenu().items.count == 1 && coordinator.makeMenu().items[0].representedObject == nil,
                   "an all-invalid library also shows the empty state")

        coordinator.profiles = .preview("error")
        try expect(coordinator.makeMenu().items.allSatisfy { !$0.isEnabled }, "unsupported configuration disables switching")
        coordinator.profiles = .preview("provider-unavailable")
        try expect(coordinator.makeMenu().items.allSatisfy { !$0.isEnabled }, "unavailable configuration disables switching")
        coordinator.profiles = .preview()
        var duplicate = coordinator.profiles.profiles[0]
        duplicate.id = UUID(); duplicate.name = "Second official"
        coordinator.profiles.library.profiles.append(duplicate)
        try expect(coordinator.makeMenu().items.allSatisfy { $0.state == .off }, "ambiguous providers are not arbitrarily checked")
        try expect(Set(coordinator.makeMenu().items.map(\.title)).count == 4, "duplicate provider identities retain unique titles")

        let dirty = CodexModelProfilesStore.preview()
        dirty.draft?.name = "Unsaved fixture"
        coordinator.profiles = dirty
        let target = try require(coordinator.makeMenu().items.dropFirst().first, "dirty draft switch target")
        coordinator.selectProvider(target)
        try expect(managed && dirty.showUnsavedPrompt && dirty.message == nil, "dirty quick switch opens Settings and waits for a decision")
        dirty.cancelNavigation()
        try await Task.sleep(for: .milliseconds(20))
        try expect(dirty.message == nil && dirty.hasUnsavedChanges, "Cancel preserves the draft and does not switch")
        coordinator.selectProvider(target)
        await dirty.resolveNavigation(save: false)
        try await wait { dirty.message != nil }
        try expect(!dirty.hasUnsavedChanges, "Discard allows the pending isolated switch")
        let button = ProviderMenuNativeButton()
        var closed = false
        button.closeMenu = { closed = true }
        button.cancelOperation(nil)
        try expect(closed, "focused native provider button forwards Escape to the popover")
    }

    static func checkQuickSwitchLayout(_ host: NSView, profiles: CodexModelProfilesStore) throws {
        let button = try require(buttons(host).first { $0.accessibilityIdentifier() == "models.quickSwitch" }, "provider button")
        try expect(abs(button.bounds.width - (PanelSizing.width - 32)) < 1 && button.bounds.height >= 32,
                   "the entire provider row is clickable")
        try expect(button.accessibilityLabel() == L10n.text("Default provider: \(profiles.defaultProviderIdentity.name)"),
                   "provider button exposes its full name")
    }

    private static func fields(_ view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? view.subviews.flatMap(fields)
    }
    private static func buttons(_ view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
    }
    private static func edit(_ current: String, to value: String, host: NSView, window: NSWindow) throws {
        let field = try require(fields(host).first { $0.stringValue == current }, "native field")
        field.selectText(nil)
        let editor = try require(window.firstResponder as? NSTextView, "native field editor")
        editor.selectAll(nil)
        editor.insertText(value, replacementRange: editor.selectedRange())
        window.makeFirstResponder(nil)
    }
    private static func click(_ identifier: String, host: NSView) async throws {
        try await wait { buttons(host).first { $0.accessibilityIdentifier() == identifier }?.isEnabled == true }
        let button = try require(buttons(host).first { $0.accessibilityIdentifier() == identifier }, identifier)
        try expect(button.isEnabled, "enabled " + identifier)
        button.performClick(nil)
    }
    private static func wait(file: StaticString = #fileID, line: UInt = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CheckFailure.failed("Timed out waiting for native model profile state at \(file):\(line)")
    }
    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw CheckFailure.failed(message) }
        return value
    }
    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailure.failed(message) }
    }
}

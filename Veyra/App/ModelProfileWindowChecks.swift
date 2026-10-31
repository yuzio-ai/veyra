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
        try await checkSettingsToolbar(to: directory)
        try await checkProviderMenu()
        let profiles = CodexModelProfilesStore.preview("preset-empty")
        let monitor = PreviewSupport.settingsStore(.automatic)
        let host = NSHostingView(rootView: MonitorSettings(store: monitor, updates: .preview(.idle), profiles: profiles)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = SettingsWindow.make(hosting: host)
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
        let advanced = try require(buttons(host).first { $0.accessibilityIdentifier() == "providers.advanced" }, "advanced disclosure header")
        advanced.scrollToVisible(advanced.bounds)
        try await Task.sleep(for: .milliseconds(100))
        let headerFrame = advanced.convert(advanced.bounds, to: host)
        try expect(headerFrame.width > 400 && headerFrame.height >= 28, "advanced header fills the form row")
        for offset in [CGFloat(5), 50, headerFrame.width - 5] {
            let point = advanced.convert(NSPoint(x: offset, y: advanced.bounds.midY), to: host.superview)
            let hit = host.hitTest(point)
            try expect(hit === advanced || hit?.isDescendant(of: advanced) == true,
                       "arrow, title and trailing space hit the same advanced control")
        }
        advanced.performClick(nil)
        try await wait { profiles.expandedProviders.contains("deepseek") }
        try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
        let expandedActionFrame = save.convert(save.bounds, to: host)
        try expect(abs(originalActionFrame.minY - expandedActionFrame.minY) < 1, "expanding advanced options does not move the Action Bar")
        let expanded = try require(buttons(host).first { $0.accessibilityIdentifier() == "providers.advanced" }, "expanded disclosure header")
        expanded.performClick(nil)
        try await wait { !profiles.expandedProviders.contains("deepseek") }
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
        try await wait { buttons(host).first { $0.accessibilityIdentifier() == "providers.apply" }?.title == L10n.text("Save and set as default") }
        try await click("providers.save", host: host)
        try await wait { !profiles.hasUnsavedChanges }
        try expect(profiles.customConnections.contains { $0.displayName == "Native custom" }, "new provider enters the unified sidebar")
        try expect(profiles.snapshot == original, "saving a custom provider does not set it as default")
        try await wait { buttons(host).first { $0.accessibilityIdentifier() == "providers.apply" }?.title == L10n.text("Set as default") }
        try await click("providers.apply", host: host)
        try await wait { profiles.showUnverifiedPrompt }
        profiles.showUnverifiedPrompt = false
        profiles.providerDraft?.model = "next-local-model"
        try await wait { buttons(host).first { $0.accessibilityIdentifier() == "providers.apply" }?.title == L10n.text("Save and set as default") }
        try await click("providers.apply", host: host)
        try await wait { profiles.showUnverifiedPrompt && !profiles.hasUnsavedChanges }
        try expect(profiles.savedConnection?.model == "next-local-model" && profiles.snapshot == original,
                   "the direct default action saves edits and still requires unverified-provider confirmation")
        profiles.showUnverifiedPrompt = false
        let saved = try require(profiles.savedConnection, "saved custom provider")
        let profile = try saved.profile(helper: Bundle.main.executableURL!)
        let user: JSONValue = .object(["model": .string(profile.model), "model_provider": .string(profile.providerID),
                                       "model_providers": .object([profile.providerID: profile.provider])])
        profiles.snapshot = CodexConfigSnapshot(user: user, version: "fixture", file: original!.file)
        try await wait { buttons(host).first { $0.accessibilityIdentifier() == "providers.apply" }?.title == L10n.text("Apply") }
        profiles.providerDraft?.model = "updated-default-model"
        try await wait { buttons(host).first { $0.accessibilityIdentifier() == "providers.apply" }?.title == L10n.text("Save and apply") }
        profiles.busy = true
        try await wait { buttons(host).first { $0.accessibilityIdentifier() == "providers.apply" }?.isEnabled == false }
        profiles.busy = false
        profiles.cancelWorkspaceEdits()
        profiles.providerDraft?.wireAPI = "chat"
        try expect(await profiles.saveWorkspace(), "save the isolated unsupported-protocol fixture")
        try await wait { buttons(host).first { $0.accessibilityIdentifier() == "providers.apply" }?.isEnabled == false }
        try await click("providers.useResponses", host: host)
        try await wait { profiles.providerDraft?.protocolName == "responses" && profiles.hasUnsavedChanges }
        try expect(profiles.savedConnection?.protocolName == "chat" && profiles.providerDraft?.id == saved.id,
                   "protocol correction edits the same connection without saving automatically")
        profiles.cancelWorkspaceEdits()
        try await wait { profiles.providerDraft?.protocolName == "chat" && !profiles.hasUnsavedChanges }
        let record: [String: Any] = ["fixtureOnly": true, "nativeTextEditing": true, "saveDoesNotApply": true,
            "keyNotRefilled": true, "dirtyCloseBlocked": true, "cancelAndDiscard": true,
            "unifiedCustomCreation": true, "officialSelectionReadOnly": true, "unverifiedApplyConfirmation": true,
            "directDefaultAction": true, "defaultActionSavesEdits": true, "currentDefaultActionLabels": true, "busyDefaultActionDisabled": true,
            "unsupportedProtocolRecovery": true, "protocolRecoveryCanCancel": true,
            "nativeToolbar": window.toolbar != nil, "providerMenuActions": true, "advancedHeaderClickable": true,
            "advancedKeepsActionBarFixed": true, "savedActionDisabled": true,
            "evidence": "native-control-interaction", "codexWrites": 0]
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("model-profile-native-checks.json"))
    }

    private static func checkSettingsToolbar(to directory: URL) async throws {
        let profiles = CodexModelProfilesStore.preview("workspace-local")
        let monitor = PreviewSupport.settingsStore(.automatic)
        let host = NSHostingView(rootView: MonitorSettings(store: monitor, updates: .preview(.idle), profiles: profiles))
        let window = SettingsWindow.make(hosting: host)
        let controller = SettingsToolbarController(profiles: profiles, window: window)
        window.makeKeyAndOrderFront(nil)
        defer { profiles.cancelNavigation(); profiles.cancelWorkspaceEdits(); window.close(); withExtendedLifetime(controller) {} }
        let toolbar = try require(window.toolbar, "settings toolbar")
        let general = try require(toolbar.items.first { $0.itemIdentifier.rawValue == "veyra.settings.general" }, "General toolbar item")
        let models = try require(toolbar.items.first { $0.itemIdentifier.rawValue == "veyra.settings.models" }, "Models toolbar item")
        try expect(toolbar.items.count == 2 && general.view == nil && models.view == nil,
                   "settings uses two native image items without hosted controls")
        try expect(general.image != nil && models.image != nil && general.label == L10n.text("General") && models.label == L10n.text("Models"),
                   "native items retain localized labels and SF Symbols")
        try expect(toolbar.displayMode == .iconAndLabel && window.toolbarStyle == .expanded && !toolbar.allowsUserCustomization,
                   "native settings toolbar displays icons above labels")
        try expect(window.titleVisibility == .visible && window.styleMask.contains([.resizable, .miniaturizable]),
                   "settings retains a separate titlebar and enabled window controls")
        try expect(host.sizingOptions == [.minSize] && window.contentMaxSize.width > 1400 && window.contentMaxSize.height > 1000,
                   "hosting content does not impose a fixed maximum window size")
        if #available(macOS 15.0, *) { try expect(!toolbar.allowsDisplayModeCustomization, "toolbar display mode stays icon and label") }
        try expect(toolbar.centeredItemIdentifiers == [general.itemIdentifier, models.itemIdentifier], "both categories are centered")
        try await wait { profiles.workspaceEnabled && toolbar.selectedItemIdentifier == models.itemIdentifier }
        let windowFrame = try require(host.superview, "native settings frame")
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let button = try require(window.standardWindowButton(type), "native window control")
            let bounds = button.convert(button.bounds, to: windowFrame)
            try expect(button.isEnabled && windowFrame.bounds.maxY - bounds.midY < 32,
                       "traffic lights remain in the top titlebar row")
        }

        // Dispatch the native target/action and model AppKit's eager selection before it.
        func select(_ item: NSToolbarItem) throws {
            toolbar.selectedItemIdentifier = item.itemIdentifier
            try expect(NSApp.sendAction(try require(item.action, "toolbar action"), to: item.target, from: item), "native toolbar action dispatch")
        }
        try select(general)
        try expect(profiles.tab == .general && toolbar.selectedItemIdentifier == general.itemIdentifier, "Models to General")
        try select(models)
        try expect(profiles.tab == .models && toolbar.selectedItemIdentifier == models.itemIdentifier, "General to Models")
        profiles.tab = .general
        try await wait { toolbar.selectedItemIdentifier == general.itemIdentifier }
        window.orderOut(nil); profiles.tab = .models
        try await wait { toolbar.selectedItemIdentifier == models.itemIdentifier }
        window.makeKeyAndOrderFront(nil)

        profiles.busy = true
        try await wait { !general.isEnabled && !models.isEnabled }
        try select(general)
        try expect(profiles.tab == .models && toolbar.selectedItemIdentifier == models.itemIdentifier, "busy navigation is blocked")
        profiles.busy = false
        try await wait { general.isEnabled && models.isEnabled }

        profiles.providerDraft?.model = "toolbar-unsaved"
        try select(models)
        try expect(!profiles.showUnsavedPrompt, "clicking current category preserves the draft without prompting")
        try select(general)
        try await wait { profiles.showUnsavedPrompt && window.attachedSheet != nil }
        try expect(profiles.tab == .models && toolbar.selectedItemIdentifier == models.itemIdentifier, "dirty navigation retains actual selection")
        try await wait { !general.isEnabled && !models.isEnabled }
        try select(models)
        try expect(profiles.showUnsavedPrompt, "repeated actions do not replace pending navigation")
        let cancel = try require(buttons(window.attachedSheet!.contentView!).first { $0.title == L10n.text("Cancel") }, "toolbar Cancel")
        cancel.performClick(nil)
        try await wait { !profiles.showUnsavedPrompt && window.attachedSheet == nil && general.isEnabled }
        try expect(profiles.tab == .models && profiles.providerDraft?.model == "toolbar-unsaved", "Cancel retains page and draft")

        try select(general)
        try await wait { window.attachedSheet != nil }
        let discard = try require(buttons(window.attachedSheet!.contentView!).first { $0.title == L10n.text("Discard changes") }, "toolbar Discard")
        discard.performClick(nil)
        try await wait { profiles.tab == .general && toolbar.selectedItemIdentifier == general.itemIdentifier && window.attachedSheet == nil }
        try expect(!profiles.hasUnsavedChanges, "Discard completes the original pending switch")

        try select(models)
        profiles.providerDraft?.model = "toolbar-saved"
        try select(general)
        try await wait { window.attachedSheet != nil }
        let save = try require(buttons(window.attachedSheet!.contentView!).first { $0.title == L10n.text("Save") }, "toolbar Save")
        save.performClick(nil)
        try await wait { profiles.tab == .general && toolbar.selectedItemIdentifier == general.itemIdentifier && window.attachedSheet == nil && general.isEnabled }
        try expect(profiles.savedConnection?.model == "toolbar-saved" && !profiles.hasUnsavedChanges, "Save completes navigation after saving")

        try select(models)
        profiles.providerDraft?.baseURL = "invalid"
        try select(general)
        try await wait { window.attachedSheet != nil }
        let failedSave = try require(buttons(window.attachedSheet!.contentView!).first { $0.title == L10n.text("Save") }, "toolbar invalid Save")
        failedSave.performClick(nil)
        try await wait { !profiles.showUnsavedPrompt && window.attachedSheet == nil && general.isEnabled }
        try expect(profiles.tab == .models && toolbar.selectedItemIdentifier == models.itemIdentifier && profiles.hasUnsavedChanges,
                   "failed Save retains actual page, selection, and editable draft")
        profiles.cancelWorkspaceEdits()

        for tab in [VeyraSettingsTab.models, .general] {
            profiles.tab = tab
            for size in [NSSize(width: 1280, height: 900), NSSize(width: 950, height: 650)] {
                window.setContentSize(size)
                try await Task.sleep(for: .milliseconds(100))
                host.layoutSubtreeIfNeeded()
                try expect(abs(host.bounds.width - size.width) < 1 && abs(host.bounds.height - size.height) < 1,
                           "both settings pages grow and shrink with the window")
                try expect(window.contentMaxSize.width > 1400 && window.contentMaxSize.height > 1000,
                           "tab switches do not reintroduce a fixed maximum")
            }
        }

        // Exercise the production minimum outer window size, including the taller toolbar.
        window.setFrame(NSRect(x: window.frame.minX, y: window.frame.minY, width: 900, height: 630), display: true)
        try select(general)
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        try expect(window.frame.width >= 900 && window.frame.height >= 630 && window.contentLayoutRect.height >= 600,
                   "native minimum window preserves the settings content minimum")
        let frame = try require(host.superview, "native window frame")
        try PreviewSupport.saveBitmap(frame, to: directory.appendingPathComponent("settings-toolbar-minimum-general.png"))
        try select(models)
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        try PreviewSupport.saveBitmap(frame, to: directory.appendingPathComponent("settings-toolbar-minimum-models.png"))
        let record: [String: Any] = ["fixtureOnly": true, "nativeItems": true, "iconAndLabel": true, "centered": true,
            "trafficLightsInTitlebar": true, "flexibleWindowBounds": true, "bothPagesResize": true,
            "bidirectionalNavigation": true, "externalSelectionAndReopen": true, "busyBlocked": true,
            "sameTabNoPrompt": true, "cancelAndDiscard": true, "saveBeforeSwitch": true, "failedSaveKeepsSelection": true,
            "evidence": "native-target-action-and-window-view-bitmap", "codexWrites": 0,
            "requestedMinimumWidth": 900, "requestedMinimumHeight": 630,
            "minimumWindowWidth": window.frame.width, "minimumWindowHeight": window.frame.height]
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("settings-toolbar-native-checks.json"))
    }

    private static func checkProviderMenu() async throws {
        for failure in [ProviderConnectionFailure.authentication, .incompatible] {
            for mode in ["legacy", "preset", "custom"] {
                let blocked = CodexModelProfilesStore.preview(mode == "preset" ? "preset-configured" : "normal")
                var managed = false
                let coordinator = ProviderQuickSwitchButton.Coordinator(profiles: blocked, manage: { managed = true })
                let id: String
                let represented: String
                if mode == "custom" {
                    var settings = ProviderSettings(name: "Fixture local")
                    settings.baseURL = "http://localhost:11434/v1"; settings.model = "fixture-model"; settings.authentication = ModelProfileAuthentication.none
                    blocked.library.connections.append(settings)
                    id = settings.id; represented = "connection:" + id
                } else {
                    id = mode == "preset" ? "deepseek" : blocked.providerDraft!.id
                    represented = mode == "preset" ? "preset:" + id : blocked.providerDraft!.legacyProfile!.id.uuidString
                }
                let stale = try require(coordinator.makeMenu().items.first { ($0.representedObject as? String) == represented }, "switch target before failure")
                let index = blocked.library.connections.firstIndex { $0.id == id }!
                let settings = blocked.library.connections[index]
                blocked.library.connections[index].connectivity = ProviderConnectivityResult(scope: ProviderModelScope(settings)!,
                    model: settings.model, protocolName: settings.protocolName, date: Date(), failure: failure)
                try expect(!coordinator.makeMenu().items.contains { ($0.representedObject as? String) == represented }, "known connection failures are omitted from the native menu")
                if mode == "preset" { coordinator.selectPreset(stale) }
                else if mode == "custom" { coordinator.selectConnection(stale) }
                else { coordinator.selectProvider(stale) }
                try await Task.sleep(for: .milliseconds(20))
                try expect(blocked.message == nil && !managed, "a stale native menu action cannot bypass connection validation")
            }
        }
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
        for mark in ProviderMark.allCases {
            let identity = CodexProviderIdentity(name: mark.rawValue, isOfficial: mark == .openAI)
            let image = ProviderIcon.menuImage(for: identity)
            try expect(image.size == NSSize(width: 16, height: 16) && image.isTemplate == mark.isTemplate
                       && image.representations.contains { $0.pixelsWide >= 32 && $0.pixelsHigh >= 32 },
                       "known provider menus use their bundled Logo and preserve template/color rendering")
        }
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

        profiles.chooseWorkspace(.create)
        profiles.providerDraft?.name = "Unsaved provider"
        try expect(profiles.hasUnsavedChanges, "new provider remains an unsaved draft")
        try expect(coordinator.makeMenu().items.count == 2, "unsaved drafts never appear in the menu")
        profiles.cancelNavigation()
        profiles.cancelWorkspaceEdits()
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
        dirty.providerDraft?.name = "Unsaved fixture"
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
        let button = try require(buttons(host).first { $0.accessibilityIdentifier() == "models.quickSwitch" } as? ProviderMenuNativeButton, "provider button")
        let frame = button.convert(button.bounds, to: host)
        try expect(frame.minX >= 100 && abs(frame.maxX - (host.bounds.width - 16)) < 1
                   && frame.width >= 120 && frame.height >= 32,
                   "provider switch occupies the right side of the context row")
        if profiles.defaultProviderIdentity.isOfficial && !profiles.busy {
            try expect(frame.width < 200, "short provider names do not stretch across the context row")
        }
        let menu = ProviderQuickSwitchButton.Coordinator(profiles: profiles, manage: {}).makeMenu()
        let origin = button.popupOrigin(for: menu)
        try expect(abs(origin.x + menu.size.width - button.bounds.maxX) < 1,
                   "provider menu aligns with the right edge of its compact control")
        let window = try require(button.window, "provider window")
        let screenOrigin = window.convertPoint(toScreen: button.convert(origin, to: nil))
        let screenFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        try expect(abs(screenOrigin.y - (screenFrame.minY - 4)) < 1,
                   "provider menu opens below its control in native screen coordinates")
        let parent = try require(host.superview, "provider host parent")
        for x in [frame.minX + 2, frame.maxX - 2] {
            let hit = host.hitTest(host.convert(NSPoint(x: x, y: frame.midY), to: parent))
            try expect(hit === button || hit?.isDescendant(of: button) == true,
                       "the full provider control remains clickable")
        }
        let activityHit = host.hitTest(host.convert(NSPoint(x: 32, y: frame.midY), to: parent))
        try expect(activityHit !== button && activityHit?.isDescendant(of: button) != true,
                   "local activity does not activate the provider menu")
        try expect(button.accessibilityLabel() == L10n.text("Current provider: \(profiles.defaultProviderIdentity.name)"),
                   "provider button exposes its full name")
        try expect(button.toolTip?.contains(profiles.defaultProviderIdentity.name) == true,
                   "provider tooltip retains the full configuration name")
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

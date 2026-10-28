import SwiftUI
import AppKit

/// Native actions preserve keyboard equivalents when settings are hosted in an AppKit window.
struct ModelProfileActionButton: NSViewRepresentable {
    enum Style { case rounded, inline }

    var title: String
    var identifier: String
    var key: String
    var enabled: Bool
    var primary = false
    var style: Style = .rounded
    var action: @MainActor () -> Void

    @MainActor final class Coordinator: NSObject {
        var action: @MainActor () -> Void
        init(action: @escaping @MainActor () -> Void) { self.action = action }
        @objc func invoke() { action() }
    }
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.invoke))
        button.bezelStyle = style == .inline ? .inline : .rounded
        button.isBordered = style == .rounded
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setAccessibilityIdentifier(identifier)
        button.keyEquivalent = key
        button.keyEquivalentModifierMask = key == "\r" ? [] : .command
        if style == .inline { button.contentTintColor = .controlAccentColor }
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.title = title
        button.isEnabled = enabled
        button.bezelColor = primary ? .controlAccentColor : nil
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? { nsView.fittingSize }
}

struct ModelProfilesNotice: View {
    var profiles: CodexModelProfilesStore
    var showUndo = true
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let error = profiles.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            if let message = profiles.message { Label(message, systemImage: "checkmark.circle") }
            if profiles.snapshot?.overridden == true {
                Label("A higher-priority policy overrides this user configuration.", systemImage: "info.circle")
            }
            if showUndo, profiles.canUndo {
                Button("Undo last switch") { Task { await profiles.undo() } }
                    .buttonStyle(.link).accessibilityIdentifier("models.undo")
            }
        }.font(.caption).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
    }
}

struct ModelProfileQuickSwitch: View {
    @Bindable var profiles: CodexModelProfilesStore
    var manage: () -> Void
    var closeMenu: () -> Void = {}
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            menu
            if profiles.error != nil || profiles.message != nil || profiles.snapshot?.overridden == true {
                ModelProfilesNotice(profiles: profiles, showUndo: false)
            }
        }
    }

    private var menu: some View {
        HStack(spacing: 8) {
            Text("Default provider").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
            Spacer(minLength: 8)
            ProviderIcon(identity: profiles.defaultProviderIdentity, size: 20)
            Text(profiles.defaultProviderIdentity.name)
                .font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.tail)
            if profiles.busy { ProgressView().controlSize(.mini) }
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 32)
        .contentShape(Rectangle())
        .accessibilityHidden(true)
        .overlay { ProviderQuickSwitchButton(profiles: profiles, manage: manage, closeMenu: closeMenu) }
    }
}

/// Keep the label in SwiftUI: AppKit's standard Menu style flattens complex labels.
/// A transparent native button supplies keyboard focus and anchors the native menu.
struct ProviderQuickSwitchButton: NSViewRepresentable {
    var profiles: CodexModelProfilesStore
    var manage: () -> Void
    var closeMenu: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(profiles: profiles, manage: manage) }
    func makeNSView(context: Context) -> ProviderMenuNativeButton {
        let button = ProviderMenuNativeButton(title: "", target: context.coordinator, action: #selector(Coordinator.openMenu(_:)))
        button.isBordered = false
        button.isTransparent = true
        button.focusRingType = .exterior
        button.setAccessibilityIdentifier("models.quickSwitch")
        button.setAccessibilityRole(.popUpButton)
        return button
    }
    func updateNSView(_ button: ProviderMenuNativeButton, context: Context) {
        context.coordinator.profiles = profiles
        context.coordinator.manage = manage
        button.closeMenu = closeMenu
        button.toolTip = profiles.defaultProviderIdentity.name
        button.setAccessibilityLabel(L10n.text("Default provider: \(profiles.defaultProviderIdentity.name)"))
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ProviderMenuNativeButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? PanelSizing.width - 32, height: proposal.height ?? 32)
    }

    @MainActor
    final class Coordinator: NSObject {
        var profiles: CodexModelProfilesStore
        var manage: () -> Void
        init(profiles: CodexModelProfilesStore, manage: @escaping () -> Void) {
            self.profiles = profiles; self.manage = manage
        }
        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            for profile in profiles.profiles where profile.validation.isEmpty && (profile.kind != .custom || profile.authentication != .environment) {
                let item = NSMenuItem(title: profiles.providerTitle(profile), action: #selector(selectProvider(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = profile.id.uuidString
                item.image = ProviderIcon.menuImage(for: profile.providerIdentity)
                item.state = profiles.currentProviderProfileID == profile.id ? .on : .off
                item.isEnabled = !profiles.busy && profiles.writesSupported && profiles.currentProviderProfileID != profile.id
                menu.addItem(item)
            }
            for preset in profiles.switchablePresets {
                let item = NSMenuItem(title: preset.name, action: #selector(selectPreset(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = "preset:" + preset.id
                item.image = ProviderIcon.menuImage(for: CodexProviderIdentity(name: preset.name))
                item.state = profiles.currentPresetID == preset.id ? .on : .off
                item.isEnabled = !profiles.busy && profiles.writesSupported && profiles.credentialCommandsSupported && profiles.currentPresetID != preset.id
                menu.addItem(item)
            }
            for connection in profiles.customConnections where connection.legacyProfile == nil && connection.validation.isEmpty && !connection.model.isEmpty {
                let item = NSMenuItem(title: connection.displayName, action: #selector(selectConnection(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = "connection:" + connection.id
                item.image = ProviderIcon.menuImage(for: CodexProviderIdentity(name: connection.displayName))
                item.state = profiles.isDefaultConnection(connection) ? .on : .off
                item.isEnabled = !profiles.busy && profiles.writesSupported && !profiles.isDefaultConnection(connection)
                    && (connection.authMode != .keychain || profiles.providerKeyAvailable[connection.id] == true)
                menu.addItem(item)
            }
            if !profiles.profiles.contains(where: { $0.kind == .official }), profiles.snapshot != nil {
                let official = NSMenuItem(title: "OpenAI", action: #selector(selectOfficial), keyEquivalent: "")
                official.target = self; official.representedObject = "openai"
                official.image = ProviderIcon.menuImage(for: CodexProviderIdentity(name: "OpenAI", isOfficial: true))
                official.state = profiles.defaultProviderIdentity.isOfficial ? .on : .off
                official.isEnabled = !profiles.busy && profiles.writesSupported && !profiles.defaultProviderIdentity.isOfficial
                menu.addItem(official)
            }
            if menu.items.isEmpty {
                menu.addItem(withTitle: L10n.text("No providers available. Add one in Settings."),
                             action: nil, keyEquivalent: "").isEnabled = false
            }
            return menu
        }
        @objc func openMenu(_ button: NSButton) {
            let menu = makeMenu()
            menu.popUp(positioning: nil,
                       at: NSPoint(x: 0, y: button.isFlipped ? button.bounds.maxY + 4 : button.bounds.minY - 4), in: button)
        }
        @objc func selectPreset(_ item: NSMenuItem) {
            guard let value = item.representedObject as? String, value.hasPrefix("preset:"), !profiles.busy,
                  profiles.writesSupported, profiles.credentialCommandsSupported else { return }
            let id = String(value.dropFirst(7))
            guard profiles.currentPresetID != id, profiles.switchablePresets.contains(where: { $0.id == id }) else { return }
            if profiles.hasUnsavedChanges { manage() }
            profiles.navigate { Task { await self.profiles.applyPreset(id) } }
        }
        @objc func selectConnection(_ item: NSMenuItem) {
            guard let value = item.representedObject as? String, value.hasPrefix("connection:"), !profiles.busy else { return }
            let id = String(value.dropFirst(11))
            guard profiles.customConnections.contains(where: { $0.id == id }) else { return }
            manage()
            profiles.navigate {
                self.profiles.workspaceEnabled = true; self.profiles.chooseConnectionForAction(id)
                Task { await self.profiles.requestWorkspaceApply() }
            }
        }
        @objc func selectOfficial() {
            guard !profiles.busy, profiles.writesSupported, !profiles.defaultProviderIdentity.isOfficial else { return }
            if profiles.hasUnsavedChanges { manage() }
            profiles.navigate { Task { await self.profiles.restoreOpenAI() } }
        }
        @objc func selectProvider(_ item: NSMenuItem) {
            guard !profiles.busy, profiles.writesSupported,
                  let value = item.representedObject as? String, let id = UUID(uuidString: value),
                  let profile = profiles.profiles.first(where: { $0.id == id }),
                  profile.validation.isEmpty, profiles.currentProviderProfileID != id else { return }
            if profiles.hasUnsavedChanges { manage() }
            profiles.navigate { Task { await self.profiles.apply(profile) } }
        }
    }
}

final class ProviderMenuNativeButton: NSButton {
    var closeMenu: () -> Void = {}
    override var acceptsFirstResponder: Bool { true }
    override func cancelOperation(_ sender: Any?) { closeMenu() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { closeMenu() }
        else { super.keyDown(with: event) }
    }
}

import AppKit
import SwiftUI

struct CodexModelProfilesView: View {
    @Bindable var profiles: CodexModelProfilesStore
    var body: some View { ProviderSettingsView(profiles: profiles) }
}

struct ProviderSettingsView: View {
    @Bindable var profiles: CodexModelProfilesStore
    @State private var deleting: ProviderSettings?

    var body: some View {
        HStack(spacing: 0) {
            ProviderSidebarView(profiles: profiles, deleting: $deleting)
            Divider()
            if let settings = profiles.providerDraft {
                ProviderDetailView(profiles: profiles, settings: settings).id(settings.id + String(profiles.editorRevision))
            } else {
                ContentUnavailableView("Select a provider", systemImage: "network")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { profiles.activateWorkspace() }
        .onDisappear { profiles.cancelModelDiscovery(); profiles.cancelConnectionTest() }
        .confirmationDialog("Responses compatibility has not been verified", isPresented: $profiles.showUnverifiedPrompt, titleVisibility: .visible) {
            Button("Apply to new sessions") { Task { await profiles.applyWorkspace() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This provider has not passed a Responses model test. Applying does not test the model or switch existing sessions.")
        }
        .sheet(item: $deleting) { value in ProviderDeletionSheet(profiles: profiles, settings: value) }
    }
}

struct ProviderSidebarView: View {
    @Bindable var profiles: CodexModelProfilesStore
    @Binding var deleting: ProviderSettings?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Built-in providers").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(10)
                    row(name: L10n.text("OpenAI (official)"), identity: .init(name: "OpenAI", isOfficial: true),
                        selection: .official, isDefault: profiles.defaultProviderIdentity.isOfficial)
                    ForEach(ProviderPreset.all) { preset in
                        row(name: preset.name, identity: .init(name: preset.name), selection: .connection(preset.id),
                            isDefault: profiles.snapshot?.configuredProviderID == "veyra_preset_" + preset.id)
                    }
                    Divider().padding(.vertical, 16)
                    Text("Custom providers").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 10)
                    ForEach(profiles.customConnections) { settings in
                        row(name: settings.displayName, identity: settings.legacyValue?.providerIdentity ?? .init(name: settings.displayName),
                            selection: .connection(settings.id), isDefault: profiles.isDefaultConnection(settings), symbol: settings.symbol)
                            .contextMenu {
                                Button("Rename") { profiles.chooseWorkspace(.connection(settings.id)); profiles.renameRequested = settings.id }
                                Button("Duplicate provider") {
                                    profiles.navigate { profiles.chooseConnectionForAction(settings.id); profiles.duplicateWorkspace() }
                                }
                                Button("Delete provider", role: .destructive) { profiles.navigate { deleting = settings } }
                            }
                    }
                    Button { profiles.chooseWorkspace(.create) } label: {
                        Label("Add provider", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }
                    .buttonStyle(.plain)
                    .background(profiles.workspaceSelection == .create ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("providers.add")
                }.padding(12)
            }
        }
        .frame(width: 248)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
        .disabled(profiles.busy)
    }
    private func row(name: String, identity: CodexProviderIdentity, selection: ProviderWorkspaceSelection,
                     isDefault: Bool, symbol: String? = nil) -> some View {
        Button { profiles.chooseWorkspace(selection) } label: {
            HStack(spacing: 12) {
                if let symbol { Image(systemName: symbol).font(.title3).frame(width: 24) }
                else { ProviderIcon(identity: identity, size: 24) }
                Text(name).lineLimit(1).help(name)
                Spacer(minLength: 0)
                if isDefault { Image(systemName: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor).accessibilityLabel("Default for new sessions") }
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            .background(profiles.workspaceSelection == selection ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(selection == .official ? "providers.openai" : "providers.select.\(name)")
        .accessibilityAddTraits(profiles.workspaceSelection == selection ? .isSelected : [])
    }
}

struct ProviderDetailView: View {
    @Bindable var profiles: CodexModelProfilesStore
    var settings: ProviderSettings
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    header
                    if profiles.workspaceIssue != nil || profiles.configurationReloadError != nil || profiles.error != nil || profiles.message != nil || profiles.snapshot?.overridden == true {
                        ProviderStatusBanner(profiles: profiles)
                    }
                    if settings.origin == .custom { ProviderEditorView(profiles: profiles) }
                    ProviderCredentialSection(profiles: profiles, settings: settings)
                    Divider()
                    ProviderModelSection(profiles: profiles, settings: settings)
                    Divider()
                    ProviderAdvancedSection(profiles: profiles, settings: settings)
                    if profiles.attemptedValidation {
                        ForEach(profiles.workspaceErrors.keys.sorted(), id: \.self) { key in
                            Text(profiles.workspaceErrors[key] ?? "").font(.caption).foregroundStyle(.red)
                        }
                    }
                }
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 36).padding(.vertical, 30)
                .frame(maxWidth: 792, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            Divider()
            ProviderActionBar(profiles: profiles, settings: settings)
        }
        .disabled(profiles.busy)
    }
    private var header: some View {
        HStack(spacing: 14) {
            if let symbol = settings.symbol { Image(systemName: symbol).font(.system(size: 30)).frame(width: 36) }
            else { ProviderIcon(identity: settings.id == "openai" ? .init(name: "OpenAI", isOfficial: true) : .init(name: settings.displayName), size: 36) }
            VStack(alignment: .leading, spacing: 5) {
                Text(profiles.workspaceSelection == .create ? L10n.text("Add custom provider") : settings.displayName)
                    .font(.system(size: 22, weight: .semibold)).textSelection(.enabled)
                Text(configurationLabel).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if profiles.isDefaultConnection(settings) { Text("Default for new sessions").font(.caption).foregroundStyle(Color.accentColor) }
        }
    }
    private var configurationLabel: String {
        if settings.id == "openai" { return L10n.text("Uses existing Codex sign-in") }
        return switch profiles.configurationStatus(settings) {
        case .configured: L10n.text("Configured")
        case .unconfigured: L10n.text("Not configured")
        case .invalid: L10n.text("Configuration needs attention")
        }
    }
}

struct ProviderEditorView: View {
    @Bindable var profiles: CodexModelProfilesStore
    @FocusState private var nameFocused: Bool
    private var value: Binding<ProviderSettings> { Binding(get: { profiles.providerDraft! }, set: { profiles.providerDraft = $0 }) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Basic information").font(.headline)
            ProviderFormRow("Name") {
                TextField("Provider name", text: Binding(get: { value.wrappedValue.displayName }, set: { value.wrappedValue.name = $0 }))
                    .focused($nameFocused).accessibilityIdentifier("providers.name")
            }
            ProviderFormRow("Icon") {
                Picker("Icon", selection: Binding(get: { value.wrappedValue.symbol ?? "network" }, set: { value.wrappedValue.symbol = $0 })) {
                    ForEach(["network", "server.rack", "cloud", "cpu", "sparkles", "building.2", "shippingbox"], id: \.self) { symbol in
                        Image(systemName: symbol).tag(symbol)
                    }
                }.labelsHidden()
            }
            if value.wrappedValue.isManagedEndpoint {
                ProviderFormRow("Protocol") {
                    if value.wrappedValue.protocolName == "responses" { Text("Responses API") }
                    else { Text("Unsupported protocol").foregroundStyle(.orange) }
                }
                if value.wrappedValue.protocolName != "responses" {
                    Text("Codex requires Responses. Chat Completions compatibility is insufficient.").font(.caption).foregroundStyle(.orange)
                    ModelProfileActionButton(title: L10n.text("Use Responses API"), identifier: "providers.useResponses", key: "", enabled: !profiles.busy, style: .inline) {
                        profiles.useResponsesProtocol()
                    }
                }
                ProviderFormRow("Base URL") {
                    TextField("https://api.example.com/v1", text: value.baseURL)
                        .accessibilityIdentifier("providers.baseURL")
                }
                Text("The address is used as entered. Veyra does not append /v1.").font(.caption).foregroundStyle(.secondary)
                ProviderFormRow("Authentication") {
                    Picker("Authentication", selection: Binding(get: { value.wrappedValue.authMode }, set: { value.wrappedValue.authentication = $0 })) {
                        Text("API Key in Keychain").tag(ModelProfileAuthentication.keychain)
                        Text("No authentication").tag(ModelProfileAuthentication.none)
                        if value.wrappedValue.authMode == .environment { Text("Existing environment variable").tag(ModelProfileAuthentication.environment) }
                    }.labelsHidden()
                }
            } else {
                Text("This connection uses Codex's existing provider and authentication. Unknown settings remain managed by Codex.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { if profiles.renameRequested == profiles.providerDraft?.id { nameFocused = true; profiles.renameRequested = nil } }
        .onChange(of: profiles.renameRequested) { _, id in if id == profiles.providerDraft?.id { nameFocused = true; profiles.renameRequested = nil } }
    }
}

struct ProviderCredentialSection: View {
    @Bindable var profiles: CodexModelProfilesStore
    var settings: ProviderSettings
    @State private var removing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(settings.isManagedEndpoint ? L10n.text("API Key") : L10n.text("Authentication")).font(.headline)
            if !settings.isManagedEndpoint {
                Text("Uses Codex's existing sign-in. Veyra does not sign in or store credentials.").font(.callout).foregroundStyle(.secondary)
            } else if settings.authMode == .none {
                Label("This service does not require an API Key.", systemImage: "network").foregroundStyle(.secondary)
            } else if settings.authMode == .environment {
                Text("Authentication is supplied externally through the existing environment variable. Veyra does not read or export it.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if profiles.providerKeyAvailable[settings.id] == true && !profiles.replacingKey {
                HStack(spacing: 12) {
                    Image(systemName: "lock.shield.fill").font(.title2).foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Key saved").font(.body.weight(.medium))
                        Text("Stored securely in this Mac's Keychain").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Replace Key") { profiles.replacingKey = true; profiles.cancelModelDiscovery(); profiles.cancelConnectionTest() }
                    Menu { Button("Remove API Key", role: .destructive) { removing = true } } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).fixedSize()
                }
            } else {
                HStack {
                    SecureField("Enter API Key", text: $profiles.apiKeyInput).accessibilityIdentifier("providers.key")
                    if profiles.replacingKey { Button("Cancel") { profiles.apiKeyInput = ""; profiles.replacingKey = false } }
                }
                Text("Keys are never written to Codex configuration or logs.").font(.caption).foregroundStyle(.secondary)
            }
            if let saved = profiles.savedConnection, saved.baseURL != settings.baseURL, settings.authMode == .keychain {
                Toggle("Confirm using the saved Key at this new address", isOn: $profiles.confirmedEndpoint).font(.caption)
            }
        }
        .confirmationDialog("Remove this API Key?", isPresented: $removing) {
            Button("Remove API Key", role: .destructive) { Task { await profiles.removeWorkspaceKey() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Keys required by the current configuration or recovery record cannot be removed.") }
    }
}

struct ProviderModelSection: View {
    @State private var manualEntry = false
    @Bindable var profiles: CodexModelProfilesStore
    var settings: ProviderSettings
    private var model: Binding<String> { Binding(get: { profiles.providerDraft?.model ?? "" }, set: { profiles.providerDraft?.model = $0 }) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Default model").font(.headline)
                Spacer()
                if profiles.fetchingModelsFor == settings.id { ProgressView().controlSize(.small) }
                if settings.isManagedEndpoint && settings.authMode != .environment {
                    Button("Refresh models", systemImage: "arrow.clockwise") { Task { await profiles.refreshWorkspaceModels() } }
                        .disabled(profiles.hasUnsavedChanges || profiles.savedConnection == nil || profiles.fetchingModelsFor != nil)
                        .accessibilityIdentifier("providers.refreshModels")
                }
            }
            if !profiles.workspaceModels.isEmpty && !manualEntry {
                Picker("Default model", selection: model) {
                    Text("Choose a model").tag("")
                    ForEach(profiles.workspaceModels) { item in Text(item.name.map { $0 + " · " + item.id } ?? item.id).tag(item.id) }
                    if !model.wrappedValue.isEmpty && !profiles.workspaceModels.contains(where: { $0.id == model.wrappedValue }) { Text(model.wrappedValue).tag(model.wrappedValue) }
                }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(settings.isManagedEndpoint ? "Model ID" : "Follow Codex default", text: model)
                    .accessibilityIdentifier("providers.model")
            }
            if settings.origin == .custom && !profiles.workspaceModels.isEmpty {
                Button(manualEntry ? L10n.text("Choose from model list") : L10n.text("Enter model ID")) { manualEntry.toggle() }.buttonStyle(.link)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 24) { specifications }
                VStack(alignment: .leading, spacing: 16) { specifications }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            if let cache = profiles.providerModelCaches[settings.id], cache.scope == ProviderModelScope(settings), let date = cache.fetchedAt {
                Text(L10n.text("Provider metadata") + " · " + date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                if cache.failure != nil { Text("Showing the last successful model list.").font(.caption).foregroundStyle(.secondary) }
            } else { Text("Model capabilities are unknown until supplied by a trusted catalog.").font(.caption).foregroundStyle(.secondary) }
            if settings.isManagedEndpoint && settings.authMode != .environment {
                HStack {
                    Button(profiles.connectionTesting ? L10n.text("Testing…") : L10n.text("Test connection")) { Task { await profiles.testWorkspaceConnection() } }
                        .disabled(profiles.hasUnsavedChanges || profiles.savedConnection == nil || settings.model.isEmpty || profiles.connectionTesting || settings.protocolName != "responses")
                        .accessibilityIdentifier("providers.test")
                    if profiles.connectionTesting { ProgressView().controlSize(.small) }
                    else if let result = profiles.connectionResult {
                        Image(systemName: result.failure == nil ? "checkmark.circle" : "exclamationmark.triangle")
                        Text(result.failure == nil ? L10n.text("Responses verified") : L10n.text("Test failed")).font(.caption)
                        Text(result.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    } else { Text("Not tested").font(.caption).foregroundStyle(.secondary) }
                }
                Text("Save first. Testing makes a small model request and may incur API charges.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    @ViewBuilder private var specifications: some View {
        specification("Context window", profiles.workspaceModel?.contextWindow.map { $0.formatted() + " tokens" } ?? L10n.text("Unknown"), valueFont: .callout.monospacedDigit())
        specification("Default reasoning", profiles.workspaceModel?.defaultReasoning ?? L10n.text("Unknown"))
        specification("Supported reasoning", profiles.workspaceModel?.reasoningLevels?.joined(separator: " / ") ?? L10n.text("Unknown"))
    }
    private func specification(_ title: LocalizedStringKey, _ value: String, valueFont: Font = .callout) -> some View {
        VStack(alignment: .leading, spacing: 7) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(valueFont).textSelection(.enabled) }
    }
}

struct ProviderAdvancedSection: View {
    @Bindable var profiles: CodexModelProfilesStore
    var settings: ProviderSettings
    @State private var contextInput = ""
    @State private var contextInvalid = false
    private var expanded: Binding<Bool> { Binding(get: { profiles.expandedProviders.contains(settings.id) }, set: { if $0 { profiles.expandedProviders.insert(settings.id) } else { profiles.expandedProviders.remove(settings.id) } }) }
    var body: some View {
        DisclosureGroup("Advanced options", isExpanded: expanded) {
            VStack(alignment: .leading, spacing: 18) {
                if settings.origin == .builtin && settings.isManagedEndpoint {
                    ProviderFormRow("Service address") {
                        TextField("Service address", text: Binding(get: { profiles.providerDraft?.baseURL ?? "" }, set: { profiles.providerDraft?.baseURL = $0 }))
                            .accessibilityIdentifier("providers.baseURL")
                    }
                }
                ProviderFormRow("Reasoning effort") {
                    Picker("Reasoning effort", selection: Binding(get: { profiles.providerDraft?.reasoning ?? "" }, set: { profiles.providerDraft?.reasoning = $0 })) {
                        Text("Use model default").tag("")
                        ForEach(profiles.permittedReasoning, id: \.self) { Text($0).tag($0) }
                        if !settings.reasoning.isEmpty && !profiles.permittedReasoning.contains(settings.reasoning) { Text(settings.reasoning + " · " + L10n.text("Existing override")).tag(settings.reasoning) }
                    }.labelsHidden()
                }
                ProviderFormRow("Context override") {
                    TextField("Automatic", text: $contextInput)
                        .monospacedDigit()
                        .accessibilityIdentifier("providers.context")
                        .onChange(of: contextInput) { _, text in
                            let trimmed = text.trimmingCharacters(in: .whitespaces)
                            contextInvalid = !trimmed.isEmpty && (Int(trimmed).map { $0 <= 0 } ?? true)
                            profiles.invalidContextInput = contextInvalid
                            if !contextInvalid { profiles.providerDraft?.contextWindowOverride = Int(trimmed) }
                        }
                }
                if contextInvalid { Text("Enter a positive context window.").font(.caption).foregroundStyle(.red) }
                Text("Leave empty to inherit the model context. A manual limit affects Codex context management.").font(.caption).foregroundStyle(.secondary)
                Divider()
                HStack {
                    Text("Responses API · API billing").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let source = settings.source, let url = URL(string: source) { Link("Provider documentation", destination: url).font(.caption) }
                }
            }.padding(.top, 18)
        }
        .disclosureGroupStyle(ProviderAdvancedDisclosureStyle())
        .onAppear { contextInput = settings.contextWindowOverride.map(String.init) ?? "" }
        .onChange(of: settings.id) { _, _ in contextInput = settings.contextWindowOverride.map(String.init) ?? ""; contextInvalid = false; profiles.invalidContextInput = false }
    }
}

private struct ProviderAdvancedDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 10)
                configuration.label
                Spacer(minLength: 0)
            }
            .frame(minHeight: 28)
            .accessibilityHidden(true)
            .overlay {
                ProviderAdvancedHeader(expanded: configuration.isExpanded) { configuration.isExpanded.toggle() }
            }
            if configuration.isExpanded { configuration.content }
        }
    }
}

/// Match the menu's native-focus/SwiftUI-label pattern so the entire header is one control.
private struct ProviderAdvancedHeader: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    var expanded: Bool
    var action: @MainActor () -> Void

    @MainActor final class Coordinator: NSObject {
        var action: @MainActor () -> Void
        init(action: @escaping @MainActor () -> Void) { self.action = action }
        @objc func invoke() { action() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.invoke))
        button.isBordered = false
        button.isTransparent = true
        button.focusRingType = .exterior
        button.setAccessibilityIdentifier("providers.advanced")
        button.setAccessibilityLabel(L10n.text("Advanced options"))
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.isEnabled = isEnabled
        button.setAccessibilityValue(expanded ? L10n.text("Expanded") : L10n.text("Collapsed"))
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.fittingSize.width, height: proposal.height ?? 28)
    }
}

struct ProviderActionBar: View {
    @Bindable var profiles: CodexModelProfilesStore
    var settings: ProviderSettings
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                if profiles.isDefaultConnection(settings) {
                    Text("Default for new sessions").font(.caption.weight(.medium))
                }
                Text(profiles.hasUnsavedChanges ? L10n.text("Unsaved changes") : applyLabel).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Cancel") { profiles.cancelWorkspaceEdits() }.disabled(!profiles.hasUnsavedChanges && profiles.workspaceSelection != .create)
            ModelProfileActionButton(title: L10n.text("Save"), identifier: "providers.save", key: "s", enabled: profiles.hasUnsavedChanges && !profiles.busy) {
                Task { await profiles.saveWorkspace() }
            }
            ModelProfileActionButton(title: defaultActionTitle, identifier: "providers.apply", key: "\r", enabled: profiles.canApplyWorkspace, primary: true) {
                Task { await profiles.requestWorkspaceApply() }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("providers.actionBar")
    }
    private var defaultActionTitle: String {
        if profiles.isDefaultConnection(settings) {
            return profiles.hasUnsavedChanges ? L10n.text("Save and apply") : L10n.text("Apply")
        }
        return profiles.hasUnsavedChanges || profiles.savedConnection == nil
            ? L10n.text("Save and set as default") : L10n.text("Set as default")
    }
    private var applyLabel: String {
        switch profiles.workspaceApplyStatus {
        case .notApplied: L10n.text("Not applied")
        case .applied: L10n.text("Applied to new-session defaults")
        case .needsRepair: L10n.text("Credential path needs repair")
        case .failed: L10n.text("Applying failed. Retry when ready.")
        }
    }
}

struct ProviderStatusBanner: View {
    @Bindable var profiles: CodexModelProfilesStore
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let issue = profiles.workspaceIssue, issue != profiles.error {
                HStack {
                    Label(issue, systemImage: "exclamationmark.triangle")
                    Spacer()
                    if let value = profiles.savedConnection, profiles.credentialPathNeedsRepair(value) {
                        Button("Re-enable") { Task { await profiles.repairWorkspacePath() } }.accessibilityIdentifier("providers.repair")
                    }
                }.padding(12).background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
            ModelProfilesNotice(profiles: profiles)
        }.font(.caption)
    }
}

struct ProviderFormRow<Content: View>: View {
    var title: LocalizedStringKey
    @ViewBuilder var content: Content
    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text(title).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ProviderDeletionSheet: View {
    @Bindable var profiles: CodexModelProfilesStore
    var settings: ProviderSettings
    @Environment(\.dismiss) private var dismiss
    @State private var replacement = "openai"
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Delete provider").font(.headline)
            Text(settings.displayName)
            if profiles.isDefaultConnection(settings) {
                Text("Choose a replacement for new sessions before deleting this provider.")
                Picker("Replacement", selection: $replacement) {
                    Text("OpenAI (official)").tag("openai")
                    ForEach(profiles.library.connections.filter { $0.id != settings.id && $0.id != "openai" && $0.validation.isEmpty }) { item in Text(item.displayName).tag(item.id) }
                }
                Text("The replacement must be applicable. Untested providers may fail when used.").font(.caption).foregroundStyle(.secondary)
            }
            Text("Codex provider definitions and credentials needed by existing sessions or recovery are retained.").font(.caption).foregroundStyle(.secondary)
            if let error = profiles.error { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Delete provider", role: .destructive) {
                    Task {
                        profiles.chooseConnectionForAction(settings.id)
                        await profiles.deleteWorkspace(replacementID: replacement)
                        if !profiles.library.connections.contains(where: { $0.id == settings.id }) { dismiss() }
                    }
                }.disabled(profiles.busy)
            }
        }.padding(24).frame(width: 440)
    }
}

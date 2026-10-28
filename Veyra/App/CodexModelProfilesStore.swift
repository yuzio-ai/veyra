import Foundation
import Observation

enum ProviderWorkspaceSelection: Equatable { case official, connection(String), create }

enum VeyraSettingsTab: String, CaseIterable { case general, models }

/// One word per provider in the sidebar. Problems are reported separately by
/// `CodexModelProfilesStore.providerIssue(_:)` so the list stays scannable.
enum ProviderReadiness: Equatable, Sendable {
    case inUse
    case configured
    case notConfigured
}

@MainActor @Observable
final class CodexModelProfilesStore {
    var library = ModelProfileLibrary()
    var snapshot: CodexConfigSnapshot?
    var draft: CodexModelProfile?
    var selectedID: UUID?
    var tab = VeyraSettingsTab.general
    var editorRevision = 0
    var renameRequested: String?
    var invalidContextInput = false
    var workspaceEnabled = false
    var workspaceSelection = ProviderWorkspaceSelection.connection("deepseek")
    var expandedProviders: Set<String> = []
    var replacingKey = false
    var confirmedEndpoint = false
    var setAsDefault = false
    var showUnverifiedPrompt = false
    var connectionTesting = false
    var applyErrors: [String: String] = [:]
    var editStatus = ProviderEditStatus.clean
    private var workspaceBaseline: ProviderSettings?
    @ObservationIgnored private var connectionRequest: Task<ProviderConnectivityResult, Error>?
    @ObservationIgnored private var connectionGeneration = 0
    var showAdvanced = false
    var selectedPresetID = "deepseek"
    var providerDraft: ProviderSettings? {
        didSet {
            if oldValue?.id != providerDraft?.id || oldValue?.baseURL != providerDraft?.baseURL || oldValue?.authMode != providerDraft?.authMode || oldValue?.credential != providerDraft?.credential {
                cancelModelDiscovery(); cancelConnectionTest()
            }
            if oldValue?.model != providerDraft?.model || oldValue?.protocolName != providerDraft?.protocolName { cancelConnectionTest() }
            if workspaceEnabled && providerDraft != workspaceBaseline { editStatus = .modified }
        }
    }
    // Transient UI input only. It is never part of a Codable type or diagnostics.
    var apiKeyInput = "" {
        didSet { if !apiKeyInput.isEmpty { cancelModelDiscovery(); cancelConnectionTest(); if workspaceEnabled { editStatus = .modified } } }
    }
    var providerKeyAvailable: [String: Bool] = [:]
    var providerModelCaches: [String: ProviderModelCache] = [:]
    private(set) var fetchingModelsFor: String?
    var credentialCommandsSupported = false
    var providerKeyIssues: [String: String] = [:]
    var busy = false
    var error: String? { didSet { if error != nil { message = nil } } }
    var message: String?
    var attemptedValidation = false
    var showUnsavedPrompt = false
    var isPreview = false
    private(set) var writesSupported = false
    private(set) var location: CodexLocation?
    @ObservationIgnored private let service: CodexModelProfileService
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var configurationFailure: ModelProfileFailure?
    @ObservationIgnored private var pendingNavigation: (@MainActor () -> Void)?
    @ObservationIgnored private var modelRequest: Task<ProviderModelCache, Error>?
    @ObservationIgnored private var modelGeneration = 0
    @ObservationIgnored private var providerSaveCanApply = false

    init(service: CodexModelProfileService = CodexModelProfileService()) { self.service = service }

    var profiles: [CodexModelProfile] { library.profiles }
    var sidebarProfiles: [CodexModelProfile] {
        if let draft, !profiles.contains(where: { $0.id == draft.id }) { return profiles + [draft] }
        return profiles
    }
    var hasUnsavedChanges: Bool {
        if workspaceEnabled { return invalidContextInput || !apiKeyInput.isEmpty || providerDraft != workspaceBaseline }
        if !showAdvanced {
            guard let providerDraft, let preset = ProviderPreset.find(providerDraft.id) else { return !apiKeyInput.isEmpty }
            return !apiKeyInput.isEmpty || providerDraft != (library.providers.first { $0.id == providerDraft.id } ?? ProviderSettings(preset: preset))
        }
        guard let draft else { return !apiKeyInput.isEmpty }
        return !apiKeyInput.isEmpty || draft != profiles.first { $0.id == draft.id }
    }
    var fieldErrors: [String: String] {
        guard let draft else { return [:] }
        var result = draft.validation
        if !apiKeyInput.isEmpty { result["credential"] = nil; do { try CredentialFailure.validate(apiKeyInput) } catch { result["credential"] = CredentialFailure.invalid.localizedDescription } }
        if profiles.contains(where: { $0.id != draft.id && $0.name.localizedCaseInsensitiveCompare(draft.normalized().name) == .orderedSame }) {
            result["name"] = L10n.text("A profile with this name already exists.")
        }
        return result
    }
    var defaultName: String {
        guard let snapshot else { return L10n.text("Configuration unavailable") }
        if let profile = profiles.first(where: { $0.matches(snapshot) }) { return profile.name }
        return snapshot.user["model"].string ?? snapshot.user["model_provider"].string ?? L10n.text("Codex default")
    }
    var currentProviderProfileID: UUID? {
        guard let snapshot else { return nil }
        let candidates = profiles.filter { $0.matchesProvider(snapshot) }
        let exact = candidates.filter { $0.providerID == snapshot.configuredProviderID }
        let matches = exact.isEmpty ? candidates : exact
        return matches.count == 1 ? matches.first?.id : nil
    }
    var defaultProviderIdentity: CodexProviderIdentity {
        guard let snapshot else { return CodexProviderIdentity(name: L10n.text("Configuration unavailable")) }
        if let id = currentProviderProfileID, let profile = profiles.first(where: { $0.id == id }) {
            return profile.providerIdentity
        }
        return snapshot.providerIdentity
    }

    func providerTitle(_ profile: CodexModelProfile) -> String {
        let identity = profile.providerIdentity.name
        let sameName = sidebarProfiles.filter { $0.providerIdentity.name.localizedCaseInsensitiveCompare(identity) == .orderedSame }
        guard sameName.count > 1 else { return identity }
        let title = "\(identity) · \(profile.name)"
        let sameTitle = sameName.filter { $0.name.localizedCaseInsensitiveCompare(profile.name) == .orderedSame }
        // Full UUIDs are available without changing or migrating any saved connection.
        let length = (8...32).first { length in
            Set(sameTitle.map { $0.id.uuidString.replacingOccurrences(of: "-", with: "").prefix(length) }).count == sameTitle.count
        } ?? 32
        return sameTitle.count > 1 ? title + " · " + profile.id.uuidString.replacingOccurrences(of: "-", with: "").prefix(length) : title
    }
    var canUndo: Bool {
        guard writesSupported, !busy, let journal = library.journal, let snapshot else { return false }
        return ModelProfilePatch.matches(journal.after, snapshot: snapshot)
    }

    func load(location newLocation: CodexLocation) async {
        guard !isPreview else { return }
        if location != newLocation {
            cancelModelDiscovery()
            generation += 1
            workspaceBaseline = nil; cancelConnectionTest()
            location = newLocation
            library = ModelProfileLibrary(); snapshot = nil; draft = nil; selectedID = nil
            writesSupported = false; error = nil; message = nil; busy = false
            providerDraft = nil; apiKeyInput = ""; providerKeyAvailable = [:]; providerKeyIssues = [:]; credentialCommandsSupported = false
            providerModelCaches = [:]
            configurationFailure = nil
        }
        guard !busy else { return }
        let version = generation
        busy = true
        defer { if generation == version { busy = false } }
        do {
            let local = try await service.library(home: newLocation.home)
            guard version == generation else { return }
            library = local
            providerModelCaches = try await service.cachedModels(home: newLocation.home)
            guard version == generation else { return }
            if draft == nil { selectImmediately(profiles.first?.id) }
            let context = try await service.read(location: newLocation)
            guard version == generation else { return }
            accept(context)
            credentialCommandsSupported = await service.supportsCredentialCommands(location: newLocation)
            await refreshProviderKeys()
            if providerDraft == nil, let preset = ProviderPreset.find(selectedPresetID) {
                providerDraft = library.providers.first { $0.id == selectedPresetID } ?? ProviderSettings(preset: preset)
            }
            writesSupported = context.library.pending == nil
            configurationFailure = context.recoveryIssue
            error = context.recoveryIssue?.localizedDescription
            if workspaceEnabled && (workspaceBaseline == nil || !hasUnsavedChanges) { chooseWorkspaceImmediately(workspaceSelection) }
        } catch {
            guard version == generation else { return }
            writesSupported = false
            configurationFailure = (error as? ModelProfileFailure) ?? .unavailable
            self.error = safeMessage(error)
        }
    }

    func navigate(_ action: @escaping @MainActor () -> Void) {
        cancelModelDiscovery(); cancelConnectionTest()
        guard !busy else { return }
        if hasUnsavedChanges {
            pendingNavigation = action
            showUnsavedPrompt = true
        } else { action() }
    }

    func resolveNavigation(save: Bool) async {
        if save {
            let saved = workspaceEnabled ? await saveWorkspace() : showAdvanced ? await saveDraft() : await saveProviderDraft()
            if !saved { pendingNavigation = nil; showUnsavedPrompt = false; return }
        }
        if !save {
            if workspaceEnabled { invalidContextInput = false; providerDraft = workspaceBaseline }
            apiKeyInput = ""
            if !workspaceEnabled, showAdvanced { selectImmediately(selectedID) }
            else if !workspaceEnabled, let preset = ProviderPreset.find(selectedPresetID) { providerDraft = library.providers.first { $0.id == selectedPresetID } ?? ProviderSettings(preset: preset) }
        }
        let action = pendingNavigation
        pendingNavigation = nil
        showUnsavedPrompt = false
        action?()
    }

    func cancelNavigation() { pendingNavigation = nil; showUnsavedPrompt = false }

    func select(_ id: UUID?) { navigate { self.showAdvanced = true; self.selectImmediately(id) } }
    private func selectImmediately(_ id: UUID?) {
        apiKeyInput = ""
        selectedID = id
        draft = profiles.first { $0.id == id }
        attemptedValidation = false
    }

    func newProfile() {
        navigate {
            var profile = CodexModelProfile(name: self.uniqueName(L10n.text("New provider")), kind: .custom)
            profile.authentication = .keychain
            self.showAdvanced = true; self.apiKeyInput = ""
            self.draft = profile; self.selectedID = profile.id; self.attemptedValidation = false
        }
    }

    func duplicate() {
        guard draft != nil else { return }
        navigate {
            self.showAdvanced = true; self.apiKeyInput = ""
            guard let original = self.draft else { return }
            var copy = original
            copy.id = UUID(); copy.name = self.uniqueName(original.name + " " + L10n.text("Copy"))
            self.draft = copy; self.selectedID = copy.id; self.attemptedValidation = false
        }
    }

    func importCurrent() {
        guard let snapshot else { return }
        navigate {
            self.showAdvanced = true; self.apiKeyInput = ""
            let profile = CodexModelProfile.imported(from: snapshot, name: self.uniqueName(L10n.text("Current configuration")))
            self.draft = profile; self.selectedID = profile.id; self.attemptedValidation = false
        }
    }

    func uniqueName(_ base: String) -> String {
        var value = base, suffix = 2
        while profiles.contains(where: { $0.name.localizedCaseInsensitiveCompare(value) == .orderedSame }) {
            value = "\(base) \(suffix)"; suffix += 1
        }
        return value
    }

    @discardableResult
    func saveDraft() async -> Bool {
        attemptedValidation = true
        guard !busy, let draft, fieldErrors.isEmpty else { return false }
        if draft.kind == .custom, !apiKeyInput.isEmpty {
            guard let location else { return false }
            busy = true; defer { busy = false }
            do {
                if isPreview {
                    var saved = draft.normalized(); saved.authentication = .keychain; saved.environmentKey = ""
                    saved.credentialReference = CredentialReference(); saved.helperPath = Bundle.main.executablePath
                    library.profiles.removeAll { $0.id == saved.id }; library.profiles.append(saved)
                    self.draft = saved; selectedID = saved.id; apiKeyInput = ""; return true
                }
                library = try await service.saveLegacyKey(draft, newKey: apiKeyInput, home: location.home)
                self.draft = library.profiles.first { $0.id == draft.id }; selectedID = draft.id; apiKeyInput = ""; return true
            } catch { self.error = safeMessage(error); return false }
        }
        var profiles = profiles
        let normalized = draft.normalized()
        if let index = profiles.firstIndex(where: { $0.id == draft.id }) { profiles[index] = normalized }
        else { profiles.append(normalized) }
        guard await persist(profiles) else { return false }
        self.draft = normalized; selectedID = normalized.id
        return true
    }

    func deleteSelected() async {
        guard let selectedID, !busy else { return }
        let remaining = profiles.filter { $0.id != selectedID }
        guard await persist(remaining) else { return }
        selectImmediately(remaining.first?.id)
    }

    private func persist(_ profiles: [CodexModelProfile]) async -> Bool {
        guard let location, !busy else { return false }
        if isPreview { library.profiles = profiles; return true }
        let version = generation
        busy = true
        defer { if version == generation { busy = false } }
        do {
            let library = try await service.saveProfiles(profiles, home: location.home)
            guard version == generation else { return false }
            self.library = library; error = configurationFailure?.localizedDescription
            return true
        } catch {
            if version == generation { self.error = safeMessage(error) }
            return false
        }
    }

    func applyDraft() async {
        guard let draft, !busy else { return }
        if hasUnsavedChanges, !(await saveDraft()) { return }
        await apply((self.draft ?? draft).normalized())
    }

    func apply(_ profile: CodexModelProfile) async {
        guard !busy, writesSupported, let location, let snapshot else { return }
        if profile.kind == .custom && profile.authentication == .environment { error = CredentialFailure.missing.localizedDescription; return }
        await update(location: location) {
            try await self.service.apply(profile, location: location, expectedVersion: snapshot.version)
        }
    }

    func undo() async {
        guard canUndo, let location else { return }
        await update(location: location, undo: true) { try await self.service.undo(location: location) }
    }

    private func update(location: CodexLocation, undo: Bool = false,
                        operation: () async throws -> ModelProfileContext) async {
        let version = generation
        busy = true; error = nil; message = nil
        defer { if version == generation { busy = false } }
        do {
            if isPreview { message = L10n.text("Preview only. Codex configuration was not changed."); return }
            let context = try await operation()
            guard version == generation else { return }
            accept(context)
            message = undo ? L10n.text("Previous default configuration restored. Restart Codex to use it.")
                : L10n.text("Set as the default provider for new sessions. Restart open Codex clients if needed.")
        } catch {
            guard version == generation else { return }
            self.error = safeMessage(error)
            if error as? ModelProfileFailure == .unsupported { writesSupported = false; configurationFailure = .unsupported }
            // Resolve uncertain writes and refresh external changes without issuing another write.
            if let context = try? await service.read(location: location), version == generation { accept(context) }
            else if version == generation { writesSupported = false; snapshot = nil; configurationFailure = .unavailable }
        }
    }

    var currentPresetID: String? {
        ProviderPreset.all.first { snapshot?.configuredProviderID == "veyra_preset_" + $0.id }?.id
    }
    var switchablePresets: [ProviderPreset] {
        guard credentialCommandsSupported, writesSupported else { return [] }
        return ProviderPreset.all.filter { preset in
            library.providers.contains { $0.id == preset.id && $0.validation.isEmpty && $0.credential != nil }
                && providerKeyAvailable[preset.id] == true
                && library.providers.first(where: { $0.id == preset.id }).map { settings in
                    providerModelCaches[preset.id].map { $0.scope == ProviderModelScope(settings) && $0.contains(settings.model) } == true
                } == true
        }
    }
    /// The sidebar shows one word per provider; problems live in `providerIssue`.
    func providerReadiness(_ preset: ProviderPreset) -> ProviderReadiness {
        if currentPresetID == preset.id { return .inUse }
        return providerKeyAvailable[preset.id] == true ? .configured : .notConfigured
    }

    /// A single blocking reason for the detail pane, highest priority first.
    func providerIssue(_ preset: ProviderPreset) -> String? {
        if let issue = providerKeyIssues[preset.id] { return issue }
        if providerKeyAvailable[preset.id] == true && (!credentialCommandsSupported || !writesSupported) {
            return L10n.text("This Codex executable does not support Keychain credential commands. Update Codex or select its native executable in General.")
        }
        if currentPresetID == preset.id,
           !ExecutablePath.matches(snapshot?.configuredProvider["auth"]["command"].string, Bundle.main.executablePath) {
            return L10n.text("Veyra moved. Re-enable this provider to repair the credential path.")
        }
        if providerModelCaches[preset.id]?.failure == .authentication {
            return L10n.text("The provider rejected the saved Key. Update it, then refresh models.")
        }
        return nil
    }
    func selectPreset(_ id: String) {
        navigate {
            guard let preset = ProviderPreset.find(id) else { return }
            self.showAdvanced = false; self.selectedPresetID = id; self.apiKeyInput = ""
            self.providerDraft = self.library.providers.first { $0.id == id } ?? ProviderSettings(preset: preset)
        }
    }
    func setAdvanced(_ advanced: Bool) { navigate { self.showAdvanced = advanced; self.apiKeyInput = "" } }
    private func refreshProviderKeys() async {
        guard !isPreview else { return }
        providerKeyAvailable = [:]; providerKeyIssues = [:]
        for settings in library.connections {
            guard let reference = settings.credential else { continue }
            do { providerKeyAvailable[settings.id] = try await service.hasCredential(reference) }
            catch { providerKeyIssues[settings.id] = safeMessage(error) }
        }
    }

    var selectedModelCache: ProviderModelCache? {
        guard let draft = providerDraft, let cache = providerModelCaches[draft.id], cache.scope == ProviderModelScope(draft) else { return nil }
        return cache
    }
    var discoveredModels: [DiscoveredModel] { selectedModelCache?.models ?? [] }
    var selectedDiscoveredModel: DiscoveredModel? { discoveredModels.first { $0.id == providerDraft?.model } }
    var canEnableProviderDraft: Bool {
        guard let draft = providerDraft else { return false }
        return selectedModelCache?.contains(draft.model) == true && draft.validation.isEmpty
    }
    var modelDiscoveryState: ModelDiscoveryState {
        if fetchingModelsFor == selectedPresetID { return .loading }
        guard let cache = selectedModelCache else { return .idle }
        if cache.failure != nil { return cache.permitsEnable ? .cached : .failed }
        guard cache.fetchedAt != nil else { return .idle }
        return cache.models.isEmpty ? .empty : .ready
    }
    var canRefreshModels: Bool {
        guard !busy, apiKeyInput.isEmpty, let draft = providerDraft,
              let saved = library.providers.first(where: { $0.id == draft.id }) else { return false }
        return ProviderModelScope(draft) == ProviderModelScope(saved) && saved.credential != nil
            && providerKeyAvailable[draft.id] == true && fetchingModelsFor == nil
    }
    func cancelModelDiscovery() {
        modelGeneration += 1; modelRequest?.cancel(); modelRequest = nil; fetchingModelsFor = nil
    }
    @discardableResult
    func refreshModels() async -> Bool {
        guard canRefreshModels, let location, let settings = library.providers.first(where: { $0.id == selectedPresetID }),
              let scope = ProviderModelScope(settings) else { return false }
        cancelModelDiscovery()
        let version = modelGeneration
        let homeGeneration = generation
        fetchingModelsFor = settings.id
        let request = Task { [service, isPreview] in
            if isPreview {
                return ProviderModelCache(scope: scope, models: Self.previewModels, fetchedAt: Date())
            }
            return try await service.fetchProviderModels(settings.id, home: location.home)
        }
        modelRequest = request
        defer { if version == modelGeneration { fetchingModelsFor = nil; modelRequest = nil } }
        do {
            let cache = try await request.value
            guard version == modelGeneration, homeGeneration == generation, selectedPresetID == settings.id,
                  ProviderModelScope(providerDraft ?? settings) == scope else { return false }
            providerModelCaches[settings.id] = cache
            return cache.failure == nil
        } catch {
            guard !(error is CancellationError), version == modelGeneration, homeGeneration == generation else { return false }
            self.error = safeMessage(error)
            return false
        }
    }

    @discardableResult
    func saveProviderDraft() async -> Bool {
        guard !busy, let draft = providerDraft, let location else { return false }
        cancelModelDiscovery(); providerSaveCanApply = false
        let version = generation
        let newKey = !apiKeyInput.isEmpty
        attemptedValidation = true
        guard draft.validation.isEmpty else { return false }
        busy = true
        do {
            if !apiKeyInput.isEmpty { try CredentialFailure.validate(apiKeyInput) }
            if isPreview {
                var saved = draft; saved.credential = saved.credential ?? CredentialReference()
                library.providers.removeAll { $0.id == saved.id }; library.providers.append(saved)
            } else {
                let saved = try await service.saveProvider(draft, newKey: apiKeyInput.isEmpty ? nil : apiKeyInput, home: location.home)
                guard version == generation else { return false }
                library = saved
            }
            providerDraft = library.providers.first { $0.id == draft.id }; apiKeyInput = ""
            if isPreview { providerKeyAvailable[draft.id] = true } else { await refreshProviderKeys() }
            guard version == generation else { return false }
            busy = false; error = nil
            let requiresFetch = newKey || selectedModelCache?.fetchedAt == nil
            providerSaveCanApply = !requiresFetch
            if requiresFetch { providerSaveCanApply = await refreshModels() }
            return true
        } catch {
            if version == generation { self.error = safeMessage(error); busy = false }
            return false
        }
    }
    func saveAndApplyProvider() async {
        guard let id = providerDraft?.id else { return }
        guard await saveProviderDraft() else { return }
        guard providerSaveCanApply, selectedPresetID == id, canEnableProviderDraft else { return }
        await applyPreset(id)
    }
    func applyPreset(_ id: String) async {
        guard !busy, writesSupported, credentialCommandsSupported, let location, let snapshot else { return }
        await update(location: location) { try await self.service.applyProvider(id, location: location, expectedVersion: snapshot.version) }
        await refreshProviderKeys()
    }
    func restoreOpenAI() async {
        guard !busy, writesSupported, let location, let snapshot else { return }
        await update(location: location) { try await self.service.restoreOpenAI(location: location, expectedVersion: snapshot.version) }
    }
    func removeProviderKey() async {
        guard !busy, let location else { return }
        busy = true; defer { busy = false }
        do {
            if isPreview { providerKeyAvailable[selectedPresetID] = false }
            else { library = try await service.removeProviderKey(selectedPresetID, location: location); await refreshProviderKeys() }
            if let preset = ProviderPreset.find(selectedPresetID) { providerDraft = library.providers.first { $0.id == preset.id } ?? ProviderSettings(preset: preset) }
            apiKeyInput = ""; error = nil
        } catch { self.error = safeMessage(error) }
    }
    func discardUndo() async {
        guard !busy, let location else { return }
        busy = true; defer { busy = false }
        do {
            if isPreview { library.journal = nil } else { library = try await service.discardUndo(home: location.home) }
        } catch { self.error = safeMessage(error) }
    }

    private func accept(_ context: ModelProfileContext) {
        library = context.library; snapshot = context.snapshot
        if context.library.pending != nil { writesSupported = false; configurationFailure = context.recoveryIssue ?? .changed }
    }
    private func safeMessage(_ error: Error) -> String {
        if let failure = error as? CredentialFailure { return failure.localizedDescription }
        if let failure = error as? ModelDiscoveryFailure { return failure.localizedDescription }
        if let failure = error as? ProviderConnectionFailure { return failure.localizedDescription }
        return ((error as? ModelProfileFailure) ?? .unavailable).localizedDescription
    }

    var customConnections: [ProviderDescriptor] { library.connections.filter { $0.origin == .custom } }
    var selectedConnection: ProviderSettings? { providerDraft }
    var savedConnection: ProviderSettings? { library.connections.first { $0.id == providerDraft?.id } }
    var connectionResult: ProviderConnectivityResult? {
        guard apiKeyInput.isEmpty, let value = providerDraft, let result = savedConnection?.connectivity, result.matches(value) else { return nil }
        return result
    }
    var workspaceModels: [DiscoveredModel] {
        guard let settings = providerDraft, let cache = providerModelCaches[settings.id], cache.scope == ProviderModelScope(settings) else { return [] }
        return cache.models
    }
    var workspaceModel: DiscoveredModel? { workspaceModels.first { $0.id == providerDraft?.model } }
    var permittedReasoning: [String] {
        let supported = Set(CodexModelProfile.supportedReasoning)
        if let levels = workspaceModel?.reasoningLevels { return levels.filter { supported.contains($0) } }
        guard let value = providerDraft else { return [] }
        // An observed configuration can establish an existing override for this exact model.
        let configured = snapshot?.configuredProviderID == value.codexProviderID && snapshot?.user["model"].string == value.model
            ? snapshot?.user["model_reasoning_effort"].string : nil
        let official = value.id == "openai" && library.openAISnapshot?.first(where: { $0.keyPath == "model" })?.value.string == value.model
            ? library.openAISnapshot?.first(where: { $0.keyPath == "model_reasoning_effort" })?.value.string : nil
        return [configured ?? official].compactMap { $0 }.filter { supported.contains($0) }
    }
    var workspaceErrors: [String: String] {
        guard let value = providerDraft else { return [:] }
        var errors = value.validation
        if invalidContextInput { errors["context"] = L10n.text("Enter a positive context window.") }
        if !value.reasoning.isEmpty && !permittedReasoning.contains(value.reasoning), value.reasoning != workspaceBaseline?.reasoning {
            errors["reasoning"] = L10n.text("Choose a supported reasoning effort.")
        }
        if value.isManagedEndpoint, value.authMode == .keychain,
           value.credential == nil && apiKeyInput.isEmpty { errors["credential"] = CredentialFailure.missing.localizedDescription }
        if !apiKeyInput.isEmpty {
            do { try CredentialFailure.validate(apiKeyInput) } catch { errors["credential"] = CredentialFailure.invalid.localizedDescription }
        }
        if let saved = savedConnection, saved.baseURL != value.baseURL, value.authMode == .keychain,
           apiKeyInput.isEmpty && !confirmedEndpoint { errors["endpoint"] = L10n.text("Confirm authentication before sending the saved Key to this address.") }
        return errors
    }
    func isDefaultConnection(_ settings: ProviderSettings) -> Bool {
        guard let snapshot else { return false }
        if settings.legacyProfile?.kind == .reference { return settings.legacyValue?.matchesProvider(snapshot) == true }
        if settings.legacyProfile?.kind == .official && settings.id != "openai" { return settings.legacyValue?.matches(snapshot) == true }
        return snapshot.configuredProviderID == settings.codexProviderID
            && (settings.codexProviderID != "openai" || snapshot.configuredOpenAIBaseURL == nil)
    }
    func configurationStatus(_ settings: ProviderSettings) -> ProviderConfigurationStatus {
        guard let saved = library.connections.first(where: { $0.id == settings.id }) else { return .unconfigured }
        if !saved.validation.isEmpty || saved.protocolName != "responses" || (saved.connectivity?.matches(saved) == true && [.authentication, .incompatible].contains(saved.connectivity?.failure)) { return .invalid }
        if settings.isManagedEndpoint && saved.model.isEmpty { return .unconfigured }
        if settings.isManagedEndpoint && settings.authMode == .keychain {
            if providerKeyIssues[settings.id] != nil { return .invalid }
            return providerKeyAvailable[settings.id] == true ? .configured : .unconfigured
        }
        return library.connections.contains(where: { $0.id == settings.id }) || settings.id == "openai" ? .configured : .unconfigured
    }
    func credentialPathNeedsRepair(_ settings: ProviderSettings) -> Bool {
        guard settings.isManagedEndpoint, settings.authMode == .keychain,
              let auth = snapshot?.user["model_providers"][settings.codexProviderID]["auth"].object,
              auth["args"]?.array?.first?.string == "--provider-credential" else { return false }
        return !ExecutablePath.matches(auth["command"]?.string, Bundle.main.executablePath)
    }
    var workspaceIssue: String? {
        guard let value = providerDraft else { return nil }
        if let configurationFailure { return configurationFailure.localizedDescription }
        if let issue = providerKeyIssues[value.id] { return issue }
        if value.authMode == .keychain && value.isManagedEndpoint && !credentialCommandsSupported {
            return L10n.text("This Codex executable does not support Keychain credential commands. Update Codex or select its native executable in General.")
        }
        if credentialPathNeedsRepair(value) { return L10n.text("Veyra moved. Re-enable this provider to repair the credential path.") }
        if let result = connectionResult, let failure = result.failure { return failure.localizedDescription }
        if !value.reasoning.isEmpty && !permittedReasoning.contains(value.reasoning) { return L10n.text("Choose a verified reasoning level or use the model default before applying.") }
        if value.reasoning.isEmpty, let defaultReasoning = workspaceModel?.defaultReasoning, !CodexModelProfile.supportedReasoning.contains(defaultReasoning) { return L10n.text("This model's default reasoning level is not supported by this Codex integration.") }
        return nil
    }
    var workspaceApplyStatus: ProviderApplyStatus {
        guard let value = providerDraft else { return .notApplied }
        if credentialPathNeedsRepair(value) { return .needsRepair }
        if applyErrors[value.id] != nil { return .failed }
        guard !hasUnsavedChanges, let snapshot, let helper = Bundle.main.executableURL,
              let profile = try? value.profile(helper: helper, catalogPath: snapshot.user["model_catalog_json"].string ?? "", discoveredModel: workspaceModel),
              profile.matches(snapshot) else { return .notApplied }
        if value.isManagedEndpoint,
           snapshot.user["model_context_window"].integer != profile.contextWindow.map(Int64.init) { return .notApplied }
        return .applied
    }
    var canApplyWorkspace: Bool {
        guard !busy, !connectionTesting, writesSupported, let value = providerDraft,
              workspaceErrors.isEmpty, value.protocolName == "responses" else { return false }
        if value.isManagedEndpoint && !DiscoveredModel.validToken(value.model) { return false }
        if value.isManagedEndpoint && value.authMode == .keychain && !credentialCommandsSupported { return false }
        if !value.reasoning.isEmpty && !permittedReasoning.contains(value.reasoning) { return false }
        if value.reasoning.isEmpty, let defaultReasoning = workspaceModel?.defaultReasoning, !CodexModelProfile.supportedReasoning.contains(defaultReasoning) { return false }
        if connectionResult?.failure == .incompatible || connectionResult?.failure == .authentication { return false }
        if apiKeyInput.isEmpty, let cache = providerModelCaches[value.id], cache.scope == ProviderModelScope(value), cache.failure == .authentication { return false }
        if value.origin == .builtin && value.id != "openai" {
            return !apiKeyInput.isEmpty || providerModelCaches[value.id]?.contains(value.model) == true
        }
        return true
    }
    func chooseConnectionForAction(_ id: String) { chooseWorkspaceImmediately(.connection(id)) }
    func reloadWorkspace(location: CodexLocation) async {
        let selection = workspaceSelection
        await load(location: location)
        chooseWorkspaceImmediately(selection)
    }
    func activateWorkspace() {
        guard !workspaceEnabled else { return }
        let selection: ProviderWorkspaceSelection = showAdvanced && selectedID != nil
            ? .connection("legacy:" + selectedID!.uuidString.lowercased()) : .connection(selectedPresetID)
        workspaceEnabled = true
        chooseWorkspaceImmediately(selection)
    }
    func chooseWorkspace(_ selection: ProviderWorkspaceSelection) {
        navigate { self.chooseWorkspaceImmediately(selection) }
    }
    private func chooseWorkspaceImmediately(_ selection: ProviderWorkspaceSelection) {
        cancelModelDiscovery(); cancelConnectionTest()
        editorRevision += 1
        workspaceSelection = selection; apiKeyInput = ""; replacingKey = false; confirmedEndpoint = false
        error = nil; message = nil; attemptedValidation = false; setAsDefault = false
        switch selection {
        case .official:
            if let saved = library.connections.first(where: { $0.id == "openai" }) { providerDraft = saved }
            else {
                let model = library.openAISnapshot?.first { $0.keyPath == "model" }?.value.string
                    ?? (snapshot?.providerIdentity.isOfficial == true ? snapshot?.user["model"].string : nil) ?? ""
                let reasoning = library.openAISnapshot?.first { $0.keyPath == "model_reasoning_effort" }?.value.string
                    ?? (snapshot?.providerIdentity.isOfficial == true ? snapshot?.user["model_reasoning_effort"].string : nil) ?? ""
                var value = ProviderSettings(profile: CodexModelProfile(id: UUID(uuidString: "62141F01-A521-4ECC-BF32-000000000000")!, name: "OpenAI", model: model, reasoning: reasoning))
                value.id = "openai"; providerDraft = value
            }
        case .connection(let id):
            providerDraft = library.connections.first { $0.id == id }
                ?? ProviderPreset.find(id).map(ProviderSettings.init(preset:))
        case .create: providerDraft = ProviderSettings(name: "")
        }
        workspaceBaseline = providerDraft; editStatus = .clean; invalidContextInput = false
    }
    func cancelWorkspaceEdits() {
        cancelModelDiscovery(); cancelConnectionTest(); apiKeyInput = ""; replacingKey = false; confirmedEndpoint = false
        if workspaceSelection == .create { chooseWorkspaceImmediately(.official) }
        else { invalidContextInput = false; providerDraft = workspaceBaseline; attemptedValidation = false; error = nil; message = nil; editorRevision += 1 }
    }
    @discardableResult
    func saveWorkspace() async -> Bool {
        guard !busy, let value = providerDraft, let location else { return false }
        attemptedValidation = true
        guard workspaceErrors.isEmpty else { editStatus = .failed; return false }
        cancelModelDiscovery(); cancelConnectionTest(); busy = true; editStatus = .saving
        let version = generation
        defer { if version == generation { busy = false } }
        do {
            if isPreview {
                var saved = value
                if !apiKeyInput.isEmpty { saved.credential = CredentialReference(); providerKeyAvailable[value.id] = true }
                library.connections.removeAll { $0.id == saved.id }; library.connections.append(saved)
            } else {
                let updated = try await service.saveProvider(value, newKey: apiKeyInput.isEmpty ? nil : apiKeyInput,
                    home: location.home, confirmedAddress: confirmedEndpoint)
                guard version == generation else { return false }
                library = updated
                await refreshProviderKeys()
            }
            guard version == generation else { return false }
            providerDraft = library.connections.first { $0.id == value.id }
            workspaceBaseline = providerDraft; apiKeyInput = ""; replacingKey = false; confirmedEndpoint = false
            workspaceSelection = value.id == "openai" ? .official : .connection(value.id)
            error = nil; message = L10n.text("Provider saved. Codex defaults were not changed."); editStatus = .clean
            return true
        } catch {
            if version == generation { self.error = safeMessage(error); editStatus = .failed }
            return false
        }
    }
    func requestWorkspaceApply() async {
        guard canApplyWorkspace else { attemptedValidation = true; return }
        if hasUnsavedChanges || savedConnection == nil { guard await saveWorkspace() else { return } }
        guard let value = providerDraft else { return }
        if value.origin == .builtin && value.id != "openai", providerModelCaches[value.id]?.scope != ProviderModelScope(value) || providerModelCaches[value.id]?.contains(value.model) != true {
            await refreshWorkspaceModels()
            guard canApplyWorkspace else { error = ModelDiscoveryFailure.unavailable.localizedDescription; return }
        }
        if value.origin == .custom && value.isManagedEndpoint && (connectionResult == nil || connectionResult?.failure != nil) {
            showUnverifiedPrompt = true; return
        }
        await applyWorkspace()
    }
    func applyWorkspace() async {
        showUnverifiedPrompt = false
        guard canApplyWorkspace, let value = providerDraft, let location, let snapshot else { return }
        await update(location: location) { try await self.service.applyProvider(value.id, location: location, expectedVersion: snapshot.version) }
        if let error { applyErrors[value.id] = error; self.error = L10n.text("Provider saved, but applying failed.") + " " + error }
        else { applyErrors[value.id] = nil }
    }
    func repairWorkspacePath() async {
        guard let value = savedConnection, let location, let snapshot, !busy else { return }
        await update(location: location) { try await self.service.repairCredentialPath(value.id, location: location, expectedVersion: snapshot.version) }
        if error == nil && !isPreview { message = L10n.text("Credential path repaired. Model settings were not changed.") }
    }
    func cancelConnectionTest() {
        connectionGeneration += 1; connectionRequest?.cancel(); connectionRequest = nil; connectionTesting = false
    }
    func refreshWorkspaceModels() async {
        guard !busy, !hasUnsavedChanges, let saved = savedConnection, let location else { return }
        cancelModelDiscovery(); let token = modelGeneration; let version = generation
        fetchingModelsFor = saved.id
        let request = Task {
            if isPreview, let scope = ProviderModelScope(saved) { return ProviderModelCache(scope: scope, models: Self.previewModels, fetchedAt: Date()) }
            return try await service.fetchProviderModels(saved.id, home: location.home)
        }
        modelRequest = request
        defer { if token == modelGeneration { fetchingModelsFor = nil; modelRequest = nil } }
        do {
            let cache = try await request.value
            guard token == modelGeneration, version == generation, providerDraft?.id == saved.id else { return }
            providerModelCaches[saved.id] = cache
            if let failure = cache.failure { error = failure.localizedDescription } else { error = nil }
        } catch { if !(error is CancellationError), token == modelGeneration { self.error = safeMessage(error) } }
    }
    func testWorkspaceConnection() async {
        guard !busy, !hasUnsavedChanges, let saved = savedConnection, let location,
              saved.isManagedEndpoint, !saved.model.isEmpty, saved.authMode != .environment else { return }
        cancelConnectionTest(); let token = connectionGeneration; let version = generation
        connectionTesting = true; error = nil; message = nil
        let request = Task {
            if isPreview, let scope = ProviderModelScope(saved) { return ProviderConnectivityResult(scope: scope, model: saved.model, protocolName: saved.protocolName, date: Date()) }
            return try await service.testConnection(saved.id, home: location.home)
        }
        connectionRequest = request
        defer { if token == connectionGeneration { connectionTesting = false; connectionRequest = nil } }
        do {
            let result = try await request.value
            guard token == connectionGeneration, version == generation, providerDraft?.id == saved.id else { return }
            if let index = library.connections.firstIndex(where: { $0.id == saved.id }) { library.connections[index].connectivity = result }
            providerDraft?.connectivity = result; workspaceBaseline = providerDraft
            if let failure = result.failure { error = failure.localizedDescription }
            else { message = L10n.text("Responses test succeeded. Full Codex tool support was not tested.") }
        } catch { if !(error is CancellationError), token == connectionGeneration { self.error = safeMessage(error) } }
    }
    func duplicateWorkspace() {
        guard let original = savedConnection else { return }
        navigate {
            var copy = ProviderSettings(name: original.displayName + " " + L10n.text("Copy"))
            copy.model = original.model; copy.baseURL = original.baseURL; copy.reasoning = original.reasoning
            copy.contextWindowOverride = original.contextWindowOverride; copy.symbol = original.symbol
            copy.authentication = original.authMode == .none ? ModelProfileAuthentication.none : .keychain
            self.chooseWorkspaceImmediately(.create); self.providerDraft = copy
        }
    }
    func importWorkspace() {
        guard let snapshot else { return }
        navigate {
            self.chooseWorkspaceImmediately(.create)
            self.providerDraft = ProviderSettings(profile: .imported(from: snapshot, name: self.uniqueName(L10n.text("Current configuration"))))
        }
    }
    func deleteWorkspace(replacementID: String? = nil) async {
        guard let value = savedConnection, value.origin == .custom, let location, !busy else { return }
        if isDefaultConnection(value) {
            guard let replacementID else { return }
            if replacementID == "openai" { await restoreOpenAI() }
            else if let snapshot { await update(location: location) { try await self.service.applyProvider(replacementID, location: location, expectedVersion: snapshot.version) } }
            guard error == nil else { return }
            if value.legacyProfile?.kind != .official, isDefaultConnection(value) { return }
        }
        do {
            if isPreview { library.connections.removeAll { $0.id == value.id } }
            else { library = try await service.deleteConnection(value.id, location: location) }
            chooseWorkspaceImmediately(.official)
        } catch { self.error = safeMessage(error) }
    }
    func removeWorkspaceKey() async {
        guard let value = savedConnection, let location, !busy else { return }
        busy = true; defer { busy = false }
        do {
            if isPreview { providerKeyAvailable[value.id] = false; library.connections.removeAll { $0.id == value.id }; var updated = value; updated.credential = nil; library.connections.append(updated) }
            else { library = try await service.removeProviderKey(value.id, location: location); await refreshProviderKeys() }
            chooseWorkspaceImmediately(workspaceSelection)
        } catch { self.error = safeMessage(error) }
    }

    static func preview(_ scenario: String = "normal") -> CodexModelProfilesStore {
        if scenario.hasPrefix("workspace") {
            let store = preview("preset-configured"); store.activateWorkspace()
            if scenario == "workspace-expanded" { store.expandedProviders.insert("deepseek") }
            if scenario == "workspace-create" { store.chooseWorkspace(.create) }
            if ["workspace-local", "workspace-tested", "workspace-protocol"].contains(scenario) {
                var value = ProviderSettings(name: L10n.text("Local model"))
                value.authentication = ModelProfileAuthentication.none; value.baseURL = "http://127.0.0.1:11434/v1"; value.model = "local-model"
                if scenario == "workspace-tested", let scope = ProviderModelScope(value) { value.connectivity = ProviderConnectivityResult(scope: scope, model: value.model, protocolName: "responses", date: Date(timeIntervalSince1970: 1793000000)) }
                if scenario == "workspace-protocol" { value.wireAPI = "chat" }
                store.library.connections.append(value); store.chooseWorkspaceImmediately(.connection(value.id))
            }
            return store
        }
        let store = CodexModelProfilesStore()
        store.isPreview = true; store.writesSupported = true; store.tab = .models; store.showAdvanced = true; store.credentialCommandsSupported = true
        let home = URL(fileURLWithPath: "/tmp/veyra-model-profile-preview")
        store.location = CodexLocation(home: home, executable: nil)
        let official = CodexModelProfile(name: L10n.text("Official default"), model: "coding-default")
        var custom = CodexModelProfile(name: L10n.text("Development gateway"), kind: .custom, model: "coding-model",
                                       baseURL: "https://gateway.example.com/v1", environmentKey: "CODEX_PROXY_API_KEY")
        custom.providerName = "Development gateway"
        custom.authentication = .keychain; custom.credentialReference = CredentialReference()
        custom.helperPath = Bundle.main.executablePath
        var local = CodexModelProfile(name: L10n.text("Local model"), kind: .custom, model: "local-model",
                                      baseURL: "http://127.0.0.1:11434/v1", authentication: .none)
        local.providerName = "Local service"
        store.library.profiles = [official, custom, local]
        store.providerKeyAvailable["legacy:" + custom.id.uuidString.lowercased()] = true
        store.snapshot = CodexConfigSnapshot(user: .object(["model": .string(official.model), "model_provider": .string("openai")]),
                                            version: "fixture", file: home.appendingPathComponent("config.toml"))
        if scenario == "long" {
            store.library.profiles += (1...24).map { CodexModelProfile(name: "\(L10n.text("Development gateway")) \($0) — long profile name", model: "model-\($0)") }
        }
        if scenario == "empty" { store.library.profiles = [] }
        if scenario == "error" { store.error = ModelProfileFailure.unsupported.localizedDescription; store.writesSupported = false }
        store.selectImmediately(scenario == "empty" ? nil : custom.id)
        if scenario == "invalid" { store.draft?.baseURL = "invalid"; store.attemptedValidation = true }
        if ["success", "undo"].contains(scenario) {
            store.library.journal = ModelProfileJournal(
                before: [CodexConfigEdit(keyPath: "model", value: .string("previous-model"))],
                after: [CodexConfigEdit(keyPath: "model", value: .string(official.model))], completed: true)
        }
        if scenario == "success" { store.message = L10n.text("Set as the default provider for new sessions. Restart open Codex clients if needed.") }
        if ["provider-custom", "provider-long", "provider-busy"].contains(scenario) {
            if scenario == "provider-long" {
                custom.providerName = "供应商 Gateway — a very long provider connection name"
                store.library.profiles[1] = custom
            }
            store.snapshot = CodexConfigSnapshot(user: .object([
                "model_provider": .string(custom.providerID), "model": .string("different-chat-model"),
                "model_providers": .object([custom.providerID: custom.provider])
            ]), version: "fixture", file: home.appendingPathComponent("config.toml"))
            store.selectImmediately(custom.id)
        }
        if scenario == "provider-unavailable" {
            store.snapshot = nil; store.writesSupported = false
            store.error = ModelProfileFailure.unavailable.localizedDescription
        }
        if scenario == "provider-overridden" { store.snapshot?.overridden = true }
        if scenario == "provider-busy" { store.busy = true }
        if scenario.hasPrefix("preset") {
            store.showAdvanced = false
            let preset = ProviderPreset.all[0]
            var settings = ProviderSettings(preset: preset)
            if scenario != "preset-empty" { settings.model = Self.previewModels[0].id }
            if scenario != "preset-empty" { settings.credential = CredentialReference(); store.library.providers = [settings]; store.providerKeyAvailable[preset.id] = true }
            store.providerDraft = settings
            if let scope = ProviderModelScope(settings) {
                store.providerModelCaches[preset.id] = ProviderModelCache(scope: scope, models: Self.previewModels, fetchedAt: Date(timeIntervalSince1970: 1793000000))
            }
            if scenario == "preset-current" || scenario == "preset-repair" {
                let helper = scenario == "preset-repair" ? URL(fileURLWithPath: "/Applications/OldVeyra.app/Contents/MacOS/Veyra") : Bundle.main.executableURL!
                let p = try! settings.profile(helper: helper)
                store.snapshot = CodexConfigSnapshot(user: .object(["model_provider": .string(p.providerID), "model_providers": .object([p.providerID: p.provider])]), version: "fixture", file: home.appendingPathComponent("config.toml"))
            }
            if scenario == "preset-error" { store.providerKeyIssues[preset.id] = CredentialFailure.locked.localizedDescription }
            if scenario == "preset-unsupported" { store.credentialCommandsSupported = false }
            if scenario == "preset-busy" { store.busy = true }
            if scenario == "preset-dirty" { store.apiKeyInput = "fixture-input-only" }
            if scenario == "preset-loading" { store.fetchingModelsFor = preset.id }
            if scenario == "preset-no-models" { store.providerModelCaches[preset.id]?.models = []; store.providerDraft?.model = "" }
            if scenario == "preset-cached" { store.providerModelCaches[preset.id]?.failure = .network }
            if scenario == "preset-auth" { store.providerModelCaches[preset.id]?.failure = .authentication }
            if scenario == "preset-capabilities-missing" { store.providerDraft?.model = "new-model" }
            if scenario == "preset-removed" { store.providerDraft?.model = "previously-selected-model" }
        }
        return store
    }
    private static let previewModels = [DiscoveredModel(id: "example-model", contextWindow: 200000, reasoningLevels: ["low", "high", "max"], defaultReasoning: "high"), DiscoveredModel(id: "new-model")]
}

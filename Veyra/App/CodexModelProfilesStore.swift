import Foundation
import Observation

enum ProviderWorkspaceSelection: Equatable { case official, connection(String), create }

enum VeyraSettingsTab: String, CaseIterable { case general, models }

@MainActor @Observable
final class CodexModelProfilesStore {
    var library = ModelProfileLibrary()
    var snapshot: CodexConfigSnapshot?
    var tab = VeyraSettingsTab.general
    var editorRevision = 0
    var renameRequested: String?
    var invalidContextInput = false
    var workspaceEnabled = false
    var workspaceSelection = ProviderWorkspaceSelection.connection("deepseek")
    var expandedProviders: Set<String> = []
    var replacingKey = false
    var confirmedEndpoint = false
    var showUnverifiedPrompt = false
    var connectionTesting = false {
        didSet { if !connectionTesting { scheduleConfigurationReload() } }
    }
    var applyErrors: [String: String] = [:]
    var editStatus = ProviderEditStatus.clean
    private var workspaceBaseline: ProviderSettings?
    @ObservationIgnored private var connectionRequest: Task<ProviderConnectivityResult, Error>?
    @ObservationIgnored private var connectionGeneration = 0
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
    private(set) var fetchingModelsFor: String? {
        didSet { if fetchingModelsFor == nil { scheduleConfigurationReload() } }
    }
    var credentialCommandsSupported = false
    var providerKeyIssues: [String: String] = [:]
    var busy = false {
        didSet { if !busy { scheduleConfigurationReload() } }
    }
    var error: String? {
        didSet {
            if error != foregroundLoadError { foregroundLoadError = nil }
            if error != nil { message = nil }
        }
    }
    private(set) var configurationReloadError: String?
    var message: String?
    var attemptedValidation = false
    var showUnsavedPrompt = false
    var isPreview = false
    private(set) var monitoringAvailable = true
    private(set) var writesSupported = false
    private(set) var location: CodexLocation?
    @ObservationIgnored private let service: CodexModelProfileService
    @ObservationIgnored private let configurationChanged: @MainActor () -> Void
    @ObservationIgnored private var pendingConfigurationLocation: CodexLocation?
    @ObservationIgnored private var configurationReloadTask: Task<Void, Never>?
    @ObservationIgnored private var configurationReloadRevision = 0
    @ObservationIgnored private var configurationRetryTask: Task<Void, Never>?
    @ObservationIgnored private var configurationRetryFailures = 0
    @ObservationIgnored private var configurationRetryRevision = 0
    @ObservationIgnored private var configurationRequestRevision = 0
    @ObservationIgnored private var foregroundLoadError: String?
    @ObservationIgnored private let configurationClock: PollingClock
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var configurationFailure: ModelProfileFailure?
    @ObservationIgnored private var pendingNavigation: (@MainActor () -> Void)?
    @ObservationIgnored private var modelRequest: Task<ProviderModelCache, Error>?
    @ObservationIgnored private var modelGeneration = 0

    init(service: CodexModelProfileService = CodexModelProfileService(),
         configurationClock: PollingClock = .continuous(),
         configurationChanged: @escaping @MainActor () -> Void = {}) {
        self.service = service
        self.configurationClock = configurationClock
        self.configurationChanged = configurationChanged
    }

    var profiles: [CodexModelProfile] { library.profiles }
    func connectionIsBlocked(_ settings: ProviderSettings) -> Bool {
        if settings.blockingConnectionFailure != nil { return true }
        let cache = providerModelCaches[settings.id]
        return cache?.scope == ProviderModelScope(settings) && cache?.failure == .authentication
    }
    var switchableProfiles: [CodexModelProfile] {
        library.connections.filter { !connectionIsBlocked($0) }.compactMap(\.legacyValue).filter {
            $0.validation.isEmpty && ($0.kind != .custom || $0.authentication != .environment)
        }
    }
    var hasUnsavedChanges: Bool {
        invalidContextInput || !apiKeyInput.isEmpty || providerDraft != workspaceBaseline
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
        let sameName = profiles.filter { $0.providerIdentity.name.localizedCaseInsensitiveCompare(identity) == .orderedSame }
        guard sameName.count > 1 else { return identity }
        let title = "\(identity) · \(profile.name)"
        let sameTitle = sameName.filter { $0.name.localizedCaseInsensitiveCompare(profile.name) == .orderedSame }
        // Full UUIDs are available without changing or migrating any saved connection.
        let length = (8...32).first { length in
            Set(sameTitle.map { $0.id.uuidString.replacingOccurrences(of: "-", with: "").prefix(length) }).count == sameTitle.count
        } ?? 32
        return sameTitle.count > 1 ? title + " · " + profile.id.uuidString.replacingOccurrences(of: "-", with: "").prefix(length) : title
    }
    /// The monitor discovers external changes without blocking local task reads.
    func followConfiguration(of monitor: MonitorStore) {
        setMonitoringAvailable(monitor.canUseCodexServices)
        monitor.onConfigurationChange = { [weak self, weak monitor] location in
            guard let self, let monitor else { return }
            self.setMonitoringAvailable(monitor.canUseCodexServices)
            if self.monitoringAvailable { self.requestConfigurationReload(location: location) }
        }
    }

    private func setMonitoringAvailable(_ available: Bool) {
        guard monitoringAvailable != available else { return }
        monitoringAvailable = available
        guard !available else { return }
        generation += 1
        pendingConfigurationLocation = nil
        configurationRequestRevision += 1
        cancelConfigurationRetry()
        configurationReloadRevision += 1
        configurationReloadTask?.cancel(); configurationReloadTask = nil
        cancelModelDiscovery(); cancelConnectionTest()
        snapshot = nil; writesSupported = false; credentialCommandsSupported = false
        providerKeyAvailable = [:]; providerKeyIssues = [:]
        configurationReloadError = nil; foregroundLoadError = nil; error = nil; message = nil
        busy = false
    }

    func requestConfigurationReload(location: CodexLocation) {
        guard !isPreview, monitoringAvailable else { return }
        configurationRequestRevision += 1
        cancelConfigurationRetry()
        pendingConfigurationLocation = location
        scheduleConfigurationReload()
    }

    private func scheduleConfigurationReload() {
        guard canReloadConfiguration, configurationReloadTask == nil, configurationRetryTask == nil,
              pendingConfigurationLocation != nil else { return }
        configurationReloadRevision += 1
        let reloadRevision = configurationReloadRevision
        configurationReloadTask = Task { [weak self] in
            guard let self else { return }
            // A foreground directory change can queue a retry while an older
            // load is suspended. Its completion must respect that waiting timer.
            while self.canReloadConfiguration, self.configurationRetryTask == nil,
                  let location = self.pendingConfigurationLocation {
                self.pendingConfigurationLocation = nil
                let request = self.configurationRequestRevision
                let loaded = await self.load(location: location, preservingOperationStatus: true)
                guard reloadRevision == self.configurationReloadRevision else { return }
                if loaded {
                    self.configurationRetryFailures = 0
                } else if request == self.configurationRequestRevision, self.location == location {
                    self.pendingConfigurationLocation = location
                    if !self.busy { self.scheduleConfigurationRetry() }
                    break
                }
            }
            guard reloadRevision == self.configurationReloadRevision else { return }
            self.configurationReloadTask = nil
            self.scheduleConfigurationReload()
        }
    }

    private var canReloadConfiguration: Bool { monitoringAvailable && !busy && !connectionTesting && fetchingModelsFor == nil }

    private func cancelConfigurationRetry() {
        configurationRetryRevision += 1
        configurationRetryTask?.cancel(); configurationRetryTask = nil
        configurationRetryFailures = 0
    }

    private func scheduleConfigurationRetry() {
        guard configurationRetryTask == nil else { return }
        configurationRetryFailures += 1
        let delays = [5, 15, 30, 60]
        let delay = delays[min(configurationRetryFailures - 1, delays.count - 1)]
        let version = configurationRetryRevision, clock = configurationClock
        configurationRetryTask = Task { [weak self, clock] in
            do { try await clock.sleep(.seconds(delay)) } catch { return }
            guard let self, !Task.isCancelled, version == self.configurationRetryRevision else { return }
            self.configurationRetryTask = nil
            self.scheduleConfigurationReload()
        }
    }

    @discardableResult
    func load(location newLocation: CodexLocation, preservingOperationStatus: Bool = false) async -> Bool {
        guard !isPreview, monitoringAvailable else { return false }
        let request = configurationRequestRevision
        if !preservingOperationStatus { cancelConfigurationRetry() }
        if location != newLocation {
            // A direct location change supersedes a queued reload of the old home.
            if pendingConfigurationLocation != newLocation { pendingConfigurationLocation = nil }
            cancelModelDiscovery()
            generation += 1
            workspaceBaseline = nil; cancelConnectionTest()
            location = newLocation
            library = ModelProfileLibrary(); snapshot = nil
            writesSupported = false; error = nil; message = nil; busy = false
            applyErrors = [:]; showUnverifiedPrompt = false
            pendingNavigation = nil; showUnsavedPrompt = false
            configurationReloadError = nil
            providerDraft = nil; apiKeyInput = ""; providerKeyAvailable = [:]; providerKeyIssues = [:]; credentialCommandsSupported = false
            providerModelCaches = [:]
            configurationFailure = nil
        }
        guard !busy else { return false }
        let version = generation
        busy = true
        defer { if generation == version { busy = false } }
        do {
            let local = try await service.library(home: newLocation.home)
            guard version == generation else { return false }
            library = local
            providerModelCaches = try await service.cachedModels(home: newLocation.home)
            guard version == generation else { return false }
            let context = try await service.read(location: newLocation)
            guard version == generation else { return false }
            accept(context)
            let supportsCredentials = await service.supportsCredentialCommands(location: newLocation)
            guard version == generation, monitoringAvailable else { return false }
            credentialCommandsSupported = supportsCredentials
            await refreshProviderKeys()
            guard version == generation, monitoringAvailable else { return false }
            writesSupported = context.library.pending == nil
            configurationFailure = context.recoveryIssue
            if preservingOperationStatus {
                configurationReloadError = context.recoveryIssue?.localizedDescription
                if foregroundLoadError != nil { error = nil }
                refreshCleanWorkspace()
            } else {
                configurationReloadError = nil
                error = context.recoveryIssue?.localizedDescription
                if workspaceBaseline == nil || !hasUnsavedChanges { chooseWorkspaceImmediately(workspaceSelection) }
                if request == configurationRequestRevision, pendingConfigurationLocation == newLocation {
                    pendingConfigurationLocation = nil
                }
            }
            return true
        } catch {
            guard version == generation else { return false }
            writesSupported = false
            configurationFailure = (error as? ModelProfileFailure) ?? .unavailable
            if preservingOperationStatus {
                configurationReloadError = safeMessage(error)
            } else {
                configurationReloadError = nil
                foregroundLoadError = safeMessage(error)
                self.error = foregroundLoadError
                if request == configurationRequestRevision {
                    pendingConfigurationLocation = newLocation
                    scheduleConfigurationRetry()
                }
            }
            return false
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
        let version = generation
        if save {
            let saved = await saveWorkspace()
            guard version == generation else { return }
            if !saved { pendingNavigation = nil; showUnsavedPrompt = false; return }
        }
        if !save {
            invalidContextInput = false; providerDraft = workspaceBaseline; apiKeyInput = ""
        }
        let action = pendingNavigation
        pendingNavigation = nil
        showUnsavedPrompt = false
        action?()
    }

    func cancelNavigation() { pendingNavigation = nil; showUnsavedPrompt = false }

    func apply(_ profile: CodexModelProfile) async {
        guard !busy, writesSupported, let location, let snapshot else { return }
        if profile.kind == .custom && profile.authentication == .environment { error = CredentialFailure.missing.localizedDescription; return }
        await update(location: location) {
            try await self.service.apply(profile, location: location, expectedVersion: snapshot.version)
        }
    }

    private func update(location: CodexLocation,
                        operation: () async throws -> ModelProfileContext) async {
        let version = generation
        busy = true; error = nil; message = nil
        defer { if version == generation { busy = false } }
        do {
            if isPreview { message = L10n.text("Preview only. Codex configuration was not changed."); return }
            let context = try await operation()
            guard version == generation else { return }
            accept(context)
            message = L10n.text("Set as the default provider for new sessions. Restart open Codex clients if needed.")
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
            library.providers.contains { $0.id == preset.id && $0.validation.isEmpty && $0.credential != nil && !connectionIsBlocked($0) }
                && providerKeyAvailable[preset.id] == true
                && library.providers.first(where: { $0.id == preset.id }).map { settings in
                    providerModelCaches[preset.id].map { $0.scope == ProviderModelScope(settings) && $0.contains(settings.model) } == true
                } == true
        }
    }
    private func refreshProviderKeys() async {
        guard !isPreview, monitoringAvailable else { return }
        providerKeyAvailable = [:]; providerKeyIssues = [:]
        let version = generation
        var available: [String: Bool] = [:], issues: [String: String] = [:]
        for settings in library.connections {
            guard version == generation, monitoringAvailable else { return }
            guard let reference = settings.credential else { continue }
            do { available[settings.id] = try await service.hasCredential(reference) }
            catch { issues[settings.id] = safeMessage(error) }
        }
        guard version == generation, monitoringAvailable else { return }
        providerKeyAvailable = available; providerKeyIssues = issues
    }

    func cancelModelDiscovery() {
        modelGeneration += 1; modelRequest?.cancel(); modelRequest = nil; fetchingModelsFor = nil
    }
    func applyPreset(_ id: String) async {
        guard !busy, writesSupported, credentialCommandsSupported, let location, let snapshot else { return }
        let version = generation
        await update(location: location) { try await self.service.applyProvider(id, location: location, expectedVersion: snapshot.version) }
        guard version == generation else { return }
        await refreshProviderKeys()
    }
    func restoreOpenAI() async {
        guard !busy, writesSupported, let location, let snapshot else { return }
        await update(location: location) { try await self.service.restoreOpenAI(location: location, expectedVersion: snapshot.version) }
    }
    private func accept(_ context: ModelProfileContext) {
        library = context.library; snapshot = context.snapshot
        configurationChanged()
        if context.library.pending != nil { writesSupported = false; configurationFailure = context.recoveryIssue ?? .changed }
    }
    private func safeMessage(_ error: Error) -> String {
        if let failure = error as? CredentialFailure { return failure.localizedDescription }
        if let failure = error as? ModelDiscoveryFailure { return failure.localizedDescription }
        if let failure = error as? ProviderConnectionFailure { return failure.localizedDescription }
        return ((error as? ModelProfileFailure) ?? .unavailable).localizedDescription
    }

    var customConnections: [ProviderDescriptor] { library.connections.filter { $0.origin == .custom } }
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
        if connectionResult?.failure?.blocksApply == true { return false }
        if apiKeyInput.isEmpty, let cache = providerModelCaches[value.id], cache.scope == ProviderModelScope(value), cache.failure == .authentication { return false }
        if value.origin == .builtin && value.id != "openai" {
            return !apiKeyInput.isEmpty || providerModelCaches[value.id]?.contains(value.model) == true
        }
        return true
    }
    func chooseConnectionForAction(_ id: String) { chooseWorkspaceImmediately(.connection(id)) }
    func reloadWorkspace(location: CodexLocation) async {
        await load(location: location)
    }
    func activateWorkspace() {
        guard !workspaceEnabled else { return }
        workspaceEnabled = true
        chooseWorkspaceImmediately(workspaceSelection)
    }
    func chooseWorkspace(_ selection: ProviderWorkspaceSelection) {
        navigate { self.chooseWorkspaceImmediately(selection) }
    }
    private func chooseWorkspaceImmediately(_ selection: ProviderWorkspaceSelection) {
        cancelModelDiscovery(); cancelConnectionTest()
        editorRevision += 1
        workspaceSelection = selection; apiKeyInput = ""; replacingKey = false; confirmedEndpoint = false
        error = nil; message = nil; attemptedValidation = false
        providerDraft = workspaceValue(for: selection)
        workspaceBaseline = providerDraft; editStatus = .clean; invalidContextInput = false
    }

    /// A passive config refresh updates clean saved data, without navigating or
    /// clearing editor choices, operation feedback, or unchanged active requests.
    private func refreshCleanWorkspace() {
        guard workspaceBaseline == nil || !hasUnsavedChanges else { return }
        let updated = workspaceValue(for: workspaceSelection)
        guard updated != providerDraft else { return }
        let status = editStatus
        if updated?.baseURL != providerDraft?.baseURL { confirmedEndpoint = false }
        providerDraft = updated
        workspaceBaseline = updated
        editStatus = status
        editorRevision += 1
    }

    private func workspaceValue(for selection: ProviderWorkspaceSelection) -> ProviderSettings? {
        switch selection {
        case .official:
            if let saved = library.connections.first(where: { $0.id == "openai" }) { return saved }
            else {
                let model = library.openAISnapshot?.first { $0.keyPath == "model" }?.value.string
                    ?? (snapshot?.providerIdentity.isOfficial == true ? snapshot?.user["model"].string : nil) ?? ""
                let reasoning = library.openAISnapshot?.first { $0.keyPath == "model_reasoning_effort" }?.value.string
                    ?? (snapshot?.providerIdentity.isOfficial == true ? snapshot?.user["model_reasoning_effort"].string : nil) ?? ""
                let catalog = library.openAISnapshot?.first { $0.keyPath == "model_catalog_json" }?.value.string
                    ?? (snapshot?.providerIdentity.isOfficial == true ? snapshot?.user["model_catalog_json"].string : nil) ?? ""
                var value = ProviderSettings(profile: CodexModelProfile(id: UUID(uuidString: "62141F01-A521-4ECC-BF32-000000000000")!, name: "OpenAI", model: model, reasoning: reasoning, catalogPath: catalog))
                value.id = "openai"; return value
            }
        case .connection(let id):
            return library.connections.first { $0.id == id }
                ?? ProviderPreset.find(id).map(ProviderSettings.init(preset:))
        case .create: return ProviderSettings(name: "")
        }
    }
    func cancelWorkspaceEdits() {
        cancelModelDiscovery(); cancelConnectionTest(); apiKeyInput = ""; replacingKey = false; confirmedEndpoint = false
        if workspaceSelection == .create { chooseWorkspaceImmediately(.official) }
        else { invalidContextInput = false; providerDraft = workspaceBaseline; attemptedValidation = false; error = nil; message = nil; editorRevision += 1 }
    }
    func useResponsesProtocol() {
        guard !busy, let value = providerDraft, value.isManagedEndpoint, value.protocolName != "responses" else { return }
        providerDraft?.wireAPI = "responses"
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
        guard !Task.isCancelled else { return }
        guard canApplyWorkspace, let targetID = providerDraft?.id else { attemptedValidation = true; return }
        let version = generation, revision = editorRevision
        if hasUnsavedChanges || savedConnection == nil { guard await saveWorkspace() else { return } }
        guard !Task.isCancelled, version == generation, revision == editorRevision,
              let value = providerDraft, value.id == targetID else { return }
        if value.origin == .builtin && value.id != "openai", providerModelCaches[value.id]?.scope != ProviderModelScope(value) || providerModelCaches[value.id]?.contains(value.model) != true {
            let requestVersion = await refreshWorkspaceModels()
            // A cancelled refresh must not resume Apply against a newer selection or draft.
            guard requestVersion == modelGeneration, !Task.isCancelled, version == generation, revision == editorRevision,
                  providerDraft == value else { return }
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
        let version = generation
        await update(location: location) { try await self.service.applyProvider(value.id, location: location, expectedVersion: snapshot.version) }
        guard version == generation else { return }
        if let error { applyErrors[value.id] = error; self.error = L10n.text("Provider saved, but applying failed.") + " " + error }
        else { applyErrors[value.id] = nil }
    }
    func repairWorkspacePath() async {
        guard let value = savedConnection, let location, let snapshot, !busy else { return }
        let version = generation
        await update(location: location) { try await self.service.repairCredentialPath(value.id, location: location, expectedVersion: snapshot.version) }
        guard version == generation else { return }
        if error == nil && !isPreview { message = L10n.text("Credential path repaired. Model settings were not changed.") }
    }
    func cancelConnectionTest() {
        connectionGeneration += 1; connectionRequest?.cancel(); connectionRequest = nil; connectionTesting = false
    }
    /// Returns the accepted request version, or nil for cancellation, stale results, or failure.
    @discardableResult
    func refreshWorkspaceModels() async -> Int? {
        guard !Task.isCancelled, !busy, !hasUnsavedChanges, let saved = savedConnection, let location else { return nil }
        cancelModelDiscovery(); let token = modelGeneration; let version = generation
        fetchingModelsFor = saved.id
        let request = Task {
            if isPreview, let scope = ProviderModelScope(saved) { return ProviderModelCache(scope: scope, models: Self.previewModels, fetchedAt: Date()) }
            return try await service.fetchProviderModels(saved.id, home: location.home)
        }
        modelRequest = request
        defer { if token == modelGeneration { fetchingModelsFor = nil; modelRequest = nil } }
        do {
            let cache = try await withTaskCancellationHandler {
                try await request.value
            } onCancel: {
                request.cancel()
            }
            guard !Task.isCancelled, token == modelGeneration, version == generation, providerDraft?.id == saved.id else { return nil }
            providerModelCaches[saved.id] = cache
            if let failure = cache.failure { error = failure.localizedDescription } else { error = nil }
            return token
        } catch {
            if !(error is CancellationError), !Task.isCancelled, token == modelGeneration { self.error = safeMessage(error) }
            return nil
        }
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
            // The test persists only connectivity; edits made while it ran remain unsaved.
            workspaceBaseline?.connectivity = result
            providerDraft?.connectivity = result
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
    func deleteWorkspace(replacementID: String? = nil) async {
        guard let value = savedConnection, value.origin == .custom, let location, !busy else { return }
        let version = generation
        if isDefaultConnection(value) {
            guard let replacementID else { return }
            if replacementID == "openai" { await restoreOpenAI() }
            else if let snapshot { await update(location: location) { try await self.service.applyProvider(replacementID, location: location, expectedVersion: snapshot.version) } }
            guard version == generation, error == nil else { return }
            if value.legacyProfile?.kind != .official, isDefaultConnection(value) { return }
        }
        busy = true
        defer { if version == generation { busy = false } }
        do {
            if isPreview { library.connections.removeAll { $0.id == value.id } }
            else {
                let updated = try await service.deleteConnection(value.id, location: location)
                guard version == generation else { return }
                library = updated
            }
            chooseWorkspaceImmediately(.official)
        } catch { if version == generation { self.error = safeMessage(error) } }
    }
    func removeWorkspaceKey() async {
        guard let value = savedConnection, let location, !busy else { return }
        let version = generation
        busy = true; defer { if version == generation { busy = false } }
        do {
            if isPreview { providerKeyAvailable[value.id] = false; library.connections.removeAll { $0.id == value.id }; var updated = value; updated.credential = nil; library.connections.append(updated) }
            else {
                let updated = try await service.removeProviderKey(value.id, location: location)
                guard version == generation else { return }
                library = updated
                await refreshProviderKeys()
                guard version == generation else { return }
            }
            chooseWorkspaceImmediately(workspaceSelection)
        } catch { if version == generation { self.error = safeMessage(error) } }
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
        store.isPreview = true; store.writesSupported = true; store.tab = .models; store.credentialCommandsSupported = true
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
        store.workspaceSelection = .connection("legacy:" + custom.id.uuidString.lowercased())
        if scenario == "empty" { store.workspaceSelection = .connection("deepseek") }
        store.activateWorkspace()
        if scenario == "error" { store.error = ModelProfileFailure.unsupported.localizedDescription; store.writesSupported = false }
        if scenario == "invalid" { store.providerDraft?.baseURL = "invalid"; store.attemptedValidation = true }
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
        }
        if scenario == "provider-unavailable" {
            store.snapshot = nil; store.writesSupported = false
            store.error = ModelProfileFailure.unavailable.localizedDescription
        }
        if scenario == "provider-overridden" { store.snapshot?.overridden = true }
        if scenario == "provider-busy" { store.busy = true }
        if scenario.hasPrefix("preset") {
            let preset = ProviderPreset.all[0]
            var settings = ProviderSettings(preset: preset)
            if scenario != "preset-empty" { settings.model = Self.previewModels[0].id }
            if scenario != "preset-empty" { settings.credential = CredentialReference(); store.library.providers = [settings]; store.providerKeyAvailable[preset.id] = true }
            store.chooseWorkspaceImmediately(.connection(preset.id))
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
            if scenario == "preset-dirty" { store.replacingKey = true; store.apiKeyInput = "fixture-input-only" }
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

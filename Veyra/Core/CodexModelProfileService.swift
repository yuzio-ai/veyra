import Foundation
import CryptoKit
import Darwin

struct ModelProfileContext: Sendable {
    var library: ModelProfileLibrary
    var snapshot: CodexConfigSnapshot
    var recoveryIssue: ModelProfileFailure?
}

actor CodexModelProfileService {
    private let transport: any CodexModelConfigurationTransport
    private let root: URL
    private var operating = false
    private let credentials: any CredentialStore
    let helperExecutable: URL
    private let capability: @Sendable (URL?) -> Bool
    private let modelClient: any ProviderModelClient
    private let connectivityClient: any ProviderConnectivityClient
    private var modelCaches: [URL: ProviderModelCache] = [:]

    init(transport: any CodexModelConfigurationTransport = AppServerClient(), root: URL? = nil,
         credentials: any CredentialStore = KeychainCredentialStore(),
         helperExecutable: URL = Bundle.main.executableURL ?? URL(fileURLWithPath: "/Applications/Veyra.app/Contents/MacOS/Veyra"),
         capability: @escaping @Sendable (URL?) -> Bool = { ProviderCredentialCapability.supported(executable: $0) },
         modelClient: any ProviderModelClient = URLSessionProviderModelClient(),
         connectivityClient: any ProviderConnectivityClient = URLSessionProviderConnectivityClient()) {
        self.transport = transport; self.credentials = credentials; self.helperExecutable = helperExecutable; self.capability = capability
        self.modelClient = modelClient; self.connectivityClient = connectivityClient
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Veyra/ModelProfiles", isDirectory: true)
    }

    func libraryURL(home: URL) -> URL {
        let path = home.resolvingSymlinksInPath().standardizedFileURL.path
        let key = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(key, isDirectory: true).appendingPathComponent("profiles.json")
    }

    func library(home: URL) throws -> ModelProfileLibrary {
        let url = libraryURL(home: home)
        guard FileManager.default.fileExists(atPath: url.path) else { return ModelProfileLibrary() }
        do {
            var value = try JSONDecoder().decode(ModelProfileLibrary.self, from: Data(contentsOf: url))
            guard [1, 2, 3].contains(value.schemaVersion) else { throw ModelProfileFailure.storage }
            value.schemaVersion = 3
            return value
        } catch { throw ModelProfileFailure.storage }
    }

    private func persist(_ library: ModelProfileLibrary, home: URL) throws {
        do {
            let url = libraryURL(home: home)
            let files = FileManager.default
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            // Atomic replacement; file protection is established before data is written.
            let temporary = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".tmp")
            defer { try? files.removeItem(at: temporary) }
            guard files.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw ModelProfileFailure.storage
            }
            let data = try encoder.encode(library)
            guard try JSONDecoder().decode(ModelProfileLibrary.self, from: data) == library else { throw ModelProfileFailure.storage }
            if files.fileExists(atPath: url.path), let old = try? Data(contentsOf: url),
               let schema = try? JSONValue.decode(old)["schemaVersion"].integer, schema < 3 {
                let backup = url.deletingLastPathComponent().appendingPathComponent("profiles-schema-\(schema).backup.json")
                if !files.fileExists(atPath: backup.path) {
                    guard files.createFile(atPath: backup.path, contents: old, attributes: [.posixPermissions: 0o600]) else { throw ModelProfileFailure.storage }
                }
            }
            let handle = try FileHandle(forWritingTo: temporary)
            do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
            catch { try? handle.close(); throw error }
            if files.fileExists(atPath: url.path) {
                let kind = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard kind.isRegularFile == true, kind.isSymbolicLink != true else { throw ModelProfileFailure.storage }
                _ = try files.replaceItemAt(url, withItemAt: temporary)
            } else { try files.moveItem(at: temporary, to: url) }
        } catch { throw ModelProfileFailure.storage }
    }

    func saveProfiles(_ profiles: [CodexModelProfile], home: URL) throws -> ModelProfileLibrary {
        guard !operating else { throw ModelProfileFailure.busy }
        guard profiles.allSatisfy({ $0.validation.isEmpty }) else { throw ModelProfileFailure.invalid }
        let lock = try acquire(home: home); defer { release(lock) }
        var value = try library(home: home)
        value.profiles = profiles.map { $0.normalized() }
        try persist(value, home: home)
        return value
    }

    func read(location: CodexLocation) async throws -> ModelProfileContext {
        guard !operating else { throw ModelProfileFailure.busy }
        operating = true
        defer { operating = false }
        let lock = try acquire(home: location.home); defer { release(lock) }
        var value = try library(home: location.home)
        let file = libraryURL(home: location.home)
        if let data = try? Data(contentsOf: file), (try? JSONValue.decode(data)["schemaVersion"].integer) != 3 {
            try persist(value, home: location.home)
        }
        let snapshot = try await transport.readConfiguration(location: location)
        let issue = try reconcile(&value, snapshot: snapshot, home: location.home)
        return ModelProfileContext(library: value, snapshot: snapshot, recoveryIssue: issue)
    }

    /// Only touched values enter the journal. Whole config files and provider auth are never copied.
    func apply(_ profile: CodexModelProfile, location: CodexLocation, expectedVersion: String) async throws -> ModelProfileContext {
        guard !operating else { throw ModelProfileFailure.busy }
        operating = true
        defer { operating = false }
        let lock = try acquire(home: location.home); defer { release(lock) }
        var library = try library(home: location.home)
        let snapshot = try await transport.readConfiguration(location: location)
        _ = try reconcile(&library, snapshot: snapshot, home: location.home)
        guard library.pending == nil else { throw ModelProfileFailure.changed }
        guard snapshot.version == expectedVersion else { throw ModelProfileFailure.conflict }
        var profile = profile
        if profile.authentication == .keychain {
            profile.helperPath = helperExecutable.path
            guard capability(location.executable), let reference = profile.credentialReference,
                  try credentials.contains(reference) else { throw CredentialFailure.missing }
        }
        var edits = try ModelProfilePatch.edits(for: profile.normalized(), snapshot: snapshot)
        if profile.kind == .official {
            let base = Set(edits.map(\.keyPath))
            edits += Self.globalKeys.filter { !base.contains($0) && !Self.originalKeys.contains($0) }.map { key in
                CodexConfigEdit(keyPath: key, value: library.openAISnapshot?.first { $0.keyPath == key }?.value ?? .null)
            }.filter { snapshot.value(at: $0.keyPath) != $0.value }
        }
        guard !edits.isEmpty else { return ModelProfileContext(library: library, snapshot: snapshot) }
        if profile.kind == .custom && library.openAISnapshot == nil && snapshot.configuredProviderID == "openai" && snapshot.configuredOpenAIBaseURL == nil {
            library.openAISnapshot = Self.globalKeys.map { CodexConfigEdit(keyPath: $0, value: snapshot.value(at: $0)) }
        }
        let inverse = edits.map { CodexConfigEdit(keyPath: $0.keyPath, value: snapshot.value(at: $0.keyPath)) }
        return try await transact(ModelProfileJournal(before: inverse, after: edits), library: library,
                                  snapshot: snapshot, location: location)
    }

    func undo(location: CodexLocation) async throws -> ModelProfileContext {
        guard !operating else { throw ModelProfileFailure.busy }
        operating = true
        defer { operating = false }
        let lock = try acquire(home: location.home); defer { release(lock) }
        var library = try library(home: location.home)
        let snapshot = try await transport.readConfiguration(location: location)
        _ = try reconcile(&library, snapshot: snapshot, home: location.home)
        guard library.pending == nil else { throw ModelProfileFailure.changed }
        guard let journal = library.journal, ModelProfilePatch.matches(journal.after, snapshot: snapshot) else {
            throw ModelProfileFailure.changed
        }
        let providerIDs = journal.before.filter { $0.keyPath == "model_provider" }.compactMap { $0.value.string }
        let dependencies = journal.before.map(\.value)
            + providerIDs.flatMap { [snapshot.user["model_providers"][$0], snapshot.effective["model_providers"][$0]] }
        for reference in Set(dependencies.flatMap(Self.credentialReferences)) {
            guard try credentials.contains(reference) else { throw CredentialFailure.missing }
        }
        return try await transact(ModelProfileJournal(before: journal.after, after: journal.before, isUndo: true),
                                  library: library, snapshot: snapshot, location: location)
    }

    static let originalKeys = ["model", "model_provider", "model_reasoning_effort", "model_catalog_json", "openai_base_url"]
    static let globalKeys = originalKeys + ["model_context_window", "model_supports_reasoning_summaries", "model_reasoning_summary",
        "service_tier", "preferred_auth_method", "forced_login_method", "web_search"]

    func supportsCredentialCommands(location: CodexLocation) -> Bool { capability(location.executable) }
    func hasCredential(_ reference: CredentialReference) throws -> Bool { try credentials.contains(reference) }

    private func cacheURL(scope: ProviderModelScope, home: URL) throws -> URL {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let hash = SHA256.hash(data: try encoder.encode(scope)).map { String(format: "%02x", $0) }.joined()
        return libraryURL(home: home).deletingLastPathComponent().appendingPathComponent("model-cache/" + hash + ".json")
    }

    private func cachedModels(settings: ProviderSettings, home: URL) throws -> ProviderModelCache? {
        guard let scope = ProviderModelScope(settings) else { return nil }
        let file = try cacheURL(scope: scope, home: home)
        if let value = modelCaches[file] { return value }
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        do {
            let data = try Data(contentsOf: file)
            guard data.count <= 4 * 1024 * 1024 else { throw ModelDiscoveryFailure.storage }
            let cache = try JSONDecoder().decode(ProviderModelCache.self, from: data)
            guard cache.scope == scope, cache.models.allSatisfy({ DiscoveredModel.validToken($0.id) }),
                  Set(cache.models.map(\.id)).count == cache.models.count else { throw ModelDiscoveryFailure.storage }
            return cache
        } catch {
            // A missing/unreadable/obsolete cache never hides the saved connection or Key.
            // Treat it as unfetched: enabling stays blocked until a fresh authenticated list succeeds.
            return nil
        }
    }

    func cachedModels(home: URL) throws -> [String: ProviderModelCache] {
        var result: [String: ProviderModelCache] = [:]
        for settings in try library(home: home).connections {
            if let cache = try cachedModels(settings: settings, home: home) { result[settings.id] = cache }
        }
        return result
    }

    /// The network await holds no filesystem lock. A changed/deleted connection or cancellation
    /// invalidates its result before it can replace a cache, including authentication failures.
    func fetchProviderModels(_ id: String, home: URL) async throws -> ProviderModelCache {
        guard let settings = try library(home: home).connections.first(where: { $0.id == id }),
              let scope = ProviderModelScope(settings) else { throw CredentialFailure.missing }
        var cache = try cachedModels(settings: settings, home: home) ?? ProviderModelCache(scope: scope)
        let key = try scope.credential.map { try credentials.read($0) }
        do {
            let models = try await modelClient.models(provider: settings, key: key)
            try Task.checkCancellation()
            cache.models = models; cache.fetchedAt = Date(); cache.failure = nil
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            cache.failure = ModelDiscoveryFailure.safe(error)
        }
        try Task.checkCancellation()
        let lock = try acquire(home: home); defer { release(lock) }
        guard let current = try library(home: home).connections.first(where: { $0.id == id }),
              ProviderModelScope(current) == scope else { throw CancellationError() }
        let file = try cacheURL(scope: scope, home: home)
        modelCaches[file] = cache
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if FileManager.default.fileExists(atPath: file.path) {
                let kind = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard kind.isRegularFile == true, kind.isSymbolicLink != true else { throw ModelDiscoveryFailure.storage }
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(cache).write(to: file, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { throw ModelDiscoveryFailure.storage }
        return cache
    }

    func saveProvider(_ settings: ProviderSettings, newKey: String?, home: URL, confirmedAddress: Bool = false) throws -> ModelProfileLibrary {
        guard !operating else { throw ModelProfileFailure.busy }
        guard settings.validation.isEmpty else { throw ModelProfileFailure.invalid }
        let lock = try acquire(home: home); defer { release(lock) }
        var library = try library(home: home)
        var saved = settings
        if newKey != nil && saved.authMode != .keychain { throw ModelProfileFailure.invalid }
        let previous = library.connections.first { $0.id == settings.id }
        if newKey == nil, previous?.credential != settings.credential { throw ModelProfileFailure.conflict }
        saved.retiredCredentials = previous?.retiredCredentials
        if let previous = library.connections.first(where: { $0.id == settings.id }), previous.baseURL != settings.baseURL,
           newKey == nil, saved.authMode == .keychain, !confirmedAddress { throw CredentialFailure.missing }
        var inserted: CredentialReference?
        if let newKey {
            let reference = CredentialReference()
            try credentials.save(newKey, reference: reference)
            if let previousReference = previous?.credential {
                saved.retiredCredentials = (saved.retiredCredentials ?? []) + [previousReference]
            }
            saved.credential = reference; inserted = reference
        } else if let reference = saved.credential, !(try credentials.contains(reference)) { throw CredentialFailure.missing }
        guard saved.authMode != .keychain || saved.credential != nil else { throw CredentialFailure.missing }
        if var legacy = saved.legacyValue {
            if saved.authMode == .keychain { legacy.helperPath = helperExecutable.path; legacy.environmentKey = "" }
            saved.legacyProfile = legacy
        }
        if let previous, ProviderModelScope(previous) != ProviderModelScope(saved) || previous.model != saved.model || previous.protocolName != saved.protocolName { saved.connectivity = nil }
        library.connections.removeAll { $0.id == saved.id }; library.connections.append(saved)
        do { try persist(library, home: home) }
        catch { if let inserted { try? credentials.remove(inserted) }; throw error }
        return library
    }

    func saveLegacyKey(_ profile: CodexModelProfile, newKey: String, home: URL) throws -> ModelProfileLibrary {
        guard !operating, profile.kind == .custom else { throw ModelProfileFailure.busy }
        let lock = try acquire(home: home); defer { release(lock) }
        var library = try library(home: home)
        let reference = CredentialReference()
        var saved = profile.normalized()
        saved.authentication = .keychain; saved.environmentKey = ""; saved.credentialReference = reference
        saved.helperPath = helperExecutable.path
        guard saved.validation.isEmpty else { throw ModelProfileFailure.invalid }
        try credentials.save(newKey, reference: reference)
        if let index = library.profiles.firstIndex(where: { $0.id == saved.id }) { library.profiles[index] = saved }
        else { library.profiles.append(saved) }
        do { try persist(library, home: home) }
        catch { try? credentials.remove(reference); throw error }
        return library
    }

    func applyProvider(_ id: String, location: CodexLocation, expectedVersion: String) async throws -> ModelProfileContext {
        guard !operating else { throw ModelProfileFailure.busy }
        operating = true; defer { operating = false }
        let lock = try acquire(home: location.home); defer { release(lock) }
        var library = try library(home: location.home)
        guard let settings = library.connections.first(where: { $0.id == id }) else { throw ModelProfileFailure.invalid }
        if settings.authMode == .keychain && settings.isManagedEndpoint {
            guard capability(location.executable) else { throw ModelProfileFailure.unsupported }
            guard let reference = settings.credential, try credentials.contains(reference) else { throw CredentialFailure.missing }
        }
        guard settings.protocolName == "responses", settings.connectivity?.matches(settings) != true || settings.connectivity?.failure != .incompatible else { throw ProviderConnectionFailure.incompatible }
        let preset = settings.modelAdapter
        let snapshot = try await transport.readConfiguration(location: location)
        _ = try reconcile(&library, snapshot: snapshot, home: location.home)
        guard library.pending == nil else { throw ModelProfileFailure.changed }
        guard snapshot.version == expectedVersion else { throw ModelProfileFailure.conflict }
        if settings.legacyProfile != nil {
            let profile = try settings.profile(helper: helperExecutable)
            var edits = try ModelProfilePatch.edits(for: profile, snapshot: snapshot)
            if profile.kind == .official {
                let existing = Set(edits.map(\.keyPath))
                edits += Self.globalKeys.filter { !existing.contains($0) && !Self.originalKeys.contains($0) }.map { key in
                    CodexConfigEdit(keyPath: key, value: library.openAISnapshot?.first { $0.keyPath == key }?.value ?? .null)
                }.filter { snapshot.value(at: $0.keyPath) != $0.value }
            }
            if edits.isEmpty { return ModelProfileContext(library: library, snapshot: snapshot) }
            if profile.kind == .custom, library.openAISnapshot == nil,
               snapshot.configuredProviderID == "openai", snapshot.configuredOpenAIBaseURL == nil {
                library.openAISnapshot = Self.globalKeys.map { CodexConfigEdit(keyPath: $0, value: snapshot.value(at: $0)) }
            }
            return try await transact(ModelProfileJournal(before: edits.map { CodexConfigEdit(keyPath: $0.keyPath, value: snapshot.value(at: $0.keyPath)) }, after: edits), library: library, snapshot: snapshot, location: location)
        }
        let cache = try cachedModels(settings: settings, home: location.home)
        guard settings.validation.isEmpty else { throw ModelProfileFailure.invalid }
        if cache?.failure == .authentication { throw ModelDiscoveryFailure.authentication }
        if settings.origin == .builtin, cache?.contains(settings.model) != true { throw ModelDiscoveryFailure.unavailable }
        if let levels = cache?.models.first(where: { $0.id == settings.model })?.reasoningLevels,
           !settings.reasoning.isEmpty, !levels.contains(settings.reasoning) { throw ModelProfileFailure.invalid }
        let models = cache?.models.contains(where: { $0.id == settings.model }) == true ? cache!.models : [DiscoveredModel(id: settings.model)]
        let catalog = ProviderRuntimeCatalog.build(models: models, preset: preset, settings: settings)
        let folder = libraryURL(home: location.home).deletingLastPathComponent().appendingPathComponent("catalogs/discovered-v1")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(catalog)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let file = folder.appendingPathComponent(hash + ".json")
        // Catalogs are immutable/versioned; existing undo references never change under them.
        if FileManager.default.fileExists(atPath: file.path) {
            guard try Data(contentsOf: file) == data else { throw ModelProfileFailure.storage }
        } else {
            try data.write(to: file, options: [.atomic]); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        let profile = try settings.profile(helper: helperExecutable, catalogPath: file.path,
                                           discoveredModel: cache?.models.first { $0.id == settings.model })
        let edits = try ModelProfilePatch.edits(for: profile, snapshot: snapshot)
        if library.openAISnapshot == nil, snapshot.configuredProviderID == "openai", snapshot.configuredOpenAIBaseURL == nil {
            library.openAISnapshot = Self.globalKeys.map { CodexConfigEdit(keyPath: $0, value: snapshot.value(at: $0)) }
        }
        guard !edits.isEmpty else { return ModelProfileContext(library: library, snapshot: snapshot) }
        return try await transact(ModelProfileJournal(before: edits.map { CodexConfigEdit(keyPath: $0.keyPath, value: snapshot.value(at: $0.keyPath)) }, after: edits),
                                  library: library, snapshot: snapshot, location: location)
    }

    func restoreOpenAI(location: CodexLocation, expectedVersion: String) async throws -> ModelProfileContext {
        guard !operating else { throw ModelProfileFailure.busy }
        operating = true; defer { operating = false }
        let lock = try acquire(home: location.home); defer { release(lock) }
        var library = try library(home: location.home)
        let snapshot = try await transport.readConfiguration(location: location)
        _ = try reconcile(&library, snapshot: snapshot, home: location.home)
        guard library.pending == nil else { throw ModelProfileFailure.changed }
        guard snapshot.version == expectedVersion else { throw ModelProfileFailure.conflict }
        let target = library.openAISnapshot ?? Self.globalKeys.map { CodexConfigEdit(keyPath: $0, value: $0 == "model_provider" ? .string("openai") : .null) }
        let edits = target.filter { snapshot.value(at: $0.keyPath) != $0.value }
        guard !edits.isEmpty else { return ModelProfileContext(library: library, snapshot: snapshot) }
        return try await transact(ModelProfileJournal(before: edits.map { CodexConfigEdit(keyPath: $0.keyPath, value: snapshot.value(at: $0.keyPath)) }, after: edits),
                                  library: library, snapshot: snapshot, location: location)
    }

    func discardUndo(home: URL) throws -> ModelProfileLibrary {
        guard !operating else { throw ModelProfileFailure.busy }
        let lock = try acquire(home: home); defer { release(lock) }
        var library = try library(home: home)
        guard library.pending == nil else { throw CredentialFailure.inUse }
        library.journal = nil; try persist(library, home: home); return library
    }

    func removeProviderKey(_ id: String, location: CodexLocation) async throws -> ModelProfileLibrary {
        guard !operating else { throw ModelProfileFailure.busy }
        operating = true; defer { operating = false }
        let lock = try acquire(home: location.home); defer { release(lock) }
        var library = try library(home: location.home)
        guard let index = library.connections.firstIndex(where: { $0.id == id }), let reference = library.connections[index].credential else { return library }
        let snapshot = try await transport.readConfiguration(location: location)
        let records = [library.journal, library.pending].compactMap { $0 }.flatMap { $0.before + $0.after }
        let dependencyIDs = records.filter { $0.keyPath == "model_provider" }.compactMap { $0.value.string }
        let effectiveID = snapshot.effective["model_provider"].string ?? "openai"
        let protected: [JSONValue] = [snapshot.configuredProvider, snapshot.effective["model_providers"][effectiveID]]
            + records.map(\.value)
            + dependencyIDs.flatMap { [snapshot.user["model_providers"][$0], snapshot.effective["model_providers"][$0]] }
        let references = [reference] + (library.connections[index].retiredCredentials ?? [])
        for key in references {
            guard !protected.contains(where: { Self.contains(key.argument, in: $0) }),
                  !library.connections.contains(where: { $0.id != id && ($0.credential == key || ($0.retiredCredentials ?? []).contains(key)) }) else { throw CredentialFailure.inUse }
        }
        // Remove the reference first. On metadata failure, the usable Key remains untouched.
        library.connections[index].credential = nil; library.connections[index].retiredCredentials = nil
        try persist(library, home: location.home)
        for key in references { try credentials.remove(key) }
        return library
    }

    func testConnection(_ id: String, home: URL) async throws -> ProviderConnectivityResult {
        guard let settings = try library(home: home).connections.first(where: { $0.id == id }),
              let scope = ProviderModelScope(settings) else { throw ModelProfileFailure.invalid }
        let key = try scope.credential.map { try credentials.read($0) }
        var result = ProviderConnectivityResult(scope: scope, model: settings.model, protocolName: settings.protocolName, date: Date())
        do { try await connectivityClient.test(provider: settings, key: key) }
        catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            result.failure = (error as? ProviderConnectionFailure) ?? .inconclusive
        }
        try Task.checkCancellation()
        let lock = try acquire(home: home); defer { release(lock) }
        var library = try library(home: home)
        guard let index = library.connections.firstIndex(where: { $0.id == id }), result.matches(library.connections[index]) else { throw CancellationError() }
        library.connections[index].connectivity = result
        try persist(library, home: home)
        return result
    }

    /// Repair is intentionally independent of the editor draft and default-model patch.
    func repairCredentialPath(_ id: String, location: CodexLocation, expectedVersion: String) async throws -> ModelProfileContext {
        guard !operating else { throw ModelProfileFailure.busy }
        operating = true; defer { operating = false }
        let lock = try acquire(home: location.home); defer { release(lock) }
        var library = try library(home: location.home)
        let snapshot = try await transport.readConfiguration(location: location)
        _ = try reconcile(&library, snapshot: snapshot, home: location.home)
        guard library.pending == nil else { throw ModelProfileFailure.changed }
        guard snapshot.version == expectedVersion else { throw ModelProfileFailure.conflict }
        guard capability(location.executable), let settings = library.connections.first(where: { $0.id == id }), settings.authMode == .keychain else { throw ModelProfileFailure.unsupported }
        let prefix = "model_providers." + settings.codexProviderID + ".auth"
        let auth = snapshot.value(at: prefix)
        guard let args = auth["args"].array, args.count == 2, args[0].string == "--provider-credential",
              let raw = args[1].string, let uuid = UUID(uuidString: raw),
              auth["command"].string?.hasSuffix("/Contents/MacOS/Veyra") == true else { throw ModelProfileFailure.changed }
        guard try credentials.contains(CredentialReference(id: uuid)) else { throw CredentialFailure.missing }
        let key = prefix + ".command"
        let edit = CodexConfigEdit(keyPath: key, value: .string(helperExecutable.path))
        if snapshot.value(at: key) == edit.value { return ModelProfileContext(library: library, snapshot: snapshot) }
        return try await transact(ModelProfileJournal(before: [CodexConfigEdit(keyPath: key, value: snapshot.value(at: key))], after: [edit]),
                                  library: library, snapshot: snapshot, location: location)
    }

    /// Deletion never deletes Codex definitions or credentials still needed by recovery.
    func deleteConnection(_ id: String, location: CodexLocation) async throws -> ModelProfileLibrary {
        guard !operating else { throw ModelProfileFailure.busy }
        operating = true; defer { operating = false }
        let lock = try acquire(home: location.home); defer { release(lock) }
        var library = try library(home: location.home)
        guard let target = library.connections.first(where: { $0.id == id }), target.origin == .custom else { throw ModelProfileFailure.invalid }
        let snapshot = try await transport.readConfiguration(location: location)
        if target.legacyProfile?.kind != .official {
            let matchesUser = target.legacyProfile?.kind == .reference
                ? target.legacyValue?.matchesProvider(snapshot) == true : snapshot.configuredProviderID == target.codexProviderID
            let effective = CodexConfigSnapshot(user: snapshot.effective, version: snapshot.version, file: snapshot.file)
            let matchesEffective = target.legacyProfile?.kind == .reference
                ? target.legacyValue?.matchesProvider(effective) == true : effective.configuredProviderID == target.codexProviderID
            guard !matchesUser && !matchesEffective else { throw CredentialFailure.inUse }
        }
        library.connections.removeAll { $0.id == id }
        // Credentials are retained if any config/undo record may still use them. Explicit Key removal
        // remains a separate protected action, so deleting a local row cannot break a saved session.
        try persist(library, home: location.home)
        return library
    }

    private static func credentialReferences(_ value: JSONValue) -> [CredentialReference] {
        if let items = value.array {
            if items.count == 2, items[0].string == "--provider-credential", let raw = items[1].string, let id = UUID(uuidString: raw) {
                return [CredentialReference(id: id)]
            }
            return items.flatMap(credentialReferences)
        }
        if let object = value.object { return object.values.flatMap(credentialReferences) }
        return []
    }
    private static func contains(_ reference: String, in value: JSONValue) -> Bool {
        switch value {
        case .string(let s): return s.lowercased() == reference
        case .object(let items): return items.values.contains { contains(reference, in: $0) }
        case .array(let items): return items.contains { contains(reference, in: $0) }
        default: return false
        }
    }
    private func acquire(home: URL) throws -> FileHandle {
        let folder = libraryURL(home: home).deletingLastPathComponent()
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { throw ModelProfileFailure.storage }
        let path = folder.appendingPathComponent("operation.lock").path
        let fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ModelProfileFailure.storage }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw ModelProfileFailure.busy }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    private func release(_ handle: FileHandle) { _ = flock(handle.fileDescriptor, LOCK_UN); try? handle.close() }

    private func transact(_ operation: ModelProfileJournal, library initial: ModelProfileLibrary,
                          snapshot: CodexConfigSnapshot, location: CodexLocation) async throws -> ModelProfileContext {
        try ModelProfilePatch.validateRecovery(operation.before + operation.after)
        var library = initial
        library.pending = operation
        try persist(library, home: location.home)
        var receipt: CodexConfigWriteReceipt?
        var writeError: Error?
        do {
            receipt = try await transport.writeConfiguration(location: location, edits: operation.after, expectedVersion: snapshot.version)
        } catch { writeError = error }
        // Also on timeout/disconnection: determine the disk outcome before allowing another write.
        var actual = try await transport.readConfiguration(location: location)
        if ModelProfilePatch.matches(operation.after, snapshot: actual) {
            actual.overridden = actual.overridden || receipt?.overridden == true
            _ = try reconcile(&library, snapshot: actual, home: location.home)
            return ModelProfileContext(library: library, snapshot: actual)
        }
        if ModelProfilePatch.matches(operation.before, snapshot: actual) {
            library.pending = nil
            try persist(library, home: location.home)
            throw (writeError as? ModelProfileFailure) ?? ModelProfileFailure.invalid
        }
        // A returned version proves this is still our own commit. Roll back only
        // target fields whose values are known; expectedVersion guards the inverse too.
        let knownValues = operation.after.allSatisfy { edit in
            let actualValue = actual.value(at: edit.keyPath)
            return actualValue == edit.value || actualValue == operation.before.first(where: { $0.keyPath == edit.keyPath })?.value
        }
        if let receipt, receipt.version == actual.version, knownValues {
            let inverse = operation.before.filter { actual.value(at: $0.keyPath) != $0.value }
            library.pending = ModelProfileJournal(before: inverse.map { CodexConfigEdit(keyPath: $0.keyPath, value: actual.value(at: $0.keyPath)) }, after: inverse, isUndo: true)
            try persist(library, home: location.home)
            do { _ = try await transport.writeConfiguration(location: location, edits: inverse, expectedVersion: actual.version) }
            catch { /* Read back before classifying a disconnected inverse write. */ }
            actual = try await transport.readConfiguration(location: location)
            if ModelProfilePatch.matches(operation.before, snapshot: actual) {
                library.pending = nil; library.journal = initial.journal
                try persist(library, home: location.home)
                throw ModelProfileFailure.invalid
            }
        }
        // A mixed or externally changed result must retain recovery evidence.
        throw ModelProfileFailure.conflict
    }

    @discardableResult
    private func reconcile(_ library: inout ModelProfileLibrary, snapshot: CodexConfigSnapshot,
                           home: URL) throws -> ModelProfileFailure? {
        guard var pending = library.pending else { return nil }
        if ModelProfilePatch.matches(pending.after, snapshot: snapshot) {
            pending.completed = true
            library.journal = pending.isUndo ? nil : pending
        } else if !ModelProfilePatch.matches(pending.before, snapshot: snapshot) {
            // Preserve both the operation and the previous Undo until the user repairs
            // the conflicting configuration. Never guess which process owns a value.
            return .changed
        }
        library.pending = nil
        try persist(library, home: home)
        return nil
    }
}

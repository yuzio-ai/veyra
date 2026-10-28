import Foundation
import XCTest

actor ConnectivityFixture: ProviderConnectivityClient {
    var failure: ProviderConnectionFailure?
    var suspended = false
    var calls = 0
    var keys: [String?] = []
    var continuations: [CheckedContinuation<Void, Error>] = []
    func configure(_ failure: ProviderConnectionFailure? = nil, suspended: Bool = false) { self.failure = failure; self.suspended = suspended }
    func test(provider: ProviderSettings, key: String?) async throws {
        calls += 1; keys.append(key)
        if suspended { try await withCheckedThrowingContinuation { continuations.append($0) } }
        if let failure { throw failure }
    }
    func resume() { let work = continuations; continuations = []; work.forEach { $0.resume() } }
}

final class ProviderSettingsV2Tests: XCTestCase {
    private func fixture() throws -> (URL, CodexLocation, ModelConfigurationFixture, MemoryCredentialStore, ConnectivityFixture, CodexModelProfileService) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("veyra-v2-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let rpc = ModelConfigurationFixture(home: home)
        let keys = MemoryCredentialStore(), client = ConnectivityFixture()
        let service = CodexModelProfileService(transport: rpc, root: home.appendingPathComponent("library"), credentials: keys,
            helperExecutable: URL(fileURLWithPath: "/Applications/New Veyra.app/Contents/MacOS/Veyra"), capability: { _ in true },
            modelClient: ProviderModelFixture(), connectivityClient: client)
        return (home, CodexLocation(home: home, executable: nil), rpc, keys, client, service)
    }
    private func local() -> ProviderSettings {
        var value = ProviderSettings(name: "Local fixture")
        value.baseURL = "http://127.0.0.1:11434/v1"; value.model = "manual-model"
        value.authentication = ModelProfileAuthentication.none
        return value
    }
    func testRemoteHTTPAndCredentialURLsAreRejectedWithoutGuessingV1() {
        for address in ["http://example.com/v1", "http://192.168.1.2/v1", "https://user:key@example.com/v1", "https://example.com?key=secret", "https://example.com/#secret"] {
            XCTAssertFalse(ProviderSettings.validEndpoint(address), address)
        }
        for address in ["http://localhost:1234", "http://127.0.0.1:1234/v1", "http://127.0.0.2:1234", "http://[::1]:1234", "https://example.com/custom"] {
            XCTAssertTrue(ProviderSettings.validEndpoint(address), address)
        }
        var value = local(); value.baseURL = "https://example.com/custom"
        XCTAssertEqual(try? value.profile(helper: URL(fileURLWithPath: "/tmp/helper")).baseURL, "https://example.com/custom")
    }
    func testManualModelWithoutKeyOrModelListCanApplyAndRenameKeepsIdentity() async throws {
        let (home, location, rpc, keys, client, service) = try fixture()
        var value = local()
        _ = try await service.saveProvider(value, newKey: nil, home: home)
        let writesBefore = await rpc.writeCount; XCTAssertEqual(writesBefore, 0)
        let result = try await service.applyProvider(value.id, location: location, expectedVersion: "0")
        XCTAssertEqual(result.snapshot.user["model"].string, value.model)
        XCTAssertEqual(result.snapshot.user["model_provider"].string, value.codexProviderID)
        XCTAssertEqual(result.snapshot.configuredProvider["auth"], .null)
        let id = value.codexProviderID; value.name = "Renamed"
        let saved = try await service.saveProvider(value, newKey: nil, home: home)
        XCTAssertEqual(saved.connections[0].codexProviderID, id); XCTAssertEqual(keys.count, 0)
        let calls = await client.calls; XCTAssertEqual(calls, 0)
    }
    func testOpenAIRestoreRejectsCredentialURLsWithoutChangingConfigurationOrRecovery() async throws {
        for address in ["https://user:fixture-canary@example.invalid/v1", "https://example.invalid/v1?key=fixture-canary",
                        "https://example.invalid/v1#fixture-canary"] {
            let (home, location, rpc, _, _, service) = try fixture()
            let value = local()
            _ = try await service.saveProvider(value, newKey: nil, home: home)
            _ = try await service.applyProvider(value.id, location: location, expectedVersion: "0")
            await rpc.change("openai_base_url", to: .string(address))
            let before = try await rpc.readConfiguration(location: location)
            let writesBefore = await rpc.writeCount
            let file = await service.libraryURL(home: home)
            let recoveryBefore = try Data(contentsOf: file)

            do {
                _ = try await service.restoreOpenAI(location: location, expectedVersion: before.version)
                XCTFail("A credential-bearing URL must not enter the recovery record")
            } catch { XCTAssertEqual(error as? ModelProfileFailure, .unsafeBackup) }

            let after = try await rpc.readConfiguration(location: location)
            let writesAfter = await rpc.writeCount
            XCTAssertEqual(after, before); XCTAssertEqual(writesAfter, writesBefore)
            XCTAssertEqual(try Data(contentsOf: file), recoveryBefore)
            XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("fixture-canary"))
        }
    }
    func testOpenAIRestoreAllowsSafeURLAndUndoRestoresIt() async throws {
        let (_, location, rpc, _, _, service) = try fixture()
        let address = "https://gateway.example.invalid/v1"
        await rpc.change("openai_base_url", to: .string(address))
        let before = try await rpc.readConfiguration(location: location)
        let restored = try await service.restoreOpenAI(location: location, expectedVersion: before.version)
        XCTAssertTrue(restored.snapshot.providerIdentity.isOfficial)
        XCTAssertEqual(restored.snapshot.user["openai_base_url"], .null)
        let undone = try await service.undo(location: location)
        XCTAssertEqual(undone.snapshot.user, before.user)
    }
    func testUnsafeTargetURLCannotCreateRecoveryOrWriteConfiguration() async throws {
        let (home, location, rpc, _, _, service) = try fixture()
        var profile = CodexModelProfile(name: "Referenced gateway", kind: .reference)
        profile.referencedProvider = "openai"
        profile.referencedOpenAIBaseURL = "https://example.invalid/v1?key=fixture-canary"
        let before = try await rpc.readConfiguration(location: location)
        do {
            _ = try await service.apply(profile, location: location, expectedVersion: before.version)
            XCTFail("The transaction target must also be safe to persist")
        } catch { XCTAssertEqual(error as? ModelProfileFailure, .unsafeBackup) }
        let after = try await rpc.readConfiguration(location: location)
        let writes = await rpc.writeCount
        let file = await service.libraryURL(home: home)
        XCTAssertEqual(after, before); XCTAssertEqual(writes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
    func testLegacyUnauthenticatedSwitchRetainsOfficialContextForRestore() async throws {
        for useConnection in [false, true] {
            let (home, location, rpc, _, _, service) = try fixture()
            await rpc.change("model_context_window", to: .number(128000))
            var value = local(); value.contextWindowOverride = 8192
            let profile = try value.profile(helper: URL(fileURLWithPath: "/tmp/fixture-helper"))
            _ = try await service.saveProfiles([profile], home: home)
            let before = try await service.read(location: location)
            let applied: ModelProfileContext
            if useConnection {
                applied = try await service.applyProvider(ProviderSettings(profile: profile).id, location: location,
                    expectedVersion: before.snapshot.version)
            } else {
                applied = try await service.apply(profile, location: location, expectedVersion: before.snapshot.version)
            }
            XCTAssertEqual(applied.snapshot.user["model_context_window"].integer, 8192)
            let restored = try await service.restoreOpenAI(location: location, expectedVersion: applied.snapshot.version)
            XCTAssertTrue(restored.snapshot.providerIdentity.isOfficial)
            XCTAssertEqual(restored.snapshot.user["model_context_window"].integer, 128000)
        }
    }
    func testUnauthenticatedContextOverrideReplacesPreviousProviderAndUndoRestoresIt() async throws {
        let (home, location, rpc, _, _, service) = try fixture()
        await rpc.change("model_context_window", to: .number(128000))
        var gateway = local(); gateway.authentication = .keychain; gateway.contextWindowOverride = 200000
        _ = try await service.saveProvider(gateway, newKey: "fixture-key", home: home)
        let initial = try await service.read(location: location)
        let previous = try await service.applyProvider(gateway.id, location: location, expectedVersion: initial.snapshot.version)
        XCTAssertEqual(previous.snapshot.user["model_context_window"].integer, 200000)
        var value = local(); value.contextWindowOverride = 8192
        _ = try await service.saveProvider(value, newKey: nil, home: home)
        let applied = try await service.applyProvider(value.id, location: location, expectedVersion: previous.snapshot.version)
        XCTAssertEqual(applied.snapshot.user["model_context_window"].integer, 8192)
        XCTAssertEqual(applied.snapshot.configuredProvider["auth"], .null)
        let undone = try await service.undo(location: location)
        XCTAssertEqual(undone.snapshot.user, previous.snapshot.user)
        let official = try await service.restoreOpenAI(location: location, expectedVersion: undone.snapshot.version)
        XCTAssertTrue(official.snapshot.providerIdentity.isOfficial)
        XCTAssertEqual(official.snapshot.user["model_context_window"].integer, 128000)
    }
    func testUnauthenticatedAutomaticContextUsesMetadataAndClearsStaleCapacity() async throws {
        let (home, location, rpc, keys, _, _) = try fixture()
        let client = ProviderModelFixture()
        let service = CodexModelProfileService(transport: rpc, root: home.appendingPathComponent("library"),
            credentials: keys, modelClient: client)
        let value = local()
        await client.configure([DiscoveredModel(id: value.model, contextWindow: 65536)])
        _ = try await service.saveProvider(value, newKey: nil, home: home)
        _ = try await service.fetchProviderModels(value.id, home: home)
        await rpc.change("model_context_window", to: .number(200000))
        let initial = try await service.read(location: location)
        let discovered = try await service.applyProvider(value.id, location: location, expectedVersion: initial.snapshot.version)
        XCTAssertEqual(discovered.snapshot.user["model_context_window"].integer, 65536)

        await client.configure([DiscoveredModel(id: value.model)])
        _ = try await service.fetchProviderModels(value.id, home: home)
        let automatic = try await service.applyProvider(value.id, location: location, expectedVersion: discovered.snapshot.version)
        XCTAssertEqual(automatic.snapshot.user["model_context_window"], .null)
        let undone = try await service.undo(location: location)
        XCTAssertEqual(undone.snapshot.user, discovered.snapshot.user)
    }
    func testMigrationIsCanonicalIdempotentAndBacksUpOriginalBeforeWriting() async throws {
        let (home, location, rpc, _, _, service) = try fixture()
        var profile = CodexModelProfile(name: "Same name", kind: .custom, model: "old-model", baseURL: "https://gateway.example.invalid/v1", environmentKey: "DO_NOT_READ")
        profile.id = UUID(uuidString: "AA000000-0000-0000-0000-000000000001")!
        var other = profile; other.id = UUID(); other.model = "another-model"
        var preset = ProviderSettings(preset: ProviderPreset.all[0]); preset.credential = CredentialReference()
        let raw: JSONValue = .object(["schemaVersion": .number(2), "profiles": .array(try [profile, other].map { try JSONValue.decode(JSONEncoder().encode($0)) }),
            "providers": .array([try JSONValue.decode(JSONEncoder().encode(preset))])])
        let file = await service.libraryURL(home: home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = try JSONEncoder().encode(raw); try original.write(to: file)
        let first = try await service.read(location: location)
        let second = try await service.read(location: location)
        XCTAssertEqual(first.library, second.library)
        XCTAssertEqual(first.library.connections.count, 3)
        XCTAssertEqual(first.library.profiles, [profile, other])
        XCTAssertEqual(first.library.providers[0].credential, preset.credential)
        let persisted = try JSONValue.decode(Data(contentsOf: file))
        XCTAssertEqual(persisted["schemaVersion"].integer, 3)
        XCTAssertEqual(persisted["profiles"], .null); XCTAssertEqual(persisted["providers"], .null)
        XCTAssertEqual(try Data(contentsOf: file.deletingLastPathComponent().appendingPathComponent("profiles-schema-2.backup.json")), original)
        let writes = await rpc.writeCount; XCTAssertEqual(writes, 0)
    }
    func testUnknownSchemaIsPreserved() async throws {
        let (home, _, _, _, _, service) = try fixture()
        let file = await service.libraryURL(home: home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(#"{"schemaVersion":99,"connections":[],"future":"keep"}"#.utf8)
        try original.write(to: file)
        do { _ = try await service.library(home: home); XCTFail() } catch { XCTAssertEqual(error as? ModelProfileFailure, .storage) }
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
    func testAddressConfirmationAndUnauthenticatedRequestsNeverReuseKey() async throws {
        let (home, _, _, _, client, service) = try fixture()
        var value = local(); value.authentication = .keychain; value.baseURL = "https://one.example.invalid/custom"
        var saved = try await service.saveProvider(value, newKey: "fixture-secret", home: home).connections[0]
        let reference = saved.credential
        saved.baseURL = "https://two.example.invalid/custom"
        do { _ = try await service.saveProvider(saved, newKey: nil, home: home); XCTFail() } catch { XCTAssertEqual(error as? CredentialFailure, .missing) }
        _ = try await service.saveProvider(saved, newKey: nil, home: home, confirmedAddress: true)
        saved.authentication = ModelProfileAuthentication.none
        _ = try await service.saveProvider(saved, newKey: nil, home: home)
        let result = try await service.testConnection(saved.id, home: home)
        XCTAssertNil(result.failure); XCTAssertNil(result.scope.credential)
        let sent = await client.keys; XCTAssertEqual(sent.count, 1); XCTAssertNil(sent[0])
        XCTAssertNotNil(reference)
    }
    func testConnectivityResultInvalidatesWithModelAddressAndCredentialAndDoesNotWriteCodex() async throws {
        let (home, _, rpc, _, client, service) = try fixture()
        let value = local()
        _ = try await service.saveProvider(value, newKey: nil, home: home)
        await client.configure(.authentication)
        let result = try await service.testConnection(value.id, home: home)
        XCTAssertEqual(result.failure, .authentication); XCTAssertTrue(result.matches(value))
        var changed = value; changed.model = "other"
        XCTAssertFalse(result.matches(changed))
        let saved = try await service.saveProvider(changed, newKey: nil, home: home)
        XCTAssertNil(saved.connections[0].connectivity)
        let writes = await rpc.writeCount; XCTAssertEqual(writes, 0)
        let file = await service.libraryURL(home: home)
        XCTAssertFalse(try String(contentsOf: file).contains("fixture-secret"))
    }
    func testLateConnectivityResultCannotOverwriteChangedConnection() async throws {
        let (home, _, _, _, client, service) = try fixture()
        var value = local()
        _ = try await service.saveProvider(value, newKey: nil, home: home)
        await client.configure(suspended: true)
        let testedID = value.id
        let operation = Task { try await service.testConnection(testedID, home: home) }
        for _ in 0..<100 { if await client.calls > 0 { break }; try await Task.sleep(for: .milliseconds(2)) }
        value.model = "changed"
        _ = try await service.saveProvider(value, newKey: nil, home: home)
        await client.resume()
        do { _ = try await operation.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        let saved = try await service.library(home: home)
        XCTAssertNil(saved.connections[0].connectivity)
    }
    func testRepairChangesOnlyCommandAndPreservesUnsavedCredentialAndModel() async throws {
        let (home, location, rpc, keys, _, service) = try fixture()
        var value = local(); value.authentication = .keychain
        value = try await service.saveProvider(value, newKey: "old-fixture-key", home: home).connections[0]
        var profile = try value.profile(helper: URL(fileURLWithPath: "/Applications/Old Veyra.app/Contents/MacOS/Veyra"))
        profile.model = "running-model"
        await rpc.change("model_provider", to: .string(profile.providerID))
        await rpc.change("model", to: .string(profile.model))
        await rpc.change("model_providers." + profile.providerID, to: profile.provider)
        let old = value.credential!
        value.model = "saved-but-unapplied"
        _ = try await service.saveProvider(value, newKey: "replacement-fixture-key", home: home)
        let before = try await service.read(location: location)
        let repaired = try await service.repairCredentialPath(value.id, location: location, expectedVersion: before.snapshot.version)
        XCTAssertEqual(repaired.snapshot.user["model"].string, "running-model")
        XCTAssertEqual(repaired.snapshot.configuredProvider["auth"]["args"], profile.provider["auth"]["args"])
        XCTAssertEqual(repaired.snapshot.configuredProvider["auth"]["command"].string, "/Applications/New Veyra.app/Contents/MacOS/Veyra")
        XCTAssertTrue(try keys.contains(old))
        XCTAssertEqual(repaired.library.journal?.after.map(\.keyPath), ["model_providers." + profile.providerID + ".auth.command"])
    }
    func testUnifiedOfficialApplyRestoresSignInSettingsAndLegacyOfficialRowCanBeDeleted() async throws {
        let (home, location, _, _, _, service) = try fixture()
        var gateway = local(); gateway.authentication = .keychain
        _ = try await service.saveProvider(gateway, newKey: "fixture-key", home: home)
        let active = try await service.applyProvider(gateway.id, location: location, expectedVersion: "0")
        XCTAssertEqual(active.snapshot.user["forced_login_method"].string, "api")
        var official = ProviderSettings(profile: CodexModelProfile(name: "Original official", model: "original"))
        let legacyID = official.id
        official.id = "openai"
        _ = try await service.saveProvider(official, newKey: nil, home: home)
        let restored = try await service.applyProvider(official.id, location: location, expectedVersion: active.snapshot.version)
        XCTAssertTrue(restored.snapshot.providerIdentity.isOfficial)
        XCTAssertEqual(restored.snapshot.user["forced_login_method"], .null)
        XCTAssertEqual(restored.snapshot.user["preferred_auth_method"], .null)
        official.id = legacyID
        _ = try await service.saveProvider(official, newKey: nil, home: home)
        let deleted = try await service.deleteConnection(official.id, location: location)
        XCTAssertFalse(deleted.connections.contains { $0.id == legacyID })
    }

    func testLegacyEnvironmentConversionPreservesIdentityAndRemainsAvailableToQuickSwitch() async throws {
        let (home, _, _, _, _, service) = try fixture()
        let legacy = CodexModelProfile(name: "Existing gateway", kind: .custom, model: "manual-model", baseURL: "https://gateway.example.invalid/v1", environmentKey: "EXTERNAL_KEY_NAME")
        _ = try await service.saveProfiles([legacy], home: home)
        var connection = ProviderSettings(profile: legacy); connection.authentication = .keychain
        let saved = try await service.saveProvider(connection, newKey: "fixture-key", home: home)
        let converted = try XCTUnwrap(saved.profiles.first)
        XCTAssertEqual(converted.id, legacy.id); XCTAssertEqual(converted.providerID, legacy.providerID)
        XCTAssertEqual(converted.authentication, .keychain)
        XCTAssertEqual(converted.helperPath, "/Applications/New Veyra.app/Contents/MacOS/Veyra")
        XCTAssertTrue(converted.validation.isEmpty)
        XCTAssertNotNil(converted.credentialReference)
        XCTAssertEqual(converted.environmentKey, "")
    }

    func testKnownPartialCommitRollsBackAndExternalMixedResultRetainsRecovery() async throws {
        let (home, location, rpc, _, _, service) = try fixture()
        let value = local()
        _ = try await service.saveProvider(value, newKey: nil, home: home)
        await rpc.configure(.partial)
        do { _ = try await service.applyProvider(value.id, location: location, expectedVersion: "0"); XCTFail() }
        catch { XCTAssertEqual(error as? ModelProfileFailure, .invalid) }
        let restored = try await service.read(location: location)
        XCTAssertEqual(restored.snapshot.user["model"].string, "original")
        XCTAssertNil(restored.library.pending)
        let writes = await rpc.writeCount; XCTAssertEqual(writes, 2)
        await rpc.configure(.partialAndExternal)
        do { _ = try await service.applyProvider(value.id, location: location, expectedVersion: restored.snapshot.version); XCTFail() }
        catch { XCTAssertEqual(error as? ModelProfileFailure, .conflict) }
        let unresolved = try await service.read(location: location)
        XCTAssertNotNil(unresolved.library.pending)
        XCTAssertEqual(unresolved.recoveryIssue, .changed)
        XCTAssertEqual(unresolved.snapshot.user["model"].string, "external-unknown-value")
        do { _ = try await service.applyProvider(value.id, location: location, expectedVersion: unresolved.snapshot.version); XCTFail() }
        catch { XCTAssertEqual(error as? ModelProfileFailure, .changed) }
        let finalWrites = await rpc.writeCount; XCTAssertEqual(finalWrites, 3)
    }

    func testDefaultDeletionIsBlockedUntilReplacementAppliedAndRetainsKey() async throws {
        let (home, location, _, keys, _, service) = try fixture()
        var value = local(); value.authentication = .keychain
        value = try await service.saveProvider(value, newKey: "fixture-key", home: home).connections[0]
        let applied = try await service.applyProvider(value.id, location: location, expectedVersion: "0")
        do { _ = try await service.deleteConnection(value.id, location: location); XCTFail() } catch { XCTAssertEqual(error as? CredentialFailure, .inUse) }
        _ = try await service.restoreOpenAI(location: location, expectedVersion: applied.snapshot.version)
        let removed = try await service.deleteConnection(value.id, location: location)
        XCTAssertTrue(removed.connections.isEmpty)
        XCTAssertTrue(try keys.contains(value.credential!))
        let undo = try await service.undo(location: location)
        XCTAssertEqual(undo.snapshot.configuredProviderID, value.codexProviderID)
    }
}

@MainActor
final class ProviderSettingsV2StoreTests: XCTestCase {
    private func fixture() async throws -> (ModelConfigurationFixture, CodexModelProfilesStore) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("veyra-v2-store-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let rpc = ModelConfigurationFixture(home: home)
        let service = CodexModelProfileService(transport: rpc, root: home.appendingPathComponent("library"), credentials: MemoryCredentialStore(), capability: { _ in true }, modelClient: ProviderModelFixture(), connectivityClient: ConnectivityFixture())
        let store = CodexModelProfilesStore(service: service)
        await store.load(location: CodexLocation(home: home, executable: nil)); store.activateWorkspace()
        store.chooseWorkspace(.create)
        store.providerDraft?.name = "Local fixture"; store.providerDraft?.baseURL = "http://localhost:11434/v1"
        store.providerDraft?.model = "manual-model"; store.providerDraft?.authentication = ModelProfileAuthentication.none
        return (rpc, store)
    }
    func testSaveAndUnverifiedApplyAreSeparateAndFailurePreservesSavedDefinition() async throws {
        let (rpc, store) = try await fixture()
        let saved = await store.saveWorkspace(); XCTAssertTrue(saved)
        let writes = await rpc.writeCount; XCTAssertEqual(writes, 0)
        await store.requestWorkspaceApply()
        XCTAssertTrue(store.showUnverifiedPrompt)
        await rpc.configure(.reject)
        await store.applyWorkspace()
        XCTAssertNotNil(store.error); XCTAssertNil(store.message)
        XCTAssertEqual(store.workspaceApplyStatus, .failed)
        XCTAssertFalse(store.hasUnsavedChanges); XCTAssertEqual(store.customConnections.count, 1)
        await rpc.configure(.normal)
        await store.applyWorkspace()
        XCTAssertNil(store.error); XCTAssertNotNil(store.message)
        XCTAssertTrue(store.isDefaultConnection(store.providerDraft!))
    }
    func testOfficialSelectionAndNavigationNeverWriteAndSaveFailureKeepsEditor() async throws {
        let (rpc, store) = try await fixture()
        store.chooseWorkspace(.official)
        XCTAssertTrue(store.showUnsavedPrompt)
        store.cancelNavigation(); XCTAssertEqual(store.providerDraft?.name, "Local fixture")
        store.providerDraft?.baseURL = "invalid"
        store.chooseWorkspace(.official); await store.resolveNavigation(save: true)
        XCTAssertEqual(store.workspaceSelection, .create)
        XCTAssertEqual(store.providerDraft?.baseURL, "invalid")
        store.chooseWorkspace(.official); await store.resolveNavigation(save: false)
        XCTAssertEqual(store.workspaceSelection, .official)
        let writes = await rpc.writeCount; XCTAssertEqual(writes, 0)
    }
    func testDiscardInvalidContextAllowsWindowCloseNavigation() async throws {
        let (_, store) = try await fixture()
        _ = await store.saveWorkspace()
        store.invalidContextInput = true
        var closed = false
        store.navigate { closed = true }
        XCTAssertTrue(store.showUnsavedPrompt)
        await store.resolveNavigation(save: false)
        XCTAssertTrue(closed); XCTAssertFalse(store.hasUnsavedChanges)
    }

    func testUnauthenticatedAppliedStatusChecksContextOverrideAndExternalChanges() async throws {
        let (rpc, store) = try await fixture()
        store.providerDraft?.contextWindowOverride = 8192
        let saved = await store.saveWorkspace(); XCTAssertTrue(saved)
        await store.applyWorkspace()
        XCTAssertNil(store.error); XCTAssertEqual(store.workspaceApplyStatus, .applied)
        let applied = try await rpc.readConfiguration(location: store.location!)
        XCTAssertEqual(applied.user["model_context_window"].integer, 8192)

        await rpc.change("model_context_window", to: .number(200000))
        await store.reloadWorkspace(location: store.location!)
        XCTAssertEqual(store.workspaceApplyStatus, .notApplied)
        await store.applyWorkspace()
        XCTAssertEqual(store.workspaceApplyStatus, .applied)

        store.providerDraft?.contextWindowOverride = nil
        await store.requestWorkspaceApply(); await store.applyWorkspace()
        XCTAssertNil(store.error); XCTAssertEqual(store.workspaceApplyStatus, .applied)
        let automatic = try await rpc.readConfiguration(location: store.location!)
        XCTAssertEqual(automatic.user["model_context_window"], .null)
        await rpc.change("model_context_window", to: .number(65536))
        await store.reloadWorkspace(location: store.location!)
        XCTAssertEqual(store.workspaceApplyStatus, .notApplied)
    }

    func testDuplicateHasNewIdentityAndNoCredentialOrVerification() async throws {
        let (_, store) = try await fixture()
        store.providerDraft?.authentication = .keychain; store.apiKeyInput = "fixture-secret"
        let saved = await store.saveWorkspace(); XCTAssertTrue(saved)
        let original = store.providerDraft!
        store.duplicateWorkspace()
        XCTAssertNotEqual(original.id, store.providerDraft?.id)
        XCTAssertNil(store.providerDraft?.credential); XCTAssertNil(store.providerDraft?.connectivity)
        XCTAssertEqual(store.providerDraft?.baseURL, original.baseURL)
        XCTAssertTrue(store.hasUnsavedChanges)
    }
    func testObservedReasoningAppliesOnlyToSameModelAndOldUnknownOverrideCannotApply() async throws {
        let (rpc, store) = try await fixture()
        _ = await store.saveWorkspace()
        await store.requestWorkspaceApply(); await store.applyWorkspace()
        await rpc.change("model_reasoning_effort", to: .string("high"))
        store.providerDraft?.reasoning = "high"
        // Reload the real fixture configuration, then preserve the observed model association.
        if let location = store.location { await store.reloadWorkspace(location: location) }
        XCTAssertEqual(store.permittedReasoning, ["high"])
        store.providerDraft?.model = "another-model"
        XCTAssertTrue(store.permittedReasoning.isEmpty)
        store.providerDraft?.reasoning = "high"
        XCTAssertFalse(store.canApplyWorkspace)
    }

    func testOpeningKeyEditorCannotBypassKnownAuthenticationFailure() async throws {
        let (_, store) = try await fixture()
        store.providerDraft?.authentication = .keychain; store.apiKeyInput = "fixture-key"
        _ = await store.saveWorkspace()
        let saved = store.providerDraft!
        let scope = try XCTUnwrap(ProviderModelScope(saved))
        let index = try XCTUnwrap(store.library.connections.firstIndex { $0.id == saved.id })
        store.library.connections[index].connectivity = ProviderConnectivityResult(scope: scope, model: saved.model, protocolName: saved.protocolName, date: Date(), failure: .authentication)
        store.replacingKey = true
        XCTAssertFalse(store.canApplyWorkspace)
        store.apiKeyInput = "replacement-fixture-key"
        XCTAssertNil(store.connectionResult)
        XCTAssertTrue(store.canApplyWorkspace)
    }

    func testInvalidContextAndUnsupportedReasoningCannotSubmit() async throws {
        let (_, store) = try await fixture()
        store.invalidContextInput = true
        XCTAssertFalse(store.canApplyWorkspace)
        store.invalidContextInput = false; store.providerDraft?.reasoning = "high"
        XCTAssertFalse(store.canApplyWorkspace)
        XCTAssertNotNil(store.workspaceErrors["reasoning"])
    }
}

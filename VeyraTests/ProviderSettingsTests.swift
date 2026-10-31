import Foundation
import XCTest

final class ProviderSettingsTests: XCTestCase {
    private func fixture(capable: Bool = true) throws -> (URL, CodexLocation, ModelConfigurationFixture, MemoryCredentialStore, CodexModelProfileService) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("veyra-provider-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let location = CodexLocation(home: home, executable: nil)
        let transport = ModelConfigurationFixture(home: home, user: .object(["model": .string("official-original"), "service_tier": .string("fast"), "mcp_servers": .object(["fixture": .object(["command": .string("keep")])])]))
        let keys = MemoryCredentialStore()
        let service = CodexModelProfileService(transport: transport, root: home.appendingPathComponent("library"), credentials: keys,
            helperExecutable: URL(fileURLWithPath: "/Applications/Veyra.app/Contents/MacOS/Veyra"), capability: { _ in capable }, modelClient: ProviderModelFixture())
        return (home, location, transport, keys, service)
    }
    func testPresetsContainOnlyProviderIdentityAndNewSettingsHaveNoModel() throws {
        XCTAssertEqual(ProviderPreset.all.map(\.id), ["deepseek", "kimi", "glm", "minimax", "mimo"])
        for preset in ProviderPreset.all { XCTAssertEqual(ProviderSettings(preset: preset).model, "") }
    }
    func testSaveDoesNotApplyAndDoesNotSerializeKey() async throws {
        let (home, _, transport, keys, service) = try fixture()
        let value = try await service.saveDiscoveredProvider(ProviderSettings(preset: ProviderPreset.all[0]), newKey: "fixture-canary-secret", home: home)
        XCTAssertNotNil(value.providers[0].credential)
        XCTAssertEqual(keys.count, 1)
        let writes = await transport.writeCount; XCTAssertEqual(writes, 0)
        let file = await service.libraryURL(home: home)
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("fixture-canary-secret"))
        XCTAssertEqual(value.schemaVersion, 3)
    }
    func testApplySwitchAndOfficialRestorePreserveUnrelatedSettings() async throws {
        let (home, location, transport, _, service) = try fixture()
        for preset in ProviderPreset.all {
            _ = try await service.saveDiscoveredProvider(ProviderSettings(preset: preset), newKey: "fixture-key-" + preset.id, home: home)
        }
        var context = try await service.read(location: location)
        for preset in ProviderPreset.all {
            context = try await service.applyProvider(preset.id, location: location, expectedVersion: context.snapshot.version)
            XCTAssertEqual(context.snapshot.user["model_provider"].string, "veyra_preset_" + preset.id)
            XCTAssertEqual(context.snapshot.user["model"].string, "fixture-model")
            XCTAssertNil(context.snapshot.configuredProvider["env_key"].string)
            XCTAssertNil(context.snapshot.configuredProvider["experimental_bearer_token"].string)
            XCTAssertEqual(context.snapshot.configuredProvider["auth"]["args"].array?.first?.string, "--provider-credential")
            let catalog = try XCTUnwrap(context.snapshot.user["model_catalog_json"].string)
            XCTAssertTrue(FileManager.default.fileExists(atPath: catalog))
            XCTAssertEqual(context.snapshot.user["service_tier"], .null)
            XCTAssertEqual(context.snapshot.user["mcp_servers"]["fixture"]["command"].string, "keep")
        }
        context = try await service.restoreOpenAI(location: location, expectedVersion: context.snapshot.version)
        XCTAssertEqual(context.snapshot.user["model"].string, "official-original")
        XCTAssertEqual(context.snapshot.user["service_tier"].string, "fast")
        context = try await service.applyProvider("mimo", location: location, expectedVersion: context.snapshot.version)
        XCTAssertEqual(context.snapshot.user["model_provider"].string, "veyra_preset_mimo")
        let writes = await transport.writeCount; XCTAssertEqual(writes, 7)
    }
    func testReapplyingSamePresetUsesImmutableCatalogAndNoExtraWrite() async throws {
        let (home, location, transport, _, service) = try fixture()
        _ = try await service.saveDiscoveredProvider(ProviderSettings(preset: ProviderPreset.all[0]), newKey: "fixture-key", home: home)
        let first = try await service.applyProvider("deepseek", location: location, expectedVersion: "0")
        _ = try await service.applyProvider("deepseek", location: location, expectedVersion: first.snapshot.version)
        let writes = await transport.writeCount; XCTAssertEqual(writes, 1)
    }
    func testRotationKeepsOldKeyUntilExplicitInactiveCleanup() async throws {
        let (home, location, _, keys, service) = try fixture()
        var lib = try await service.saveDiscoveredProvider(ProviderSettings(preset: ProviderPreset.all[0]), newKey: "old-fixture-key", home: home)
        let old = try XCTUnwrap(lib.providers[0].credential)
        let first = try await service.applyProvider("deepseek", location: location, expectedVersion: "0")
        lib = try await service.saveDiscoveredProvider(lib.providers[0], newKey: "new-fixture-key", home: home)
        let new = try XCTUnwrap(lib.providers[0].credential)
        XCTAssertNotEqual(old, new)
        let current = try await service.applyProvider("deepseek", location: location, expectedVersion: first.snapshot.version)
        XCTAssertTrue(try keys.contains(old)); XCTAssertTrue(try keys.contains(new))
        XCTAssertEqual(current.snapshot.configuredProvider["auth"]["args"].array?.last?.string, new.argument)
        _ = try await service.restoreOpenAI(location: location, expectedVersion: current.snapshot.version)
        _ = try await service.removeProviderKey("deepseek", location: location)
        XCTAssertFalse(try keys.contains(old)); XCTAssertFalse(try keys.contains(new))
    }
    func testRemovalProtectsCurrentConfigurationAndAllowsInactiveCleanupWithoutUndo() async throws {
        let (home, location, _, keys, service) = try fixture()
        let lib = try await service.saveDiscoveredProvider(ProviderSettings(preset: ProviderPreset.all[0]), newKey: "fixture-key", home: home)
        let ref = try XCTUnwrap(lib.providers[0].credential)
        let active = try await service.applyProvider("deepseek", location: location, expectedVersion: "0")
        do { _ = try await service.removeProviderKey("deepseek", location: location); XCTFail() }
        catch { XCTAssertEqual(error as? CredentialFailure, .inUse) }
        _ = try await service.restoreOpenAI(location: location, expectedVersion: active.snapshot.version)
        let cleared = try await service.removeProviderKey("deepseek", location: location)
        XCTAssertNil(cleared.providers[0].credential); XCTAssertFalse(try keys.contains(ref))
    }
    func testLegacyCompletedUndoHistoryDoesNotBlockInactiveKeyRemoval() async throws {
        let (home, location, _, keys, service) = try fixture()
        let saved = try await service.saveDiscoveredProvider(ProviderSettings(preset: ProviderPreset.all[0]), newKey: "fixture-key", home: home)
        let reference = try XCTUnwrap(saved.providers[0].credential)
        let active = try await service.applyProvider("deepseek", location: location, expectedVersion: "0")
        _ = try await service.restoreOpenAI(location: location, expectedVersion: active.snapshot.version)
        let file = await service.libraryURL(home: home)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        legacy["journal"] = ["before": [["keyPath": "model_provider", "value": "veyra_preset_deepseek"]],
                             "after": [["keyPath": "model_provider", "value": "openai"]],
                             "completed": true, "isUndo": false]
        try JSONSerialization.data(withJSONObject: legacy).write(to: file)
        let cleared = try await service.removeProviderKey("deepseek", location: location)
        XCTAssertNil(cleared.providers[0].credential)
        XCTAssertFalse(try keys.contains(reference))
        let persisted = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertNil(persisted["journal"])
    }
    func testInterruptedChangeStillProtectsItsCredentialDependencies() async throws {
        let (home, location, transport, keys, service) = try fixture()
        let saved = try await service.saveDiscoveredProvider(ProviderSettings(preset: ProviderPreset.all[0]), newKey: "fixture-key", home: home)
        let reference = try XCTUnwrap(saved.providers[0].credential)
        let active = try await service.applyProvider("deepseek", location: location, expectedVersion: "0")
        await transport.configure(.partialAndExternal)
        do { _ = try await service.restoreOpenAI(location: location, expectedVersion: active.snapshot.version); XCTFail() }
        catch { XCTAssertEqual(error as? ModelProfileFailure, .conflict) }
        let interrupted = try await service.library(home: home)
        XCTAssertNotNil(interrupted.pending)
        do { _ = try await service.removeProviderKey("deepseek", location: location); XCTFail() }
        catch { XCTAssertEqual(error as? CredentialFailure, .inUse) }
        XCTAssertTrue(try keys.contains(reference))
    }
    func testAddressChangeRequiresNewKeyAndDoesNotModifySavedConnection() async throws {
        let (home, _, _, keys, service) = try fixture()
        let saved = try await service.saveDiscoveredProvider(ProviderSettings(preset: ProviderPreset.all[0]), newKey: "fixture-key", home: home)
        var changed = saved.providers[0]; changed.baseURL = "https://other.example.invalid/v1"
        do { _ = try await service.saveDiscoveredProvider(changed, newKey: nil, home: home); XCTFail() }
        catch { XCTAssertEqual(error as? CredentialFailure, .missing) }
        let actual = try await service.library(home: home)
        XCTAssertEqual(actual.providers[0], saved.providers[0]); XCTAssertEqual(keys.count, 1)
    }
    func testUnsupportedAndMissingKeyCannotWrite() async throws {
        let (home, location, transport, _, service) = try fixture(capable: false)
        _ = try await service.saveDiscoveredProvider(ProviderSettings(preset: ProviderPreset.all[0]), newKey: "fixture-key", home: home)
        do { _ = try await service.applyProvider("deepseek", location: location, expectedVersion: "0"); XCTFail() }
        catch { XCTAssertEqual(error as? ModelProfileFailure, .unsupported) }
        let writes = await transport.writeCount; XCTAssertEqual(writes, 0)
    }
    func testStaleCodexVersionAndFailedWritePreserveCurrentConfigurationAndKey() async throws {
        let (home, location, transport, keys, service) = try fixture()
        let saved = try await service.saveDiscoveredProvider(ProviderSettings(preset: ProviderPreset.all[0]), newKey: "fixture-key", home: home)
        let first = try await service.applyProvider("deepseek", location: location, expectedVersion: "0")
        do { _ = try await service.applyProvider("deepseek", location: location, expectedVersion: "0"); XCTFail() }
        catch { XCTAssertEqual(error as? ModelProfileFailure, .conflict) }
        await transport.configure(.reject)
        do { _ = try await service.restoreOpenAI(location: location, expectedVersion: first.snapshot.version); XCTFail() }
        catch { XCTAssertEqual(error as? ModelProfileFailure, .invalid) }
        let retained = try await service.library(home: home)
        XCTAssertNil(retained.pending)
        let after = try await transport.readConfiguration(location: location)
        XCTAssertEqual(after, first.snapshot)
        XCTAssertTrue(try keys.contains(saved.providers[0].credential!))
    }
    func testSchemaOneMigrationPreservesProfilesAndDoesNotApply() async throws {
        let (home, _, transport, _, service) = try fixture()
        var profile = CodexModelProfile(name: "Original legacy", kind: .custom, model: "old", baseURL: "https://legacy.example.invalid", environmentKey: "DO_NOT_READ_ME")
        profile.id = UUID(uuidString: "AA000000-0000-0000-0000-000000000001")!
        let data = try JSONEncoder().encode(profile)
        let json: JSONValue = .object(["schemaVersion": .number(1), "profiles": .array([try JSONValue.decode(data)])])
        let file = await service.libraryURL(home: home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(json).write(to: file)
        let migrated = try await service.library(home: home)
        XCTAssertEqual(migrated.schemaVersion, 3); XCTAssertEqual(migrated.profiles, [profile]); XCTAssertTrue(migrated.providers.isEmpty)
        let writes = await transport.writeCount; XCTAssertEqual(writes, 0)
    }
    func testSecretsAreNotAcceptedAsUnknownAuthRecoveryFields() throws {
        var settings = ProviderSettings(preset: ProviderPreset.all[0]); settings.model = "fixture-model"; settings.credential = CredentialReference()
        let profile = try settings.profile(helper: URL(fileURLWithPath: "/Applications/Veyra.app/Contents/MacOS/Veyra"))
        var existing = profile.provider.object!
        existing["auth"] = .object(["command": .string("/Applications/Veyra.app/Contents/MacOS/Veyra"), "args": .array([.string("--provider-credential"), .string("not-a-reference-secret")])])
        let snapshot = CodexConfigSnapshot(user: .object(["model_providers": .object([profile.providerID: .object(existing)])]), version: "0", file: URL(fileURLWithPath: "/tmp/config.toml"))
        XCTAssertThrowsError(try ModelProfilePatch.edits(for: profile, snapshot: snapshot))
    }
}

@MainActor
final class ProviderSettingsStoreTests: XCTestCase {
    private func fixture() throws -> (CodexLocation, ModelConfigurationFixture, CodexModelProfilesStore) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("veyra-provider-store-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let transport = ModelConfigurationFixture(home: home)
        let service = CodexModelProfileService(transport: transport, root: home.appendingPathComponent("library"), credentials: MemoryCredentialStore(),
            helperExecutable: URL(fileURLWithPath: "/Applications/Veyra.app/Contents/MacOS/Veyra"), capability: { _ in true }, modelClient: ProviderModelFixture())
        return (CodexLocation(home: home, executable: nil), transport, CodexModelProfilesStore(service: service))
    }
    func testSaveKeyDoesNotSwitchAndSwitchingPresetProtectsInput() async throws {
        let (location, transport, store) = try fixture()
        await store.load(location: location); store.activateWorkspace()
        store.apiKeyInput = "fixture-key"
        let saved = await store.saveWorkspace(); XCTAssertTrue(saved)
        XCTAssertTrue(store.apiKeyInput.isEmpty)
        XCTAssertTrue(store.switchablePresets.isEmpty)
        XCTAssertTrue(store.workspaceModels.isEmpty)
        await store.refreshWorkspaceModels()
        XCTAssertEqual(store.workspaceModels.map(\.id), ["fixture-model"])
        XCTAssertEqual(store.providerDraft?.model, "")
        let writes = await transport.writeCount; XCTAssertEqual(writes, 0)
        store.apiKeyInput = "replacement-fixture-key"
        store.chooseWorkspace(.connection("kimi"))
        XCTAssertTrue(store.showUnsavedPrompt); XCTAssertEqual(store.workspaceSelection, .connection("deepseek"))
        store.cancelNavigation(); XCTAssertFalse(store.apiKeyInput.isEmpty)
        store.chooseWorkspace(.connection("kimi")); await store.resolveNavigation(save: false)
        XCTAssertEqual(store.workspaceSelection, .connection("kimi")); XCTAssertTrue(store.apiKeyInput.isEmpty)
    }
    func testSaveAndApplyClearsInputAndRestoresOfficial() async throws {
        let (location, _, store) = try fixture()
        await store.load(location: location); store.activateWorkspace()
        store.apiKeyInput = "fixture-key"
        let saved = await store.saveWorkspace(); XCTAssertTrue(saved)
        await store.refreshWorkspaceModels()
        store.providerDraft?.model = "fixture-model"
        await store.requestWorkspaceApply()
        XCTAssertNil(store.error)
        XCTAssertEqual(store.currentPresetID, "deepseek")
        XCTAssertTrue(store.apiKeyInput.isEmpty); XCTAssertNil(store.library.pending)
        await store.restoreOpenAI()
        XCTAssertNil(store.currentPresetID)
        XCTAssertTrue(store.defaultProviderIdentity.isOfficial)
    }
    func testInvalidKeyNeverEntersSavedSettings() async throws {
        let (location, transport, store) = try fixture()
        await store.load(location: location); store.activateWorkspace()
        store.apiKeyInput = "invalid key\n"
        let saved = await store.saveWorkspace()
        XCTAssertFalse(saved); XCTAssertTrue(store.library.connections.isEmpty)
        let writes = await transport.writeCount; XCTAssertEqual(writes, 0)
    }

}

private final class MetadataFailureCredentialStore: CredentialStore, @unchecked Sendable {
    let memory = MemoryCredentialStore()
    let blockMetadata: URL
    init(blockMetadata: URL) { self.blockMetadata = blockMetadata }
    func save(_ key: String, reference: CredentialReference) throws {
        try memory.save(key, reference: reference)
        // Force the metadata write to fail after the Key has already been saved.
        try FileManager.default.createDirectory(at: blockMetadata, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: blockMetadata.appendingPathComponent("keep"))
    }
    func read(_ reference: CredentialReference) throws -> String { try memory.read(reference) }
    func contains(_ reference: CredentialReference) throws -> Bool { try memory.contains(reference) }
    func remove(_ reference: CredentialReference) throws { try memory.remove(reference) }
}

final class ProviderCredentialFailureTests: XCTestCase {
    func testMetadataFailureRemovesOnlyTheNewKeyAndDoesNotApply() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("veyra-key-rollback-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let transport = ModelConfigurationFixture(home: home)
        let probe = CodexModelProfileService(transport: transport, root: home.appendingPathComponent("library"))
        let file = await probe.libraryURL(home: home)
        let keys = MetadataFailureCredentialStore(blockMetadata: file)
        let service = CodexModelProfileService(transport: transport, root: home.appendingPathComponent("library"), credentials: keys)
        do {
            _ = try await service.saveDiscoveredProvider(ProviderSettings(preset: ProviderPreset.all[0]), newKey: "fixture-rollback-key", home: home)
            XCTFail("metadata must fail")
        } catch { XCTAssertEqual(error as? ModelProfileFailure, .storage) }
        XCTAssertEqual(keys.memory.count, 0)
        let writes = await transport.writeCount; XCTAssertEqual(writes, 0)
    }
    func testSwitchRefusesMissingProviderKey() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("veyra-key-switch-missing-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let transport = ModelConfigurationFixture(home: home)
        let keys = MemoryCredentialStore()
        let location = CodexLocation(home: home, executable: nil)
        let service = CodexModelProfileService(transport: transport, root: home.appendingPathComponent("library"), credentials: keys,
            helperExecutable: URL(fileURLWithPath: "/Applications/Veyra.app/Contents/MacOS/Veyra"), capability: { _ in true }, modelClient: ProviderModelFixture())
        let saved = try await service.saveDiscoveredProvider(ProviderSettings(preset: ProviderPreset.all[0]), newKey: "fixture-key", home: home)
        let active = try await service.applyProvider("deepseek", location: location, expectedVersion: "0")
        let official = try await service.restoreOpenAI(location: location, expectedVersion: active.snapshot.version)
        try keys.remove(saved.providers[0].credential!)
        do { _ = try await service.applyProvider("deepseek", location: location, expectedVersion: official.snapshot.version); XCTFail() }
        catch { XCTAssertEqual(error as? CredentialFailure, .missing) }
        let writes = await transport.writeCount; XCTAssertEqual(writes, 2)
    }
    func testMissingKeyFailsClosedAndCommittedDisconnectRecoversWithoutRetry() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("veyra-key-recovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let location = CodexLocation(home: home, executable: nil)
        let transport = ModelConfigurationFixture(home: home)
        let keys = MemoryCredentialStore()
        let service = CodexModelProfileService(transport: transport, root: home.appendingPathComponent("library"), credentials: keys,
            helperExecutable: URL(fileURLWithPath: "/Applications/Veyra.app/Contents/MacOS/Veyra"), capability: { _ in true }, modelClient: ProviderModelFixture())
        let saved = try await service.saveDiscoveredProvider(ProviderSettings(preset: ProviderPreset.all[0]), newKey: "fixture-key", home: home)
        let ref = saved.providers[0].credential!
        try keys.remove(ref)
        do { _ = try await service.applyProvider("deepseek", location: location, expectedVersion: "0"); XCTFail() }
        catch { XCTAssertEqual(error as? CredentialFailure, .missing) }
        let noWrites = await transport.writeCount; XCTAssertEqual(noWrites, 0)
        try keys.save("fixture-key", reference: ref)
        await transport.configure(.commitThenDisconnect)
        do { _ = try await service.applyProvider("deepseek", location: location, expectedVersion: "0"); XCTFail() }
        catch { XCTAssertEqual(error as? ModelProfileFailure, .unavailable) }
        let recovered = try await service.read(location: location)
        XCTAssertNil(recovered.library.pending)
        XCTAssertEqual(recovered.snapshot.configuredProviderID, "veyra_preset_deepseek")
        let oneWrite = await transport.writeCount; XCTAssertEqual(oneWrite, 1)
    }
}

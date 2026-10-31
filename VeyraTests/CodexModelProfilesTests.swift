import XCTest
import Foundation

actor ModelConfigurationFixture: CodexModelConfigurationTransport {
    enum Mode { case normal, reject, commitThenThrow, commitThenDisconnect, partial, partialAndExternal }
    var snapshot: CodexConfigSnapshot
    var mode = Mode.normal
    var writeCount = 0
    var readCount = 0
    var failedReads = 0
    var delay = Duration.zero
    init(home: URL, user: JSONValue = .object(["model": .string("original")])) {
        snapshot = CodexConfigSnapshot(user: user, version: "0", file: home.appendingPathComponent("config.toml"))
    }
    func configure(_ mode: Mode, delay: Duration = .zero) { self.mode = mode; self.delay = delay }
    func configureReadFailures(_ count: Int) { failedReads = count }
    func readConfiguration(location: CodexLocation) async throws -> CodexConfigSnapshot {
        readCount += 1
        if failedReads > 0 { failedReads -= 1; throw ModelProfileFailure.unavailable }
        return snapshot
    }
    func writeConfiguration(location: CodexLocation, edits: [CodexConfigEdit], expectedVersion: String) async throws -> CodexConfigWriteReceipt {
        guard expectedVersion == snapshot.version else { throw ModelProfileFailure.conflict }
        writeCount += 1
        if delay != .zero { try await Task.sleep(for: delay) }
        if mode == .reject { throw ModelProfileFailure.invalid }
        let partial = mode == .partial || mode == .partialAndExternal
        for edit in (partial ? Array(edits.prefix(1)) : edits) { snapshot.user = Self.setting(snapshot.user, path: edit.keyPath.split(separator: ".").map(String.init), value: edit.value) }
        snapshot.effective = snapshot.user
        snapshot.version = String((Int(snapshot.version) ?? 0) + 1)
        if mode == .commitThenDisconnect { failedReads = 1; throw ModelProfileFailure.unavailable }
        if mode == .commitThenThrow { throw ModelProfileFailure.unavailable }
        let receiptVersion = snapshot.version
        if mode == .partialAndExternal { change("model", to: .string("external-unknown-value")) }
        if partial { mode = .normal }
        return CodexConfigWriteReceipt(version: receiptVersion, overridden: false)
    }
    func change(_ path: String, to value: JSONValue) {
        snapshot.user = Self.setting(snapshot.user, path: path.split(separator: ".").map(String.init), value: value)
        snapshot.effective = snapshot.user
        snapshot.version = String((Int(snapshot.version) ?? 0) + 1)
    }
    private static func setting(_ original: JSONValue, path: [String], value: JSONValue) -> JSONValue {
        guard let key = path.first else { return value }
        var object = original.object ?? [:]
        if path.count == 1 {
            if value == .null { object.removeValue(forKey: key) } else { object[key] = value }
        } else { object[key] = setting(object[key] ?? .object([:]), path: Array(path.dropFirst()), value: value) }
        return .object(object)
    }
}

final class CodexModelProfilesTests: XCTestCase {
    private func temporary() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("veyra-profiles-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }
    private func custom() -> CodexModelProfile {
        CodexModelProfile(name: "Gateway", kind: .custom, model: "coding-model", baseURL: "https://gateway.example.invalid/v1",
                          reasoning: "high", environmentKey: "FIXTURE_API_KEY")
    }

    func testValidationAndStableProviderIdentity() {
        var profile = custom()
        XCTAssertTrue(profile.validation.isEmpty)
        let identity = profile.providerID
        profile.name = " Renamed "
        XCTAssertEqual(profile.normalized().name, "Renamed")
        XCTAssertEqual(profile.providerID, identity)
        for address in ["invalid", "https://user:secret@example.invalid/v1", "https://example.invalid?token=secret", "file:///tmp/model"] {
            profile.baseURL = address
            XCTAssertNotNil(profile.validation["baseURL"])
        }
        profile.baseURL = "http://127.0.0.1:11434/v1"
        profile.environmentKey = "BAD-NAME"
        XCTAssertNotNil(profile.validation["environmentKey"])
        profile.authentication = .none
        XCTAssertNil(profile.validation["environmentKey"])
        profile.catalogPath = "relative.json"
        XCTAssertNotNil(profile.validation["catalogPath"])
        profile.catalogPath = ""; profile.reasoning = "unsupported"
        XCTAssertNotNil(profile.validation["reasoning"])
    }

    func testProviderIdentityAndInitialNeverInferBrandFromNameOrModel() {
        XCTAssertEqual(CodexModelProfile(name: "Any saved label").providerIdentity,
                       CodexProviderIdentity(name: "OpenAI", isOfficial: true))
        var profile = custom()
        profile.name = "OpenAI gateway"
        profile.model = "OpenAI-model"
        XCTAssertFalse(profile.providerIdentity.isOfficial)
        XCTAssertEqual(profile.providerIdentity.initial, "O")
        profile.providerName = "  中文供应商  "
        XCTAssertEqual(profile.providerIdentity.name, "中文供应商")
        XCTAssertEqual(profile.providerIdentity.initial, "中")
        profile.providerName = " "; profile.name = "  gateway "
        XCTAssertEqual(profile.providerIdentity.initial, "G")
        profile.name = "  "
        XCTAssertNil(profile.providerIdentity.initial)
        XCTAssertEqual(CodexProviderIdentity(name: "e\u{301}quipe").initial, "E\u{301}")
        XCTAssertEqual(CodexProviderIdentity(name: "ßervice").initial, "S")
    }

    func testSnapshotProviderNameNeverFallsBackToModelAndRedirectIsCustom() {
        var snapshot = CodexConfigSnapshot(user: .object(["model": .string("model-only")]), version: "0",
                                           file: URL(fileURLWithPath: "/tmp/config.toml"))
        XCTAssertEqual(snapshot.providerIdentity, CodexProviderIdentity(name: "OpenAI", isOfficial: true))
        snapshot.user = .object(["model_provider": .string("external"), "model": .string("model-only"),
            "model_providers": .object(["external": .object(["name": .string(" Gateway ")])])])
        XCTAssertEqual(snapshot.providerIdentity.name, "Gateway")
        snapshot.user = .object(["model_provider": .string("unregistered"), "model": .string("model-only")])
        XCTAssertEqual(snapshot.providerIdentity.name, "unregistered")
        snapshot.user = .object(["openai_base_url": .string("https://gateway.example.invalid/v1")])
        XCTAssertFalse(snapshot.providerIdentity.isOfficial)
        XCTAssertEqual(snapshot.providerIdentity.name, L10n.text("Custom service"))
    }

    func testProviderMembershipIgnoresModelEffortAndCatalogButChecksConnection() {
        let profile = custom()
        var snapshot = CodexConfigSnapshot(user: .object([
            "model_provider": .string("imported"), "model": .string("different-model"),
            "model_reasoning_effort": .string("low"), "model_catalog_json": .string("/tmp/other.json"),
            "model_providers": .object(["imported": profile.provider])
        ]), version: "0", file: URL(fileURLWithPath: "/tmp/config.toml"))
        XCTAssertTrue(profile.matchesProvider(snapshot))
        XCTAssertFalse(profile.matches(snapshot))
        var changed = profile
        changed.baseURL = "https://different.example.invalid/v1"
        XCTAssertFalse(changed.matchesProvider(snapshot))
        changed = profile; changed.environmentKey = "OTHER_KEY"
        XCTAssertFalse(changed.matchesProvider(snapshot))
        snapshot.user = .object(["model": .string("any-model"), "model_reasoning_effort": .string("high")])
        snapshot.effective = snapshot.user
        XCTAssertTrue(CodexModelProfile(name: "Official").matchesProvider(snapshot))
    }

    func testInheritedProviderMetadataAndComplexReferenceIdentity() {
        let effective: JSONValue = .object(["model_provider": .string("gateway"),
            "model_providers": .object(["gateway": .object(["name": .string("Inherited gateway"),
                "experimental_bearer_token": .string("DO_NOT_COPY")])])])
        let snapshot = CodexConfigSnapshot(user: .object([:]), effective: effective, version: "0",
                                           file: URL(fileURLWithPath: "/tmp/config.toml"))
        XCTAssertEqual(snapshot.providerIdentity.name, "Inherited gateway")
        var profile = CodexModelProfile(name: "Saved reference", kind: .reference, providerName: "Inherited gateway")
        profile.referencedProvider = "gateway"
        XCTAssertTrue(profile.matchesProvider(snapshot))
        XCTAssertEqual(profile.providerIdentity.name, "Inherited gateway")
        XCTAssertFalse(profile.providerIdentity.isOfficial)
    }

    func testSavedProviderDefaultMatchIsIndependentOfSelectionOrName() {
        let profile = custom()
        var user: [String: JSONValue] = ["model": .string(profile.model), "model_provider": .string("external"),
            "model_reasoning_effort": .string(profile.reasoning), "model_providers": .object(["external": profile.provider])]
        let snapshot = CodexConfigSnapshot(user: .object(user), version: "0", file: URL(fileURLWithPath: "/tmp/config.toml"))
        var saved = profile
        saved.name = "Renamed connection"
        XCTAssertTrue(saved.matches(snapshot))
        user["model"] = .string("different")
        XCTAssertFalse(saved.matches(CodexConfigSnapshot(user: .object(user), version: "1", file: snapshot.file)))
    }

    func testOfficialPatchClearsRedirectAndOverridesWithoutTouchingOtherSettings() throws {
        let snapshot = CodexConfigSnapshot(user: .object(["model": .string("old"), "openai_base_url": .string("https://old.example.invalid/v1"),
            "model_reasoning_effort": .string("high"), "mcp_servers": .object(["untouched": .object(["command": .string("fixture")])])]),
            version: "0", file: URL(fileURLWithPath: "/tmp/config.toml"))
        let edits = try ModelProfilePatch.edits(for: CodexModelProfile(name: "Official"), snapshot: snapshot)
        XCTAssertEqual(edits.first { $0.keyPath == "openai_base_url" }?.value, .null)
        XCTAssertEqual(edits.first { $0.keyPath == "model_reasoning_effort" }?.value, .null)
        XCTAssertFalse(edits.contains { $0.keyPath.hasPrefix("mcp_servers") })
    }

    func testCustomContextPatchIsIndependentOfAuthentication() throws {
        let snapshot = CodexConfigSnapshot(user: .object(["model_context_window": .number(200000)]),
            version: "0", file: URL(fileURLWithPath: "/tmp/config.toml"))
        for authentication in ModelProfileAuthentication.allCases {
            var profile = custom(); profile.authentication = authentication
            profile.credentialReference = CredentialReference(); profile.helperPath = "/tmp/fixture-helper"
            profile.contextWindow = 8192
            let explicit = try ModelProfilePatch.edits(for: profile, snapshot: snapshot)
            XCTAssertEqual(explicit.first { $0.keyPath == "model_context_window" }?.value, .number(8192))
            profile.contextWindow = nil
            let automatic = try ModelProfilePatch.edits(for: profile, snapshot: snapshot)
            XCTAssertEqual(automatic.first { $0.keyPath == "model_context_window" }?.value, .null)
        }
    }

    func testTypedProviderDefaultsDoNotBreakRawUserConfigurationMatch() {
        let profile = custom()
        let user = JSONValue.object(["model": .string(profile.model), "model_provider": .string(profile.providerID),
            "model_reasoning_effort": .string(profile.reasoning), "model_providers": .object([profile.providerID: profile.provider])])
        var effective = user.object!
        var provider = profile.provider.object!
        provider["request_max_retries"] = .number(4)
        provider["http_headers"] = .null
        effective["model_providers"] = .object([profile.providerID: .object(provider)])
        let snapshot = CodexConfigSnapshot(user: user, effective: .object(effective), version: "0", file: URL(fileURLWithPath: "/tmp/config.toml"))
        XCTAssertTrue(profile.matches(snapshot))
    }

    func testExternalProviderAuthenticationIsNotOverwrittenOrBackedUp() throws {
        let profile = custom()
        var provider = profile.provider.object!
        provider["experimental_bearer_token"] = .string("PRIVATE_FIXTURE_TOKEN")
        let snapshot = CodexConfigSnapshot(user: .object(["model_providers": .object([profile.providerID: .object(provider)])]),
                                           version: "0", file: URL(fileURLWithPath: "/tmp/config.toml"))
        XCTAssertThrowsError(try ModelProfilePatch.edits(for: profile, snapshot: snapshot)) {
            XCTAssertEqual($0 as? ModelProfileFailure, .changed)
        }
    }

    func testStructuredErrorsNeverExposeBackendData() {
        for code in ["configVersionConflict", "configValidationError", "unknown"] {
            let error = ModelProfileFailure.rpc(.object(["code": .number(-32600), "message": .string("PRIVATE_ACCOUNT_SECRET"),
                "data": .object(["config_write_error_code": .string(code), "credential": .string("PRIVATE_TOKEN")])]))
            XCTAssertFalse(error.localizedDescription.contains("PRIVATE"))
        }
    }

    func testLibraryPersistenceAndDirectoryIsolationUsePrivatePermissions() async throws {
        let home = try temporary(), second = try temporary()
        let fixture = ModelConfigurationFixture(home: home)
        let service = CodexModelProfileService(transport: fixture, root: home.appendingPathComponent("library"))
        let profile = custom()
        _ = try await service.saveProfiles([profile], home: home)
        let restored = try await service.library(home: home)
        let isolated = try await service.library(home: second)
        XCTAssertEqual(restored.profiles, [profile])
        XCTAssertTrue(isolated.profiles.isEmpty)
        let url = await service.libraryURL(home: home)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let writes = await fixture.writeCount
        XCTAssertEqual(writes, 0)
    }

    func testProviderReselectionRetainsUnrelatedExternalChangesAndSurvivesRelaunch() async throws {
        let home = try temporary(), location = CodexLocation(home: home, executable: nil)
        let fixture = ModelConfigurationFixture(home: home)
        let root = home.appendingPathComponent("library")
        let service = CodexModelProfileService(transport: fixture, root: root)
        let original = try await service.read(location: location)
        let applied = try await service.apply(custom(), location: location, expectedVersion: original.snapshot.version)
        XCTAssertNil(applied.library.pending)
        await fixture.change("unrelated", to: .string("preserve"))
        let reopened = CodexModelProfileService(transport: fixture, root: root)
        let current = try await reopened.read(location: location)
        let restored = try await reopened.restoreOpenAI(location: location, expectedVersion: current.snapshot.version)
        XCTAssertEqual(restored.snapshot.user["model"].string, "original")
        XCTAssertEqual(restored.snapshot.user["unrelated"].string, "preserve")
        XCTAssertNil(restored.snapshot.user["model_provider"].string)
        XCTAssertNil(restored.library.pending)
    }

    func testStaleApplyNeverOverwritesExternalFields() async throws {
        let home = try temporary(), location = CodexLocation(home: home, executable: nil)
        let fixture = ModelConfigurationFixture(home: home)
        let service = CodexModelProfileService(transport: fixture, root: home.appendingPathComponent("library"))
        await fixture.change("model", to: .string("external"))
        do { _ = try await service.apply(custom(), location: location, expectedVersion: "0"); XCTFail("expected conflict") }
        catch { XCTAssertEqual(error as? ModelProfileFailure, .conflict) }
        let read = try await service.read(location: location)
        let applied = try await service.apply(custom(), location: location, expectedVersion: read.snapshot.version)
        await fixture.change("model", to: .string("external-again"))
        do { _ = try await service.restoreOpenAI(location: location, expectedVersion: applied.snapshot.version); XCTFail("expected conflict") }
        catch { XCTAssertEqual(error as? ModelProfileFailure, .conflict) }
        let after = try await fixture.readConfiguration(location: location)
        XCTAssertEqual(after.user["model"].string, "external-again")
        let writes = await fixture.writeCount
        XCTAssertEqual(writes, 1)
    }

    func testTimeoutAfterCommitIsVerifiedWithoutSecondWrite() async throws {
        let home = try temporary(), location = CodexLocation(home: home, executable: nil)
        let fixture = ModelConfigurationFixture(home: home)
        await fixture.configure(.commitThenThrow)
        let service = CodexModelProfileService(transport: fixture, root: home.appendingPathComponent("library"))
        let context = try await service.apply(custom(), location: location, expectedVersion: "0")
        XCTAssertEqual(context.snapshot.user["model"].string, "coding-model")
        XCTAssertNil(context.library.pending)
        let writes = await fixture.writeCount
        XCTAssertEqual(writes, 1)
    }

    func testInterruptedApplyRecoversPersistedPendingOperation() async throws {
        let home = try temporary(), location = CodexLocation(home: home, executable: nil)
        let fixture = ModelConfigurationFixture(home: home)
        await fixture.configure(.commitThenDisconnect)
        let root = home.appendingPathComponent("library")
        let service = CodexModelProfileService(transport: fixture, root: root)
        do { _ = try await service.apply(custom(), location: location, expectedVersion: "0"); XCTFail("expected disconnection") }
        catch { XCTAssertEqual(error as? ModelProfileFailure, .unavailable) }
        let saved = try await service.library(home: home)
        XCTAssertNotNil(saved.pending)
        let reopened = CodexModelProfileService(transport: fixture, root: root)
        let recovered = try await reopened.read(location: location)
        XCTAssertNil(recovered.library.pending)
        XCTAssertEqual(recovered.snapshot.user["model"].string, "coding-model")
        let writes = await fixture.writeCount
        XCTAssertEqual(writes, 1)
    }

    func testLegacyPendingInverseTransactionIsRecoveredAfterRelaunch() async throws {
        let home = try temporary(), location = CodexLocation(home: home, executable: nil)
        let fixture = ModelConfigurationFixture(home: home)
        let root = home.appendingPathComponent("library")
        let service = CodexModelProfileService(transport: fixture, root: root)
        let file = await service.libraryURL(home: home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Older builds marked automatic inverse writes as isUndo. They must
        // remain recoverable even though manual Undo is no longer supported.
        let legacy: [String: Any] = ["schemaVersion": 3, "connections": [],
            "pending": ["before": [["keyPath": "model", "value": "partial"]],
                        "after": [["keyPath": "model", "value": "original"]],
                        "completed": false, "isUndo": true]]
        try JSONSerialization.data(withJSONObject: legacy).write(to: file)
        let recovered = try await service.read(location: location)
        XCTAssertNil(recovered.library.pending)
        XCTAssertEqual(recovered.snapshot.user["model"].string, "original")
        let writes = await fixture.writeCount
        XCTAssertEqual(writes, 0)
    }

    func testRejectedWriteRetainsCurrentConfiguration() async throws {
        let home = try temporary(), location = CodexLocation(home: home, executable: nil)
        let fixture = ModelConfigurationFixture(home: home)
        let service = CodexModelProfileService(transport: fixture, root: home.appendingPathComponent("library"))
        let first = try await service.apply(custom(), location: location, expectedVersion: "0")
        await fixture.configure(.reject)
        do { _ = try await service.apply(CodexModelProfile(name: "Official"), location: location, expectedVersion: first.snapshot.version); XCTFail() }
        catch { XCTAssertEqual(error as? ModelProfileFailure, .invalid) }
        let retained = try await service.library(home: home)
        let current = try await fixture.readConfiguration(location: location)
        XCTAssertEqual(current, first.snapshot)
        XCTAssertNil(retained.pending)
    }

    func testStorageFailurePreventsAnyCodexWrite() async throws {
        let home = try temporary(), location = CodexLocation(home: home, executable: nil)
        let fixture = ModelConfigurationFixture(home: home)
        let file = home.appendingPathComponent("not-a-directory")
        try Data().write(to: file)
        let service = CodexModelProfileService(transport: fixture, root: file)
        do { _ = try await service.apply(custom(), location: location, expectedVersion: "0"); XCTFail() }
        catch { XCTAssertEqual(error as? ModelProfileFailure, .storage) }
        let writes = await fixture.writeCount
        XCTAssertEqual(writes, 0)
    }
}

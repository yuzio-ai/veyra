import Foundation
import XCTest

@MainActor
final class CodexModelProfilesStoreTests: XCTestCase {
    private func fixture() throws -> (URL, CodexLocation, ModelConfigurationFixture, CodexModelProfilesStore) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("veyra-profile-store-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let transport = ModelConfigurationFixture(home: home)
        let service = CodexModelProfileService(transport: transport, root: home.appendingPathComponent("library"), credentials: MemoryCredentialStore(),
            helperExecutable: URL(fileURLWithPath: "/Applications/Veyra.app/Contents/MacOS/Veyra"), capability: { _ in true })
        return (home, CodexLocation(home: home, executable: nil), transport, CodexModelProfilesStore(service: service))
    }

    func testSaveRenameDuplicateDeleteNeverChangeCodexDefault() async throws {
        let (_, location, transport, store) = try fixture()
        await store.load(location: location)
        store.importCurrent()
        XCTAssertTrue(store.hasUnsavedChanges)
        let imported = await store.saveDraft()
        XCTAssertTrue(imported)
        XCTAssertFalse(store.hasUnsavedChanges)
        XCTAssertEqual(store.defaultName, L10n.text("Current configuration"))
        store.draft?.name = "Renamed"
        let renamed = await store.saveDraft()
        XCTAssertTrue(renamed)
        XCTAssertEqual(store.defaultName, "Renamed")
        store.duplicate()
        XCTAssertNotEqual(store.draft?.id, store.profiles.first?.id)
        let duplicated = await store.saveDraft()
        XCTAssertTrue(duplicated)
        XCTAssertEqual(store.profiles.count, 2)
        await store.deleteSelected()
        XCTAssertEqual(store.profiles.count, 1)
        let writes = await transport.writeCount
        XCTAssertEqual(writes, 0)
    }

    func testCurrentProviderSurvivesDefaultModelChangeAndUsesExactConnectionIdentity() {
        let store = CodexModelProfilesStore.preview("provider-custom")
        let current = store.profiles[1]
        XCTAssertEqual(store.currentProviderProfileID, current.id)
        XCTAssertEqual(store.defaultProviderIdentity.name, "Development gateway")
        XCTAssertNotEqual(store.defaultProviderIdentity.name, store.snapshot?.user["model"].string)
        var copy = current
        copy.id = UUID(); copy.model = "different-model"
        store.library.profiles.append(copy)
        XCTAssertEqual(store.currentProviderProfileID, current.id)
        // Imported connections have different generated IDs; equal connections are ambiguous.
        store.snapshot?.user = .object(["model_provider": .string("external"),
            "model_providers": .object(["external": current.provider])])
        let user = store.snapshot!.user
        store.snapshot?.effective = user
        XCTAssertNil(store.currentProviderProfileID)
        XCTAssertEqual(store.defaultProviderIdentity.name, "Development gateway")
    }

    func testDuplicateOfficialConnectionsAreNotArbitrarilyChecked() {
        let store = CodexModelProfilesStore.preview()
        var copy = store.profiles[0]
        copy.id = UUID(); copy.name = "Second official"; copy.model = "different"
        store.library.profiles.append(copy)
        XCTAssertNil(store.currentProviderProfileID)
        XCTAssertEqual(store.defaultProviderIdentity.name, "OpenAI")
        XCTAssertTrue(store.defaultProviderIdentity.isOfficial)
        XCTAssertNotEqual(store.providerTitle(store.profiles[0]), store.providerTitle(copy))
    }

    func testProviderTitlesDisambiguateConnectionsWithoutRenamingSavedData() {
        let store = CodexModelProfilesStore.preview("provider-custom")
        let original = store.profiles[1]
        var copy = original
        copy.id = UUID(uuidString: "12345678-0000-0000-0000-000000000001")!
        var other = copy
        other.id = UUID(uuidString: "12345678-0000-0000-0000-000000000002")!
        store.library.profiles += [copy, other]
        let before = store.library
        let titles = [original, copy, other].map { store.providerTitle($0) }
        XCTAssertEqual(Set(titles).count, 3)
        XCTAssertTrue(titles.allSatisfy { $0.hasPrefix("Development gateway · ") })
        XCTAssertEqual(store.library, before)
    }

    func testUnavailableProviderNeverDisplaysRecordedModel() {
        let store = CodexModelProfilesStore.preview("provider-unavailable")
        XCTAssertNil(store.currentProviderProfileID)
        XCTAssertEqual(store.defaultProviderIdentity.name, L10n.text("Configuration unavailable"))
        XCTAssertFalse(store.defaultProviderIdentity.isOfficial)
    }

    func testProviderSwitchAppliesItsDefaultModelAndUndoRestoresBoth() async throws {
        let (_, location, _, store) = try fixture()
        await store.load(location: location)
        store.newProfile()
        store.draft?.name = "Connection"
        store.draft?.providerName = "Gateway"
        store.draft?.baseURL = "https://gateway.example.invalid/v1"
        store.draft?.model = "gateway-default"
        store.draft?.reasoning = "high"
        store.apiKeyInput = "fixture-key"
        let saved = await store.saveDraft()
        XCTAssertTrue(saved)
        let id = try XCTUnwrap(store.draft?.id)
        await store.applyDraft()
        XCTAssertEqual(store.currentProviderProfileID, id)
        XCTAssertEqual(store.defaultProviderIdentity.name, "Gateway")
        XCTAssertEqual(store.snapshot?.user["model"].string, "gateway-default")
        XCTAssertEqual(store.snapshot?.user["model_reasoning_effort"].string, "high")
        XCTAssertTrue(store.canUndo)
        await store.undo()
        XCTAssertEqual(store.snapshot?.user["model"].string, "original")
        XCTAssertEqual(store.defaultProviderIdentity.name, "OpenAI")
        XCTAssertNil(store.currentProviderProfileID)
    }

    func testUnsavedNavigationSupportsCancelDiscardAndSave() async throws {
        let (_, location, _, store) = try fixture()
        await store.load(location: location)
        store.importCurrent()
        _ = await store.saveDraft()
        let original = store.draft
        store.draft?.model = "unsaved"
        store.navigate { store.tab = .models }
        XCTAssertTrue(store.showUnsavedPrompt)
        store.cancelNavigation()
        XCTAssertEqual(store.draft?.model, "unsaved")
        XCTAssertEqual(store.tab, .general)
        store.navigate { store.tab = .models }
        await store.resolveNavigation(save: false)
        XCTAssertEqual(store.draft, original)
        XCTAssertEqual(store.tab, .models)
        store.draft?.model = "saved"
        store.navigate { store.tab = .general }
        await store.resolveNavigation(save: true)
        XCTAssertEqual(store.profiles.first?.model, "saved")
        XCTAssertEqual(store.tab, .general)
        XCTAssertFalse(store.hasUnsavedChanges)
    }

    func testInvalidDraftAndDuplicateNameStayEditable() async throws {
        let (_, location, _, store) = try fixture()
        await store.load(location: location)
        store.importCurrent()
        _ = await store.saveDraft()
        store.newProfile()
        let saved = await store.saveDraft()
        XCTAssertFalse(saved)
        XCTAssertTrue(store.attemptedValidation)
        XCTAssertNotNil(store.fieldErrors["model"])
        store.draft?.kind = .official
        store.draft?.name = store.profiles[0].name
        XCTAssertNotNil(store.fieldErrors["name"])
    }

    func testSelectionAndSavingDoNotSetDefaultButApplyDoes() async throws {
        let (_, location, _, store) = try fixture()
        await store.load(location: location)
        store.importCurrent()
        _ = await store.saveDraft()
        store.duplicate()
        store.draft?.model = "new-model"
        _ = await store.saveDraft()
        XCTAssertEqual(store.snapshot?.user["model"].string, "original")
        XCTAssertNotEqual(store.defaultName, store.draft?.name)
        await store.applyDraft()
        XCTAssertEqual(store.snapshot?.user["model"].string, "new-model")
        XCTAssertEqual(store.defaultName, store.draft?.name)
        XCTAssertTrue(store.canUndo)
        await store.undo()
        XCTAssertEqual(store.snapshot?.user["model"].string, "original")
        XCTAssertFalse(store.canUndo)
    }

    func testRapidApplyIsSerializedAndHomeChangeDropsOldSelection() async throws {
        let (home, location, transport, store) = try fixture()
        await store.load(location: location)
        store.importCurrent()
        store.draft?.model = "next"
        _ = await store.saveDraft()
        await transport.configure(.normal, delay: .milliseconds(100))
        let task = Task { await store.applyDraft() }
        for _ in 0..<100 {
            if store.busy { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        await store.applyDraft()
        await task.value
        let writes = await transport.writeCount
        XCTAssertEqual(writes, 1)
        let another = home.appendingPathComponent("another-home")
        await store.load(location: CodexLocation(home: another, executable: nil))
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertNil(store.draft)
    }

    func testExternalModificationReloadsWithoutChangingDraft() async throws {
        let (_, location, transport, store) = try fixture()
        await store.load(location: location)
        store.importCurrent()
        store.draft?.model = "desired"
        _ = await store.saveDraft()
        await transport.change("model", to: .string("external"))
        await store.applyDraft()
        XCTAssertEqual(store.draft?.model, "desired")
        XCTAssertEqual(store.snapshot?.user["model"].string, "external")
        XCTAssertNotNil(store.error)
        let writes = await transport.writeCount
        XCTAssertEqual(writes, 0)
    }

    func testProviderReadinessUsesOnlyThreeStates() {
        let current = CodexModelProfilesStore.preview("preset-current")
        XCTAssertEqual(current.providerReadiness(ProviderPreset.all[0]), .inUse)
        XCTAssertNil(current.providerIssue(ProviderPreset.all[0]))

        let configured = CodexModelProfilesStore.preview("preset")
        XCTAssertEqual(configured.providerReadiness(ProviderPreset.all[0]), .configured)

        let empty = CodexModelProfilesStore.preview("preset-empty")
        XCTAssertEqual(empty.providerReadiness(ProviderPreset.all[0]), .notConfigured)
        XCTAssertNil(empty.providerIssue(ProviderPreset.all[0]))
    }

    func testProviderIssueReportsOneReasonByPriority() {
        let locked = CodexModelProfilesStore.preview("preset-error")
        XCTAssertEqual(locked.providerIssue(ProviderPreset.all[0]), CredentialFailure.locked.localizedDescription)

        let unsupported = CodexModelProfilesStore.preview("preset-unsupported")
        XCTAssertEqual(unsupported.providerIssue(ProviderPreset.all[0]),
                       L10n.text("This Codex executable does not support Keychain credential commands. Update Codex or select its native executable in General."))

        let moved = CodexModelProfilesStore.preview("preset-repair")
        XCTAssertEqual(moved.providerReadiness(ProviderPreset.all[0]), .inUse)
        XCTAssertEqual(moved.providerIssue(ProviderPreset.all[0]),
                       L10n.text("Veyra moved. Re-enable this provider to repair the credential path."))

        let rejected = CodexModelProfilesStore.preview("preset-auth")
        XCTAssertEqual(rejected.providerIssue(ProviderPreset.all[0]),
                       L10n.text("The provider rejected the saved Key. Update it, then refresh models."))
    }

    func testExecutablePathMatchesEquivalentSpellings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("veyra-path-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("Veyra")
        try Data().write(to: target)
        let link = directory.appendingPathComponent("Veyra link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertTrue(ExecutablePath.matches(target.path, target.path))
        XCTAssertTrue(ExecutablePath.matches(link.path, target.path), "a symlink to the same binary is not a move")
        XCTAssertTrue(ExecutablePath.matches(directory.path + "/./Veyra", target.path), "redundant segments are normalized")
        let probe = "/private/tmp/veyra-path-probe-" + UUID().uuidString
        try Data().write(to: URL(fileURLWithPath: probe))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: probe) }
        XCTAssertTrue(ExecutablePath.matches(probe, probe.replacingOccurrences(of: "/private/tmp/", with: "/tmp/")),
                      "the /tmp spelling is canonicalized before comparing")
        XCTAssertFalse(ExecutablePath.matches(directory.appendingPathComponent("Other").path, target.path))
        XCTAssertFalse(ExecutablePath.matches(nil, target.path), "a missing recorded path keeps the repair prompt")
        XCTAssertFalse(ExecutablePath.matches(target.path, nil))
    }
}

import Foundation
import XCTest

@MainActor
final class CodexModelProfilesStoreTests: XCTestCase {
    private func fixture(clock: PollingClock = .continuous()) throws -> (URL, CodexLocation, ModelConfigurationFixture, CodexModelProfilesStore) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("veyra-profile-store-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let transport = ModelConfigurationFixture(home: home)
        let service = CodexModelProfileService(transport: transport, root: home.appendingPathComponent("library"), credentials: MemoryCredentialStore(),
            helperExecutable: URL(fileURLWithPath: "/Applications/Veyra.app/Contents/MacOS/Veyra"), capability: { _ in true })
        return (home, CodexLocation(home: home, executable: nil), transport, CodexModelProfilesStore(service: service, configurationClock: clock))
    }

    private func beginLegacyConnectionDraft(_ store: CodexModelProfilesStore) {
        store.chooseWorkspace(.create)
        store.providerDraft = ProviderSettings(profile: CodexModelProfile(name: "Legacy official", model: "original"))
    }

    func testSaveRenameDuplicateDeleteNeverChangeCodexDefault() async throws {
        let (_, location, transport, store) = try fixture()
        await store.load(location: location); store.activateWorkspace()
        beginLegacyConnectionDraft(store)
        XCTAssertTrue(store.hasUnsavedChanges)
        let saved = await store.saveWorkspace(); XCTAssertTrue(saved)
        let originalID = try XCTUnwrap(store.providerDraft?.id)
        XCTAssertFalse(store.hasUnsavedChanges)
        store.providerDraft?.name = "Renamed"
        let renamed = await store.saveWorkspace(); XCTAssertTrue(renamed)
        XCTAssertEqual(store.savedConnection?.displayName, "Renamed")
        store.duplicateWorkspace()
        XCTAssertNotEqual(store.providerDraft?.id, originalID)
        store.providerDraft?.baseURL = "http://localhost:11434/v1"
        store.providerDraft?.authentication = ModelProfileAuthentication.none
        let duplicated = await store.saveWorkspace(); XCTAssertTrue(duplicated)
        XCTAssertEqual(store.customConnections.count, 2)
        await store.deleteWorkspace()
        XCTAssertEqual(store.customConnections.count, 1)
        XCTAssertEqual(store.snapshot?.user["model"].string, "original")
        let writes = await transport.writeCount; XCTAssertEqual(writes, 0)
    }

    func testSavingAndApplyingLegacyConnectionPreservesHiddenIdentityAndCatalog() async throws {
        let (home, location, _, store) = try fixture()
        await store.load(location: location); store.activateWorkspace()
        beginLegacyConnectionDraft(store)
        let catalog = home.appendingPathComponent("legacy-catalog.json")
        try Data("{\"models\":[]}".utf8).write(to: catalog)
        store.providerDraft?.legacyProfile?.catalogPath = catalog.path
        let id = try XCTUnwrap(store.providerDraft?.id)
        let providerID = try XCTUnwrap(store.providerDraft?.codexProviderID)
        let saved = await store.saveWorkspace(); XCTAssertTrue(saved)
        store.providerDraft?.name = "Renamed legacy connection"
        store.providerDraft?.model = "updated-model"
        let renamed = await store.saveWorkspace(); XCTAssertTrue(renamed)
        await store.reloadWorkspace(location: location)
        XCTAssertEqual(store.savedConnection?.id, id)
        XCTAssertEqual(store.savedConnection?.codexProviderID, providerID)
        XCTAssertEqual(store.savedConnection?.legacyProfile?.catalogPath, catalog.path)
        await store.requestWorkspaceApply()
        XCTAssertNil(store.error)
        XCTAssertEqual(store.snapshot?.user["model"].string, "updated-model")
        XCTAssertEqual(store.snapshot?.user["model_catalog_json"].string, catalog.path)
    }

    func testOfficialEditorRetainsCurrentAndRestorableHiddenCatalog() async throws {
        for switchToCustom in [false, true] {
            let (home, location, transport, store) = try fixture()
            let catalog = home.appendingPathComponent("official-catalog.json").path
            await transport.change("model_catalog_json", to: .string(catalog))
            await store.load(location: location); store.activateWorkspace()
            if switchToCustom {
                store.chooseWorkspace(.create)
                store.providerDraft?.name = "Local gateway"
                store.providerDraft?.baseURL = "http://localhost:11434/v1"
                store.providerDraft?.authentication = ModelProfileAuthentication.none
                store.providerDraft?.model = "local-model"
                let saved = await store.saveWorkspace(); XCTAssertTrue(saved)
                await store.applyWorkspace()
                XCTAssertNil(store.error)
            }
            store.chooseWorkspace(.official)
            XCTAssertEqual(store.providerDraft?.legacyProfile?.catalogPath, catalog)
            await store.requestWorkspaceApply()
            XCTAssertNil(store.error)
            XCTAssertEqual(store.snapshot?.user["model_catalog_json"].string, catalog)
            XCTAssertTrue(store.defaultProviderIdentity.isOfficial)
        }
    }

    func testUnsupportedProtocolCanBeCorrectedWithoutReplacingIdentityOrCredential() async throws {
        let (_, location, transport, store) = try fixture()
        await store.load(location: location); store.activateWorkspace()
        store.chooseWorkspace(.create)
        store.providerDraft?.name = "Existing gateway"
        store.providerDraft?.baseURL = "https://gateway.example.invalid/v1"
        store.providerDraft?.model = "fixture-model"
        store.providerDraft?.wireAPI = "chat"
        store.apiKeyInput = "fixture-key"
        let saved = await store.saveWorkspace(); XCTAssertTrue(saved)
        let original = try XCTUnwrap(store.savedConnection)
        let snapshot = store.snapshot
        XCTAssertFalse(store.canApplyWorkspace)
        store.busy = true
        store.useResponsesProtocol()
        XCTAssertEqual(store.providerDraft?.protocolName, "chat")
        store.busy = false
        store.useResponsesProtocol()
        XCTAssertTrue(store.hasUnsavedChanges)
        XCTAssertEqual(store.providerDraft?.id, original.id)
        XCTAssertEqual(store.providerDraft?.credential, original.credential)
        XCTAssertEqual(store.savedConnection?.protocolName, "chat")
        XCTAssertEqual(store.snapshot, snapshot)
        store.cancelWorkspaceEdits()
        XCTAssertEqual(store.providerDraft, original)
        XCTAssertFalse(store.canApplyWorkspace)
        store.useResponsesProtocol()
        await store.requestWorkspaceApply()
        XCTAssertTrue(store.showUnverifiedPrompt)
        XCTAssertEqual(store.savedConnection?.protocolName, "responses")
        XCTAssertEqual(store.snapshot, snapshot)
        let writesBeforeConfirmation = await transport.writeCount
        XCTAssertEqual(writesBeforeConfirmation, 0)
        await store.applyWorkspace()
        XCTAssertNil(store.error)
        XCTAssertEqual(store.savedConnection?.id, original.id)
        XCTAssertEqual(store.savedConnection?.credential, original.credential)
        XCTAssertEqual(store.snapshot?.configuredProviderID, original.codexProviderID)
        XCTAssertEqual(store.snapshot?.configuredProvider["wire_api"].string, "responses")
    }

    func testFailedWorkspaceReloadRetainsDraftAndFailure() async throws {
        let clock = TestPollingClock()
        let (_, location, transport, store) = try fixture(clock: clock.clock)
        await store.load(location: location); store.activateWorkspace()
        store.providerDraft?.model = "unsaved-model"
        let draft = store.providerDraft
        await transport.configureReadFailures(1)
        await store.reloadWorkspace(location: location)
        XCTAssertNotNil(store.error)
        XCTAssertEqual(store.providerDraft, draft)
        XCTAssertTrue(store.hasUnsavedChanges)
        clock.finish(); await settleHeader()
    }

    func testKeyRemovalCannotOverwriteNewDirectoryDraft() async throws {
        try await verifyRemovalDuringDirectorySwitch(removingKey: true)
    }

    func testProviderDeletionCannotOverwriteNewDirectoryDraft() async throws {
        try await verifyRemovalDuringDirectorySwitch(removingKey: false)
    }

    func testLateApplyFeedbackCannotOverwriteNewDirectoryFailure() async throws {
        let clock = TestPollingClock()
        let (home, location, transport, store) = try fixture(clock: clock.clock)
        await store.load(location: location); store.activateWorkspace()
        store.chooseWorkspace(.create)
        store.providerDraft?.name = "Gateway"
        store.providerDraft?.baseURL = "http://localhost:11434/v1"
        store.providerDraft?.model = "fixture-model"
        store.providerDraft?.authentication = ModelProfileAuthentication.none
        let saved = await store.saveWorkspace(); XCTAssertTrue(saved)
        await transport.configure(.normal, delay: .milliseconds(100))
        let applying = Task { await store.applyWorkspace() }
        for _ in 0..<200 {
            if await transport.writeCount > 0 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let newLocation = CodexLocation(home: home.appendingPathComponent("new-home"), executable: nil)
        await store.load(location: newLocation)
        let failure = store.error
        XCTAssertNotNil(failure)
        await applying.value
        XCTAssertEqual(store.location, newLocation)
        XCTAssertEqual(store.error, failure)
        XCTAssertTrue(store.applyErrors.isEmpty)
        clock.finish(); await settleHeader()
    }

    private func verifyRemovalDuringDirectorySwitch(removingKey: Bool) async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("veyra-removal-generation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let clock = TestPollingClock()
        let transport = DirectorySwitchConfigurationTransport(firstHome: home)
        let service = CodexModelProfileService(transport: transport, root: home.appendingPathComponent("library"), credentials: MemoryCredentialStore())
        let store = CodexModelProfilesStore(service: service, configurationClock: clock.clock)
        let location = CodexLocation(home: home, executable: nil)
        await store.load(location: location); store.activateWorkspace()
        store.chooseWorkspace(.create)
        store.providerDraft?.name = "Old directory provider"
        store.providerDraft?.baseURL = "https://gateway.example.invalid/v1"
        store.providerDraft?.model = "fixture-model"
        store.apiKeyInput = "fixture-key"
        let saved = await store.saveWorkspace(); XCTAssertTrue(saved)
        await transport.holdOldRead()
        let removal = Task {
            if removingKey { await store.removeWorkspaceKey() }
            else { await store.deleteWorkspace() }
        }
        for _ in 0..<200 {
            if await transport.oldReadIsWaiting { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let waiting = await transport.oldReadIsWaiting; XCTAssertTrue(waiting)
        let newLocation = CodexLocation(home: home.appendingPathComponent("new-home"), executable: nil)
        await store.load(location: newLocation)
        store.chooseWorkspace(.create)
        store.providerDraft?.name = "New directory draft"
        let draft = store.providerDraft
        let library = store.library
        await transport.releaseOldRead()
        await removal.value
        XCTAssertEqual(store.location, newLocation)
        XCTAssertEqual(store.providerDraft, draft)
        XCTAssertEqual(store.library, library)
        clock.finish(); await settleHeader()
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

    func testProviderSwitchAppliesItsDefaultModelAndOfficialSelectionRestoresBoth() async throws {
        let (_, location, _, store) = try fixture()
        await store.load(location: location); store.activateWorkspace()
        store.chooseWorkspace(.create)
        store.providerDraft?.name = "Gateway"
        store.providerDraft?.baseURL = "http://localhost:11434/v1"
        store.providerDraft?.model = "gateway-default"
        store.providerDraft?.authentication = ModelProfileAuthentication.none
        store.providerDraft?.contextWindowOverride = 8192
        let saved = await store.saveWorkspace(); XCTAssertTrue(saved)
        await store.requestWorkspaceApply()
        XCTAssertTrue(store.showUnverifiedPrompt)
        await store.applyWorkspace()
        XCTAssertEqual(store.defaultProviderIdentity.name, "Gateway")
        XCTAssertEqual(store.snapshot?.user["model"].string, "gateway-default")
        XCTAssertEqual(store.snapshot?.user["model_context_window"].integer, 8192)
        await store.restoreOpenAI()
        XCTAssertEqual(store.snapshot?.user["model"].string, "original")
        XCTAssertEqual(store.defaultProviderIdentity.name, "OpenAI")
    }

    func testUnsavedNavigationSupportsCancelDiscardAndSave() async throws {
        let (_, location, _, store) = try fixture()
        await store.load(location: location); store.activateWorkspace()
        beginLegacyConnectionDraft(store)
        _ = await store.saveWorkspace()
        let original = store.providerDraft
        store.providerDraft?.model = "unsaved"
        store.navigate { store.tab = .models }
        XCTAssertTrue(store.showUnsavedPrompt)
        store.cancelNavigation()
        XCTAssertEqual(store.providerDraft?.model, "unsaved")
        XCTAssertEqual(store.tab, .general)
        store.navigate { store.tab = .models }
        await store.resolveNavigation(save: false)
        XCTAssertEqual(store.providerDraft, original)
        XCTAssertEqual(store.tab, .models)
        store.providerDraft?.model = "saved"
        store.navigate { store.tab = .general }
        await store.resolveNavigation(save: true)
        XCTAssertEqual(store.savedConnection?.model, "saved")
        XCTAssertEqual(store.tab, .general)
        XCTAssertFalse(store.hasUnsavedChanges)
    }

    func testInvalidDraftStaysEditableAndCannotBeSaved() async throws {
        let (_, location, transport, store) = try fixture()
        await store.load(location: location); store.activateWorkspace()
        store.chooseWorkspace(.create)
        store.providerDraft?.name = "Invalid gateway"
        store.providerDraft?.baseURL = "invalid"
        let saved = await store.saveWorkspace()
        XCTAssertFalse(saved); XCTAssertTrue(store.attemptedValidation)
        XCTAssertNotNil(store.workspaceErrors["baseURL"])
        XCTAssertEqual(store.providerDraft?.baseURL, "invalid")
        XCTAssertTrue(store.library.connections.isEmpty)
        let writes = await transport.writeCount; XCTAssertEqual(writes, 0)
    }

    func testSelectionAndSavingDoNotSetDefaultButApplyDoes() async throws {
        let (_, location, _, store) = try fixture()
        await store.load(location: location); store.activateWorkspace()
        beginLegacyConnectionDraft(store)
        _ = await store.saveWorkspace()
        store.providerDraft?.model = "new-model"
        _ = await store.saveWorkspace()
        XCTAssertEqual(store.snapshot?.user["model"].string, "original")
        await store.requestWorkspaceApply()
        XCTAssertEqual(store.snapshot?.user["model"].string, "new-model")
        XCTAssertNil(store.library.pending)
    }

    func testRapidApplyIsSerializedAndHomeChangeDropsOldSelection() async throws {
        let (home, location, transport, store) = try fixture()
        await store.load(location: location); store.activateWorkspace()
        beginLegacyConnectionDraft(store); store.providerDraft?.model = "next"
        _ = await store.saveWorkspace()
        await transport.configure(.normal, delay: .milliseconds(100))
        let task = Task { await store.applyWorkspace() }
        for _ in 0..<100 {
            if store.busy { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        await store.applyWorkspace(); await task.value
        let writes = await transport.writeCount; XCTAssertEqual(writes, 1)
        await store.load(location: CodexLocation(home: home.appendingPathComponent("another-home"), executable: nil))
        XCTAssertTrue(store.library.connections.isEmpty)
        XCTAssertNotEqual(store.providerDraft?.model, "next")
        XCTAssertFalse(store.hasUnsavedChanges)
    }

    func testExternalModificationReloadsWithoutChangingDraft() async throws {
        let (_, location, transport, store) = try fixture()
        await store.load(location: location); store.activateWorkspace()
        beginLegacyConnectionDraft(store); store.providerDraft?.model = "desired"
        _ = await store.saveWorkspace()
        await transport.change("model", to: .string("external"))
        await store.applyWorkspace()
        XCTAssertEqual(store.providerDraft?.model, "desired")
        XCTAssertEqual(store.snapshot?.user["model"].string, "external")
        XCTAssertNotNil(store.error)
        let writes = await transport.writeCount; XCTAssertEqual(writes, 0)
    }

    func testExternalReloadWaitsForBusyOperationAndPreservesUnsavedDraft() async throws {
        let (_, location, transport, store) = try fixture()
        await store.load(location: location); store.activateWorkspace()
        beginLegacyConnectionDraft(store)
        store.providerDraft?.model = "unsaved-local-model"
        let draft = store.providerDraft
        XCTAssertTrue(store.hasUnsavedChanges)
        store.error = "Previous explicit apply failed"
        let beforeReads = await transport.readCount
        store.busy = true
        await transport.change("model_provider", to: .string("first-external"))
        store.requestConfigurationReload(location: location)
        await transport.change("model_provider", to: .string("latest-external"))
        store.requestConfigurationReload(location: location)
        for _ in 0..<20 { await Task.yield() }
        let busyReads = await transport.readCount
        XCTAssertEqual(busyReads, beforeReads, "Reload must wait for the active provider operation")
        store.busy = false
        for _ in 0..<200 {
            if store.snapshot?.configuredProviderID == "latest-external", !store.busy { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(store.snapshot?.configuredProviderID, "latest-external")
        XCTAssertEqual(store.providerDraft, draft)
        XCTAssertTrue(store.hasUnsavedChanges)
        XCTAssertFalse(store.showUnsavedPrompt)
        XCTAssertEqual(store.error, "Previous explicit apply failed", "A background reload must not erase an operation failure")
        let writes = await transport.writeCount
        XCTAssertEqual(writes, 0, "External configuration refresh must remain read-only")
    }

    func testWorkspaceDistinguishesDefaultConfiguredAndUnconfiguredProviders() throws {
        let current = CodexModelProfilesStore.preview("preset-current")
        XCTAssertTrue(current.isDefaultConnection(try XCTUnwrap(current.providerDraft)))
        XCTAssertNil(current.workspaceIssue)
        let configured = CodexModelProfilesStore.preview("preset-configured")
        XCTAssertFalse(configured.isDefaultConnection(try XCTUnwrap(configured.providerDraft)))
        XCTAssertTrue(configured.canApplyWorkspace)
        let empty = CodexModelProfilesStore.preview("preset-empty")
        XCTAssertFalse(empty.canApplyWorkspace)
        XCTAssertNil(empty.workspaceIssue)
    }

    func testWorkspaceIssueReportsBlockingProblemsAndAuthenticationPreventsApply() {
        let locked = CodexModelProfilesStore.preview("preset-error")
        XCTAssertEqual(locked.workspaceIssue, CredentialFailure.locked.localizedDescription)
        let unsupported = CodexModelProfilesStore.preview("preset-unsupported")
        XCTAssertEqual(unsupported.workspaceIssue,
                       L10n.text("This Codex executable does not support Keychain credential commands. Update Codex or select its native executable in General."))
        let moved = CodexModelProfilesStore.preview("preset-repair")
        XCTAssertEqual(moved.workspaceIssue, L10n.text("Veyra moved. Re-enable this provider to repair the credential path."))
        let rejected = CodexModelProfilesStore.preview("preset-auth")
        XCTAssertFalse(rejected.canApplyWorkspace)
    }

    func testPreviewScenariosSurviveRepeatedWorkspaceActivation() {
        let invalid = CodexModelProfilesStore.preview("invalid")
        invalid.activateWorkspace()
        XCTAssertEqual(invalid.providerDraft?.baseURL, "invalid")
        XCTAssertNotNil(invalid.workspaceErrors["baseURL"])
        XCTAssertTrue(invalid.attemptedValidation)
        let dirty = CodexModelProfilesStore.preview("preset-dirty")
        dirty.activateWorkspace()
        XCTAssertTrue(dirty.hasUnsavedChanges); XCTAssertFalse(dirty.apiKeyInput.isEmpty)
        XCTAssertTrue(dirty.replacingKey)
        let error = CodexModelProfilesStore.preview("error")
        error.activateWorkspace(); XCTAssertNotNil(error.error)
        let success = CodexModelProfilesStore.preview("success")
        success.activateWorkspace(); XCTAssertNotNil(success.message)
        let missing = CodexModelProfilesStore.preview("preset-capabilities-missing")
        missing.activateWorkspace()
        XCTAssertEqual(missing.providerDraft?.model, "new-model")
        XCTAssertNil(missing.workspaceModel?.contextWindow)
        let removed = CodexModelProfilesStore.preview("preset-removed")
        removed.activateWorkspace()
        XCTAssertEqual(removed.providerDraft?.model, "previously-selected-model")
        XCTAssertNil(removed.workspaceModel)
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


@MainActor
extension CodexModelProfilesStoreTests {
    private func waitForHeader(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for header configuration")
    }
    private func settleHeader() async { for _ in 0..<40 { await Task.yield() } }

    func testBackgroundReloadPreservesCleanDraftFeedbackAndEditorChoices() async throws {
        let (_, location, transport, store) = try fixture()
        await store.load(location: location); store.activateWorkspace()
        let draft = store.providerDraft, revision = store.editorRevision
        XCTAssertFalse(store.hasUnsavedChanges)
        store.error = "Explicit apply failed"
        store.replacingKey = true
        store.confirmedEndpoint = true; store.attemptedValidation = true
        store.connectionTesting = true; store.editStatus = .failed
        let beforeReads = await transport.readCount
        await transport.change("model_provider", to: .string("deepseek"))
        store.requestConfigurationReload(location: location)
        await settleHeader()
        let duringConnectionReads = await transport.readCount
        XCTAssertEqual(duringConnectionReads, beforeReads)
        XCTAssertTrue(store.connectionTesting, "A pending header reload must not cancel the connection test")
        store.connectionTesting = false
        try await waitForHeader { store.snapshot?.configuredProviderID == "deepseek" && !store.busy }
        XCTAssertEqual(store.error, "Explicit apply failed")
        XCTAssertTrue(store.replacingKey)
        XCTAssertTrue(store.confirmedEndpoint); XCTAssertTrue(store.attemptedValidation)
        XCTAssertFalse(store.connectionTesting)
        XCTAssertEqual(store.editStatus, .failed)
        XCTAssertEqual(store.providerDraft, draft)
        XCTAssertEqual(store.editorRevision, revision)
        store.error = nil; store.message = "Provider successfully applied"
        await transport.change("model_provider", to: .string("openai"))
        store.requestConfigurationReload(location: location)
        try await waitForHeader { store.snapshot?.configuredProviderID == "openai" && !store.busy }
        XCTAssertEqual(store.message, "Provider successfully applied")
        let writes = await transport.writeCount; XCTAssertEqual(writes, 0)
    }

    func testHeaderReloadBacksOffCoalescesLatestRequestAndResetsAfterSuccess() async throws {
        let clock = TestPollingClock()
        let (_, location, transport, store) = try fixture(clock: clock.clock)
        await store.load(location: location)
        await transport.configureReadFailures(10)
        await transport.change("model_provider", to: .string("deepseek"))
        var expectedReads = await transport.readCount + 1
        store.requestConfigurationReload(location: location)
        try await waitForHeader { store.configurationReloadError != nil && !store.busy }
        await settleHeader()
        for delay in [5, 15, 30, 60] {
            let before = await transport.readCount
            XCTAssertEqual(before, expectedReads)
            clock.advance(delay - 1); await settleHeader()
            let early = await transport.readCount; XCTAssertEqual(early, expectedReads)
            clock.advance(1)
            expectedReads += 1
            for _ in 0..<200 {
                if await transport.readCount == expectedReads, !store.busy { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            await settleHeader()
            let after = await transport.readCount; XCTAssertEqual(after, expectedReads)
        }
        await transport.configureReadFailures(0)
        await transport.change("model_provider", to: .string("latest"))
        store.requestConfigurationReload(location: location)
        try await waitForHeader { store.snapshot?.configuredProviderID == "latest" && !store.busy }
        XCTAssertNil(store.configurationReloadError)
        let recoveredReads = await transport.readCount
        clock.advance(1000); await settleHeader()
        let cancelledReads = await transport.readCount
        XCTAssertEqual(cancelledReads, recoveredReads, "The superseded retry must not issue another read")
        await transport.configureReadFailures(1)
        await transport.change("model_provider", to: .string("after-recovery"))
        store.requestConfigurationReload(location: location)
        try await waitForHeader { store.configurationReloadError != nil && !store.busy }
        await settleHeader()
        let failedAgainReads = await transport.readCount
        clock.advance(4); await settleHeader()
        let earlyAgainReads = await transport.readCount; XCTAssertEqual(earlyAgainReads, failedAgainReads)
        clock.advance(1)
        try await waitForHeader { store.snapshot?.configuredProviderID == "after-recovery" && !store.busy }
        XCTAssertNil(store.configurationReloadError)
        let writes = await transport.writeCount; XCTAssertEqual(writes, 0)
        clock.finish(); await settleHeader()
    }

    func testHeaderRetryWaitsForBusyOperationWithoutLosingRequest() async throws {
        let clock = TestPollingClock()
        let (_, location, transport, store) = try fixture(clock: clock.clock)
        await store.load(location: location)
        await transport.configureReadFailures(1)
        await transport.change("model_provider", to: .string("deepseek"))
        store.requestConfigurationReload(location: location)
        try await waitForHeader { store.configurationReloadError != nil && !store.busy }
        await settleHeader()
        let failedReads = await transport.readCount
        store.busy = true
        clock.advance(5); await settleHeader()
        let busyReads = await transport.readCount; XCTAssertEqual(busyReads, failedReads)
        store.busy = false
        try await waitForHeader { store.snapshot?.configuredProviderID == "deepseek" && !store.busy }
        XCTAssertNil(store.configurationReloadError)
        clock.finish(); await settleHeader()
    }

    func testForegroundReloadSupersedesPendingHeaderRetry() async throws {
        let clock = TestPollingClock()
        let (_, location, transport, store) = try fixture(clock: clock.clock)
        await store.load(location: location)
        await transport.configureReadFailures(1)
        await transport.change("model_provider", to: .string("deepseek"))
        store.requestConfigurationReload(location: location)
        try await waitForHeader { store.configurationReloadError != nil && !store.busy }
        await settleHeader()
        let loaded = await store.load(location: location)
        XCTAssertTrue(loaded)
        XCTAssertEqual(store.snapshot?.configuredProviderID, "deepseek")
        XCTAssertNil(store.configurationReloadError)
        let reads = await transport.readCount
        clock.advance(1000); await settleHeader()
        let laterReads = await transport.readCount; XCTAssertEqual(laterReads, reads)
        clock.finish(); await settleHeader()
    }

    func testForegroundReadFailureAlsoRetriesAndClearsOnlyItsOwnError() async throws {
        let clock = TestPollingClock()
        let (_, location, transport, store) = try fixture(clock: clock.clock)
        await transport.configureReadFailures(1)
        let loaded = await store.load(location: location)
        XCTAssertFalse(loaded); XCTAssertNotNil(store.error)
        await settleHeader()
        clock.advance(5)
        try await waitForHeader { store.snapshot != nil && !store.busy }
        XCTAssertNil(store.error)
        XCTAssertNil(store.configurationReloadError)
        XCTAssertEqual(store.defaultProviderIdentity.name, "OpenAI")
        clock.finish(); await settleHeader()
    }

    func testFailedForegroundReloadDuringBackoffDoesNotImmediatelyReadAgain() async throws {
        let clock = TestPollingClock()
        let (_, location, transport, store) = try fixture(clock: clock.clock)
        await store.load(location: location)
        await transport.configureReadFailures(2)
        await transport.change("model_provider", to: .string("deepseek"))
        store.requestConfigurationReload(location: location)
        try await waitForHeader { store.configurationReloadError != nil && !store.busy }
        await settleHeader()
        let loaded = await store.load(location: location)
        XCTAssertFalse(loaded); XCTAssertNotNil(store.error)
        let manualReads = await transport.readCount
        await settleHeader()
        let immediateReads = await transport.readCount; XCTAssertEqual(immediateReads, manualReads)
        clock.advance(4); await settleHeader()
        let earlyReads = await transport.readCount; XCTAssertEqual(earlyReads, manualReads)
        clock.advance(1)
        try await waitForHeader { store.snapshot?.configuredProviderID == "deepseek" && !store.busy }
        XCTAssertNil(store.error); XCTAssertNil(store.configurationReloadError)
        clock.finish(); await settleHeader()
    }

    func testDirectorySwitchKeepsRetryDeadlineAfterOldReadCompletes() async throws {
        try await verifyDirectorySwitchRetry(releaseBeforeDeadline: true)
    }

    func testDirectorySwitchResumesWhenRetryExpiresDuringOldRead() async throws {
        try await verifyDirectorySwitchRetry(releaseBeforeDeadline: false)
    }

    private func verifyDirectorySwitchRetry(releaseBeforeDeadline: Bool) async throws {
        let first = try SQLiteFixture(), second = try SQLiteFixture(), clock = TestPollingClock()
        var delays: [Duration] = []
        let trackedClock = PollingClock(now: { clock.instant }, sleep: { delay in
            delays.append(delay)
            try await clock.clock.sleep(delay)
        })
        let transport = DirectorySwitchConfigurationTransport(firstHome: first.home)
        let service = CodexModelProfileService(transport: transport, root: first.home.appendingPathComponent("profiles"),
            credentials: MemoryCredentialStore(), helperExecutable: URL(fileURLWithPath: "/fixture/Veyra"), capability: { _ in true })
        let store = CodexModelProfilesStore(service: service, configurationClock: trackedClock)
        let oldLocation = CodexLocation(home: first.home, executable: nil)
        let newLocation = CodexLocation(home: second.home, executable: nil)
        await store.load(location: oldLocation)
        await transport.holdOldRead()
        store.requestConfigurationReload(location: oldLocation)
        for _ in 0..<200 {
            if await transport.oldReadIsWaiting { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let oldReadIsWaiting = await transport.oldReadIsWaiting
        XCTAssertTrue(oldReadIsWaiting)

        // The service is still reading the old home, so the foreground load fails
        // with busy and queues a five-second retry for the new home.
        let loaded = await store.load(location: newLocation)
        XCTAssertFalse(loaded); XCTAssertEqual(store.location, newLocation)
        XCTAssertNotNil(store.error); XCTAssertNil(store.snapshot)
        try await waitForHeader { delays == [.seconds(5)] }

        if !releaseBeforeDeadline {
            clock.advance(5); await settleHeader()
        }
        await transport.releaseOldRead()
        // Let the real actor/service completion propagate without advancing the
        // simulated deadline. An early retry must be observable here.
        try await Task.sleep(for: .milliseconds(100))
        if releaseBeforeDeadline {
            let earlyReads = await transport.newReads
            XCTAssertEqual(earlyReads, 0)
            XCTAssertEqual(delays, [.seconds(5)], "The old loop must not replace a waiting timer")
            XCTAssertNil(store.snapshot, "The old home's result must stay discarded")
            clock.advance(5)
        }
        try await waitForHeader { delays.count >= 2 && !store.busy }
        let firstRetryReads = await transport.newReads
        XCTAssertEqual(firstRetryReads, 1)
        XCTAssertEqual(delays, [.seconds(5), .seconds(15)])
        XCTAssertNotNil(store.configurationReloadError)

        clock.advance(10)
        try await Task.sleep(for: .milliseconds(50))
        let orphanTimerReads = await transport.newReads
        XCTAssertEqual(orphanTimerReads, 1, "No orphan timer may read at t=15")
        clock.advance(4); await settleHeader()
        let earlySecondReads = await transport.newReads; XCTAssertEqual(earlySecondReads, 1)
        clock.advance(1)
        try await waitForHeader { store.snapshot?.configuredProviderID == "second-home" && !store.busy }
        let recoveredReads = await transport.newReads; XCTAssertEqual(recoveredReads, 2)
        XCTAssertEqual(store.location, newLocation)
        XCTAssertNil(store.error); XCTAssertNil(store.configurationReloadError)
        clock.advance(1000); await settleHeader()
        let laterReads = await transport.newReads; XCTAssertEqual(laterReads, recoveredReads)
        let writes = await transport.writes; XCTAssertEqual(writes, 0)
        clock.finish(); await settleHeader()
    }
}

private actor DirectorySwitchConfigurationTransport: CodexModelConfigurationTransport {
    let firstHome: URL
    private var holdOld = false
    private var oldReadGate: CheckedContinuation<Void, Never>?
    private var failuresRemaining = 1
    private(set) var newReads = 0
    private(set) var writes = 0
    var oldReadIsWaiting: Bool { oldReadGate != nil }

    init(firstHome: URL) { self.firstHome = firstHome }
    func holdOldRead() { holdOld = true }
    func releaseOldRead() { holdOld = false; oldReadGate?.resume(); oldReadGate = nil }

    func readConfiguration(location: CodexLocation) async throws -> CodexConfigSnapshot {
        if location.home == firstHome {
            if holdOld { await withCheckedContinuation { oldReadGate = $0 } }
        } else {
            newReads += 1
            if failuresRemaining > 0 {
                failuresRemaining -= 1
                throw ModelProfileFailure.unavailable
            }
        }
        let provider = location.home == firstHome ? "first-home" : "second-home"
        return CodexConfigSnapshot(user: .object(["model_provider": .string(provider)]), version: "1",
                                   file: location.home.appendingPathComponent("config.toml"))
    }

    func writeConfiguration(location: CodexLocation, edits: [CodexConfigEdit], expectedVersion: String) async throws -> CodexConfigWriteReceipt {
        writes += 1
        throw ModelProfileFailure.invalid
    }
}

import Foundation
import XCTest

actor ProviderModelFixture: ProviderModelClient {
    var response: [DiscoveredModel] = [DiscoveredModel(id: "fixture-model")]
    var failure: ModelDiscoveryFailure?
    var calls = 0
    var suspended = false
    private var pending: [CheckedContinuation<[DiscoveredModel], Error>] = []
    func configure(_ models: [DiscoveredModel]? = nil, failure: ModelDiscoveryFailure? = nil, suspend: Bool = false) {
        if let models { response = models }; self.failure = failure; suspended = suspend
    }
    func models(preset: ProviderPreset, baseURL: String, key: String) async throws -> [DiscoveredModel] {
        calls += 1
        if suspended { return try await withCheckedThrowingContinuation { pending.append($0) } }
        if let failure { throw failure }
        return response
    }
    func resume(_ models: [DiscoveredModel]) { let work = pending; pending = []; work.forEach { $0.resume(returning: models) } }
}

extension CodexModelProfileService {
    /// Existing transaction tests explicitly prepare a discovery fixture, without changing Save semantics.
    func saveDiscoveredProvider(_ input: ProviderSettings, newKey: String?, home: URL) async throws -> ModelProfileLibrary {
        var settings = input
        if settings.model.isEmpty { settings.model = "fixture-model" }
        let saved = try saveProvider(settings, newKey: newKey, home: home)
        _ = try await fetchProviderModels(settings.id, home: home)
        return saved
    }
}

final class ProviderModelParsingTests: XCTestCase {
    func testFiveResponseFormatsPreserveOrderCaseAndUnknownIDs() throws {
        for preset in ProviderPreset.all {
            let normal = Data(#"{"data":[{"id":"New-Model"},{"id":"new-model"},{"id":"New-Model"},{"id":"unknown-audio-model"}]}"#.utf8)
            XCTAssertEqual(try URLSessionProviderModelClient.parse(normal, preset: preset).map(\.id), ["New-Model", "new-model", "unknown-audio-model"])
        }
        let native = Data(#"{"models":[{"slug":"brand-new-glm","display_name":"New GLM","context_window":123456,"supported_reasoning_levels":[{"effort":"future-effort"}],"model_messages":{"instructions_template":"DO NOT IMPORT"},"guardian":{"network":"never"}}]}"#.utf8)
        let value = try URLSessionProviderModelClient.parse(native, preset: ProviderPreset.find("glm")!)
        XCTAssertEqual(value[0].id, "brand-new-glm"); XCTAssertEqual(value[0].reasoningLevels, ["future-effort"])
        let encoded = try JSONEncoder().encode(value)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("DO NOT IMPORT"))
    }
    func testCapabilitiesAndMissingValuesDoNotInventCapacitiesOrEfforts() throws {
        let data = Data(#"{"data":[{"id":"remote-only","context_window":999999,"input_modalities":["text","image"],"effort":{"supported_levels":["low","max","future","max"],"default_level":"future"}},{"id":"id-only"}]}"#.utf8)
        let models = try URLSessionProviderModelClient.parse(data, preset: ProviderPreset.all[0])
        XCTAssertEqual(models[0].reasoningLevels, ["low","max","future"])
        XCTAssertEqual(models[0].defaultReasoning, "future")
        XCTAssertNil(models[1].contextWindow); XCTAssertNil(models[1].inputModalities); XCTAssertNil(models[1].reasoningLevels)
        var settings = ProviderSettings(preset: ProviderPreset.all[0]); settings.model = models[1].id
        let catalog = ProviderRuntimeCatalog.build(models: models, preset: ProviderPreset.all[0], settings: settings)
        let model = catalog["models"].array![1]
        XCTAssertEqual(model["context_window"], .null); XCTAssertEqual(model["default_reasoning_level"], .null)
        XCTAssertEqual(model["input_modalities"], .null); XCTAssertEqual(model["supported_reasoning_levels"].array, [])
        XCTAssertEqual(model["model_messages"], .null); XCTAssertEqual(model["guardian"], .null)
    }
    func testSignedCatalogFixtureUsesBothMacOSTemporaryPathSpellings() throws {
        let root = URL(fileURLWithPath: "/private/tmp/veyra-credential-" + UUID().uuidString)
        let folder = root.appendingPathComponent("model-catalog-fixture")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"data":[{"id":"never-bundled-model"}]}"#.utf8).write(to: folder.appendingPathComponent("models-response.json"))
        XCTAssertEqual(ProviderCredentialCommand.run(["--create-model-catalog-fixture", "deepseek", folder.path]), 0)
        let catalog = try JSONValue.decode(Data(contentsOf: folder.appendingPathComponent("deepseek.json")))
        XCTAssertEqual(catalog["models"].array?.first?["slug"].string, "never-bundled-model")
        XCTAssertEqual(catalog["models"].array?.first?["context_window"], .null)
    }
    func testEmptyMalformedAuthenticationAndSizeLimits() throws {
        let preset = ProviderPreset.all[0]
        XCTAssertEqual(try URLSessionProviderModelClient.parse(Data(#"{"data":[]}"#.utf8), preset: preset), [])
        for value in [#"{}"#, #"{"data":[{"id":""}]}"#, #"{"data":[{"id":"bad\nmodel"}]}"#, #"{"error":{"message":"secret"}}"#, #"{"data":"not-an-array"}"#] {
            XCTAssertThrowsError(try URLSessionProviderModelClient.parse(Data(value.utf8), preset: preset))
        }
        XCTAssertThrowsError(try URLSessionProviderModelClient.parse(Data(repeating: 32, count: 2 * 1024 * 1024 + 1), preset: preset))
        XCTAssertThrowsError(try URLSessionProviderModelClient.parse(Data(#"{"success":false,"code":1002,"msg":"do not display"}"#.utf8), preset: ProviderPreset.find("glm")!)) { XCTAssertEqual($0 as? ModelDiscoveryFailure, .authentication) }
    }
}

final class ProviderModelServiceTests: XCTestCase {
    private func fixture() throws -> (URL, CodexLocation, ModelConfigurationFixture, ProviderModelFixture, MemoryCredentialStore, CodexModelProfileService) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("veyra-discovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let rpc = ModelConfigurationFixture(home: home); let client = ProviderModelFixture(); let keys = MemoryCredentialStore()
        let service = CodexModelProfileService(transport: rpc, root: home.appendingPathComponent("library"), credentials: keys,
            helperExecutable: URL(fileURLWithPath: "/Applications/Veyra.app/Contents/MacOS/Veyra"), capability: { _ in true }, modelClient: client)
        return (home, CodexLocation(home: home, executable: nil), rpc, client, keys, service)
    }
    func testSaveOnlyDoesNotFetchAndEnableRequiresSelectionFromDiscovery() async throws {
        let (home, location, rpc, client, _, service) = try fixture()
        var saved = try await service.saveProvider(ProviderSettings(preset: ProviderPreset.all[0]), newKey: "fixture-only-key", home: home).providers[0]
        XCTAssertEqual(saved.model, "")
        let calls = await client.calls; XCTAssertEqual(calls, 0)
        do { _ = try await service.applyProvider(saved.id, location: location, expectedVersion: "0"); XCTFail() } catch { XCTAssertEqual(error as? ModelDiscoveryFailure, .unavailable) }
        let cache = try await service.fetchProviderModels(saved.id, home: home)
        XCTAssertEqual(cache.models.map(\.id), ["fixture-model"])
        saved.model = "fixture-model"; saved.reasoning = "future-effort"
        _ = try await service.saveProvider(saved, newKey: nil, home: home)
        do { _ = try await service.applyProvider(saved.id, location: location, expectedVersion: "0"); XCTFail("Unknown Codex efforts must not reach the configuration RPC") }
        catch { XCTAssertEqual(error as? ModelProfileFailure, .invalid) }
        let blockedWrites = await rpc.writeCount; XCTAssertEqual(blockedWrites, 0)
        saved.reasoning = ""; _ = try await service.saveProvider(saved, newKey: nil, home: home)
        let active = try await service.applyProvider(saved.id, location: location, expectedVersion: "0")
        XCTAssertEqual(active.snapshot.user["model_reasoning_effort"], .null)
        XCTAssertEqual(active.snapshot.user["model_context_window"], .null)
        XCTAssertEqual(active.snapshot.user["model_supports_reasoning_summaries"], .null)
        let writes = await rpc.writeCount; XCTAssertEqual(writes, 1)
        let files = FileManager.default.enumerator(at: home.appendingPathComponent("library"), includingPropertiesForKeys: [.isRegularFileKey])!
        let urls = files.allObjects.compactMap { $0 as? URL }
        for url in urls where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            XCTAssertFalse(try Data(contentsOf: url).range(of: Data("fixture-only-key".utf8)) != nil)
        }
    }
    func testProviderDefaultsAreAppliedAndRefreshedWithoutOverridingManualChoices() async throws {
        let (home, location, rpc, client, _, service) = try fixture()
        await client.configure([DiscoveredModel(id: "fixture-model", contextWindow: 131072, reasoningLevels: ["low", "high", "max"], defaultReasoning: "high")])
        var settings = try await service.saveDiscoveredProvider(ProviderSettings(preset: ProviderPreset.all[0]), newKey: "fixture-key", home: home).providers[0]
        let first = try await service.applyProvider(settings.id, location: location, expectedVersion: "0")
        XCTAssertEqual(first.snapshot.user["model_reasoning_effort"].string, "high")
        XCTAssertEqual(first.snapshot.user["model_context_window"].integer, 131072)
        XCTAssertEqual(settings.reasoning, ""); XCTAssertNil(settings.contextWindowOverride)
        await client.configure([DiscoveredModel(id: "fixture-model", contextWindow: 262144, reasoningLevels: ["low", "high", "max"], defaultReasoning: "max")])
        _ = try await service.fetchProviderModels(settings.id, home: home)
        let beforeApply = await rpc.writeCount; XCTAssertEqual(beforeApply, 1)
        let refreshed = try await service.applyProvider(settings.id, location: location, expectedVersion: first.snapshot.version)
        XCTAssertEqual(refreshed.snapshot.user["model_reasoning_effort"].string, "max")
        XCTAssertEqual(refreshed.snapshot.user["model_context_window"].integer, 262144)
        settings.reasoning = "low"; settings.contextWindowOverride = 8192
        _ = try await service.saveProvider(settings, newKey: nil, home: home)
        let manual = try await service.applyProvider(settings.id, location: location, expectedVersion: refreshed.snapshot.version)
        XCTAssertEqual(manual.snapshot.user["model_reasoning_effort"].string, "low")
        XCTAssertEqual(manual.snapshot.user["model_context_window"].integer, 8192)
    }
    func testEffortListWithoutDeclaredDefaultDoesNotChooseAStrengthOrAnotherModelsMetadata() throws {
        var settings = ProviderSettings(preset: ProviderPreset.all[0]); settings.model = "selected-model"
        let noDefault = DiscoveredModel(id: "selected-model", reasoningLevels: ["low", "high", "max"])
        XCTAssertEqual(settings.resolvedReasoning(using: noDefault), "")
        XCTAssertNil(settings.resolvedContextWindow(using: noDefault))
        let other = DiscoveredModel(id: "other-model", contextWindow: 1000000, reasoningLevels: ["max"], defaultReasoning: "max")
        XCTAssertEqual(settings.resolvedReasoning(using: other), "")
        XCTAssertNil(settings.resolvedContextWindow(using: other))
    }
    func testCachedFailureAuthenticationAndEmptyListAreDistinct() async throws {
        let (home, location, _, client, _, service) = try fixture()
        _ = try await service.saveDiscoveredProvider(ProviderSettings(preset: ProviderPreset.all[0]), newKey: "fixture-key", home: home)
        await client.configure(failure: .network)
        let cached = try await service.fetchProviderModels("deepseek", home: home)
        XCTAssertTrue(cached.contains("fixture-model")); XCTAssertEqual(cached.failure, .network)
        _ = try await service.applyProvider("deepseek", location: location, expectedVersion: "0")
        await client.configure(failure: .authentication)
        let rejected = try await service.fetchProviderModels("deepseek", home: home)
        XCTAssertFalse(rejected.contains("fixture-model")); XCTAssertEqual(rejected.models.count, 1)
        do { _ = try await service.applyProvider("deepseek", location: location, expectedVersion: "1"); XCTFail() } catch { XCTAssertTrue(error is ModelDiscoveryFailure) }
        await client.configure([])
        let empty = try await service.fetchProviderModels("deepseek", home: home)
        XCTAssertNotNil(empty.fetchedAt); XCTAssertNil(empty.failure); XCTAssertTrue(empty.models.isEmpty)
    }
    func testRotationAndAddressAndHomeScopesDoNotReuseLists() async throws {
        let (home, _, _, _, _, service) = try fixture()
        var saved = try await service.saveDiscoveredProvider(ProviderSettings(preset: ProviderPreset.all[0]), newKey: "fixture-key", home: home).providers[0]
        saved = try await service.saveProvider(saved, newKey: "replacement-fixture-key", home: home).providers[0]
        let rotated = try await service.cachedModels(home: home); XCTAssertNil(rotated[saved.id])
        _ = try await service.fetchProviderModels(saved.id, home: home)
        saved.baseURL = "https://other.example.invalid/v1"
        _ = try await service.saveProvider(saved, newKey: "other-fixture-key", home: home)
        let moved = try await service.cachedModels(home: home); XCTAssertTrue(moved.isEmpty)
        let other = try await service.cachedModels(home: home.appendingPathComponent("other-home")); XCTAssertTrue(other.isEmpty)
    }
    func testLateResponseAfterRotationAndCancelledRequestsDoNotReplaceCache() async throws {
        let (home, _, _, client, _, service) = try fixture()
        let saved = try await service.saveDiscoveredProvider(ProviderSettings(preset: ProviderPreset.all[0]), newKey: "fixture-key", home: home).providers[0]
        await client.configure(suspend: true)
        let request = Task { try await service.fetchProviderModels(saved.id, home: home) }
        while await client.calls < 2 { await Task.yield() }
        _ = try await service.saveProvider(saved, newKey: "new-fixture-key", home: home)
        await client.resume([DiscoveredModel(id: "stale-result")])
        do { _ = try await request.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        let current = try await service.cachedModels(home: home); XCTAssertTrue(current.isEmpty)
        let cancelled = Task { try await service.fetchProviderModels(saved.id, home: home) }
        while await client.calls < 3 { await Task.yield() }
        cancelled.cancel(); await client.resume([DiscoveredModel(id: "cancelled-result")])
        do { _ = try await cancelled.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        let after = try await service.cachedModels(home: home); XCTAssertTrue(after.isEmpty)
    }
    func testCorruptCacheDoesNotHideSavedKeyAndCanBeRefetchedAfterRestart() async throws {
        let (home, _, rpc, client, keys, service) = try fixture()
        let saved = try await service.saveDiscoveredProvider(ProviderSettings(preset: ProviderPreset.all[0]), newKey: "fixture-key", home: home)
        let files = FileManager.default.enumerator(at: home.appendingPathComponent("library"), includingPropertiesForKeys: nil)!.allObjects.compactMap { $0 as? URL }
        let file = try XCTUnwrap(files.first { $0.path.contains("/model-cache/") && $0.pathExtension == "json" })
        try Data("not valid JSON".utf8).write(to: file)
        let restarted = CodexModelProfileService(transport: rpc, root: home.appendingPathComponent("library"), credentials: keys, modelClient: client)
        let library = try await restarted.library(home: home); XCTAssertEqual(library.providers, saved.providers)
        let caches = try await restarted.cachedModels(home: home); XCTAssertTrue(caches.isEmpty)
        let fresh = try await restarted.fetchProviderModels("deepseek", home: home); XCTAssertTrue(fresh.contains("fixture-model"))
        let writes = await rpc.writeCount; XCTAssertEqual(writes, 0)
    }
    func testRefreshPreservesImmutableOldCatalogAndDoesNotWriteCodex() async throws {
        let (home, location, rpc, client, _, service) = try fixture()
        _ = try await service.saveDiscoveredProvider(ProviderSettings(preset: ProviderPreset.all[0]), newKey: "fixture-key", home: home)
        let active = try await service.applyProvider("deepseek", location: location, expectedVersion: "0")
        let file = URL(fileURLWithPath: active.snapshot.user["model_catalog_json"].string!)
        let prior = try Data(contentsOf: file)
        await client.configure([DiscoveredModel(id: "new-remote-model")])
        _ = try await service.fetchProviderModels("deepseek", home: home)
        XCTAssertEqual(try Data(contentsOf: file), prior)
        do { _ = try await service.applyProvider("deepseek", location: location, expectedVersion: active.snapshot.version); XCTFail() } catch { XCTAssertEqual(error as? ModelDiscoveryFailure, .unavailable) }
        let writes = await rpc.writeCount; XCTAssertEqual(writes, 1)
    }
}

private final class ProviderHTTPState: @unchecked Sendable {
    struct Response: Sendable { var status = 200; var body = Data(#"{"data":[{"id":"network-model"}]}"#.utf8); var length: Int?; var error: URLError.Code?; var redirect: URL? }
    private let lock = NSLock()
    private var response = Response()
    private var requests: [URLRequest] = []
    func configure(_ response: Response) { lock.lock(); defer { lock.unlock() }; self.response = response; requests = [] }
    func receive(_ request: URLRequest) -> Response { lock.lock(); defer { lock.unlock() }; requests.append(request); return response }
    func recorded() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
}
private final class ProviderHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let state = ProviderHTTPState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data = Self.state.receive(request)
        if let error = data.error { client?.urlProtocol(self, didFailWithError: URLError(error)); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: data.status, httpVersion: "HTTP/1.1",
            headerFields: data.length.map { ["Content-Length": String($0)] })!
        if let redirect = data.redirect {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirect), redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ProviderModelHTTPTests: XCTestCase {
    private var client: URLSessionProviderModelClient { URLSessionProviderModelClient(protocolClasses: [ProviderHTTPProtocol.self]) }
    func testRequestUsesOneSavedEndpointAndBearerHeader() async throws {
        ProviderHTTPProtocol.state.configure(.init())
        let models = try await client.models(preset: ProviderPreset.all[0], baseURL: "https://provider.example.invalid/custom/v1/", key: "fixture-http-key")
        XCTAssertEqual(models.map(\.id), ["network-model"])
        let requests = ProviderHTTPProtocol.state.recorded()
        XCTAssertEqual(requests.count, 1); XCTAssertEqual(requests[0].url?.absoluteString, "https://provider.example.invalid/custom/v1/models")
        XCTAssertEqual(requests[0].httpMethod, "GET"); XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer fixture-http-key")
        XCTAssertEqual(requests[0].timeoutInterval, 15); XCTAssertEqual(requests[0].cachePolicy, .reloadIgnoringLocalCacheData)
    }
    func testHTTPFailuresAreSafeAndNeverRetry() async throws {
        for (status, expected) in [(401, ModelDiscoveryFailure.authentication),(403,.authentication),(429,.rateLimited),(500,.server),(404,.invalidResponse)] {
            ProviderHTTPProtocol.state.configure(.init(status: status, body: Data("fixture-secret-never-display".utf8)))
            do { _ = try await client.models(preset: ProviderPreset.all[0], baseURL: "https://provider.example.invalid/v1", key: "fixture-key"); XCTFail() }
            catch { XCTAssertEqual(error as? ModelDiscoveryFailure, expected); XCTAssertFalse(error.localizedDescription.contains("fixture-secret")) }
            XCTAssertEqual(ProviderHTTPProtocol.state.recorded().count, 1)
        }
        ProviderHTTPProtocol.state.configure(.init(error: .timedOut))
        do { _ = try await client.models(preset: ProviderPreset.all[0], baseURL: "https://provider.example.invalid", key: "fixture-key"); XCTFail() }
        catch { XCTAssertEqual(error as? ModelDiscoveryFailure, .timeout) }
    }
    func testAdvertisedAndStreamingSizeLimits() async throws {
        for response in [ProviderHTTPState.Response(length: 2 * 1024 * 1024 + 1), .init(body: Data(repeating: 32, count: 2 * 1024 * 1024 + 1))] {
            ProviderHTTPProtocol.state.configure(response)
            do { _ = try await client.models(preset: ProviderPreset.all[0], baseURL: "https://provider.example.invalid", key: "fixture-key"); XCTFail() }
            catch { XCTAssertEqual(error as? ModelDiscoveryFailure, .tooLarge) }
        }
    }
    func testReflectedCredentialIsRejectedEvenInsideAnAllowedDisplayField() async throws {
        ProviderHTTPProtocol.state.configure(.init(body: Data(#"{"data":[{"id":"normal-model","name":"echo: fixture-reflected-key"}]}"#.utf8)))
        do { _ = try await client.models(preset: ProviderPreset.all[0], baseURL: "https://provider.example.invalid", key: "fixture-reflected-key"); XCTFail() }
        catch { XCTAssertEqual(error as? ModelDiscoveryFailure, .invalidResponse); XCTAssertFalse(error.localizedDescription.contains("fixture-reflected-key")) }
    }
    func testRedirectCannotForwardTheKeyToAnotherEndpoint() async throws {
        ProviderHTTPProtocol.state.configure(.init(status: 302, redirect: URL(string: "https://other.example.invalid/models")!))
        do { _ = try await client.models(preset: ProviderPreset.all[0], baseURL: "https://provider.example.invalid", key: "fixture-key"); XCTFail() }
        catch { XCTAssertEqual(error as? ModelDiscoveryFailure, .invalidResponse) }
        XCTAssertEqual(ProviderHTTPProtocol.state.recorded().map { $0.url?.host }, ["provider.example.invalid"])
    }
}

@MainActor
final class ProviderDiscoveryStoreTests: XCTestCase {
    private func fixture() throws -> (CodexLocation, ModelConfigurationFixture, ProviderModelFixture, CodexModelProfilesStore) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("veyra-discovery-store-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let transport = ModelConfigurationFixture(home: home); let client = ProviderModelFixture()
        let service = CodexModelProfileService(transport: transport, root: home.appendingPathComponent("library"), credentials: MemoryCredentialStore(),
            helperExecutable: URL(fileURLWithPath: "/Applications/Veyra.app/Contents/MacOS/Veyra"), capability: { _ in true }, modelClient: client)
        return (CodexLocation(home: home, executable: nil), transport, client, CodexModelProfilesStore(service: service))
    }
    func testFirstSaveFetchesWithoutSelectingAndModelOnlySaveDoesNotFetch() async throws {
        let (location, rpc, client, store) = try fixture()
        await store.load(location: location)
        let initialCalls = await client.calls; XCTAssertEqual(initialCalls, 0)
        store.apiKeyInput = "fixture-store-key"
        let saved = await store.saveProviderDraft(); XCTAssertTrue(saved)
        XCTAssertEqual(store.providerDraft?.model, ""); XCTAssertFalse(store.canEnableProviderDraft)
        XCTAssertEqual(store.modelDiscoveryState, .ready)
        let firstCalls = await client.calls; XCTAssertEqual(firstCalls, 1)
        store.providerDraft?.model = "fixture-model"
        let again = await store.saveProviderDraft(); XCTAssertTrue(again)
        let secondCalls = await client.calls; XCTAssertEqual(secondCalls, 1)
        XCTAssertTrue(store.canEnableProviderDraft)
        let writes = await rpc.writeCount; XCTAssertEqual(writes, 0)
    }
    func testFailedKeyReplacementPreservesSavedKeyButDoesNotApply() async throws {
        let (location, rpc, client, store) = try fixture()
        await store.load(location: location); store.apiKeyInput = "fixture-key"
        _ = await store.saveProviderDraft(); store.providerDraft?.model = "fixture-model"
        await store.saveAndApplyProvider()
        XCTAssertEqual(store.currentPresetID, "deepseek")
        let old = store.library.providers[0].credential
        await client.configure(failure: .authentication)
        store.apiKeyInput = "replacement-fixture-key"
        await store.saveAndApplyProvider()
        XCTAssertTrue(store.apiKeyInput.isEmpty); XCTAssertNotEqual(store.library.providers[0].credential, old)
        XCTAssertEqual(store.modelDiscoveryState, .failed); XCTAssertFalse(store.canEnableProviderDraft)
        let writes = await rpc.writeCount; XCTAssertEqual(writes, 1)
    }
    func testCancelAndSwitchRejectLateResponse() async throws {
        let (location, _, client, store) = try fixture()
        await store.load(location: location); store.apiKeyInput = "fixture-key"
        _ = await store.saveProviderDraft()
        await client.configure(suspend: true)
        let task = Task { await store.refreshModels() }
        while await client.calls < 2 { await Task.yield() }
        store.selectPreset("kimi")
        await client.resume([DiscoveredModel(id: "late-model")])
        let refreshed = await task.value; XCTAssertFalse(refreshed)
        XCTAssertEqual(store.selectedPresetID, "kimi"); XCTAssertTrue(store.discoveredModels.isEmpty)
        XCTAssertEqual(store.providerModelCaches["deepseek"]?.models.map(\.id), ["fixture-model"])
    }
}


final class ProviderConnectivityHTTPTests: XCTestCase {
    private var client: URLSessionProviderConnectivityClient { .init(protocolClasses: [ProviderHTTPProtocol.self]) }
    private func provider() -> ProviderSettings {
        var value = ProviderSettings(name: "HTTP fixture")
        value.baseURL = "http://127.0.0.1:1234/custom"; value.model = "manual-model"
        value.authentication = ModelProfileAuthentication.none
        return value
    }
    func testCompletedResponseAndNoAuthUseExactEnteredBase() async throws {
        ProviderHTTPProtocol.state.configure(.init(body: Data(#"{"object":"response","status":"completed","output":[]}"#.utf8)))
        try await client.test(provider: provider(), key: nil)
        let requests = ProviderHTTPProtocol.state.recorded()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url?.absoluteString, "http://127.0.0.1:1234/custom/responses")
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
    }
    func testCategorizedFailuresNeverReturnBodySecretsOrRetry() async throws {
        for (status, expected) in [(401, ProviderConnectionFailure.authentication), (403, .authentication), (429, .rateLimited), (500, .server), (404, .inconclusive)] {
            ProviderHTTPProtocol.state.configure(.init(status: status, body: Data(#"{"error":{"message":"fixture-secret"}}"#.utf8)))
            do { try await client.test(provider: provider(), key: "fixture-secret"); XCTFail() }
            catch { XCTAssertEqual(error as? ProviderConnectionFailure, expected); XCTAssertFalse(error.localizedDescription.contains("fixture-secret")) }
            XCTAssertEqual(ProviderHTTPProtocol.state.recorded().count, 1)
        }
        ProviderHTTPProtocol.state.configure(.init(status: 400, body: Data(#"{"error":{"code":"unsupported_api","message":"fixture-secret"}}"#.utf8)))
        do { try await client.test(provider: provider(), key: "fixture-secret"); XCTFail() }
        catch { XCTAssertEqual(error as? ProviderConnectionFailure, .incompatible) }
    }
    func testChatStyleOrIncompleteSuccessIsInconclusive() async throws {
        for body in [#"{"choices":[]}"#, #"{"object":"response","status":"in_progress","output":[]}"#, #"{"object":"response","status":"failed","output":[]}"#] {
            ProviderHTTPProtocol.state.configure(.init(body: Data(body.utf8)))
            do { try await client.test(provider: provider(), key: nil); XCTFail() }
            catch { XCTAssertEqual(error as? ProviderConnectionFailure, .inconclusive) }
        }
    }
    func testTimeoutOversizeAndRedirectFailClosed() async throws {
        ProviderHTTPProtocol.state.configure(.init(error: .timedOut))
        do { try await client.test(provider: provider(), key: nil); XCTFail() }
        catch { XCTAssertEqual(error as? ProviderConnectionFailure, .timeout) }
        ProviderHTTPProtocol.state.configure(.init(length: URLSessionProviderModelClient.maximumBytes + 1))
        do { try await client.test(provider: provider(), key: nil); XCTFail() }
        catch { XCTAssertEqual(error as? ProviderConnectionFailure, .inconclusive) }
        ProviderHTTPProtocol.state.configure(.init(status: 302, redirect: URL(string: "https://other.example.invalid")))
        do { try await client.test(provider: provider(), key: "fixture-secret"); XCTFail() }
        catch { XCTAssertEqual(error as? ProviderConnectionFailure, .inconclusive) }
        XCTAssertEqual(ProviderHTTPProtocol.state.recorded().count, 1)
    }
}

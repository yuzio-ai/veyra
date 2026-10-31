import Foundation
import XCTest

final class CodexModelConfigurationIntegrationTests: XCTestCase {
    func testIsolatedRealCodexProviderReselectionAndConflictPreserveComments() async throws {
        guard let executable = CodexLocation.resolve().executable else { throw XCTSkip("Codex is not installed") }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("veyra-real-config-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("config.toml")
        try "model = \"original-model\"\nmodel_reasoning_effort = \"high\"\n\n# Keep this fixture comment\n[tui]\nnotifications = false\n".write(to: file, atomically: true, encoding: .utf8)
        let location = CodexLocation(home: home, executable: executable)
        let client = AppServerClient(requestTimeout: .seconds(8))
        let service = CodexModelProfileService(transport: client, root: home.appendingPathComponent("library"))
        let initial = try await service.read(location: location)
        var profile = CodexModelProfile(name: "Fixture gateway", kind: .custom, model: "fixture-model",
                                       baseURL: "https://gateway.example.invalid/v1", environmentKey: "VEYRA_FIXTURE_KEY")
        var custom = try await service.apply(profile, location: location, expectedVersion: initial.snapshot.version)
        XCTAssertTrue(profile.matches(custom.snapshot))
        let original = try await service.restoreOpenAI(location: location, expectedVersion: custom.snapshot.version)
        XCTAssertEqual(original.snapshot.user["model"].string, "original-model")
        XCTAssertNotNil(original.snapshot.user["model_providers"][profile.providerID].object)
        custom = try await service.apply(profile, location: location, expectedVersion: original.snapshot.version)
        // No API key is provided and no model/account endpoint is called.
        let official = try await service.apply(CodexModelProfile(name: "Official"), location: location,
                                              expectedVersion: custom.snapshot.version)
        XCTAssertNil(official.snapshot.user["model"].string)
        XCTAssertNil(official.snapshot.user["model_reasoning_effort"].string)
        XCTAssertEqual(official.snapshot.user["model_provider"].string, "openai")
        let restored = try await service.apply(profile, location: location, expectedVersion: official.snapshot.version)
        XCTAssertTrue(profile.matches(restored.snapshot))
        profile.model = "should-not-apply"
        do {
            _ = try await service.apply(profile, location: location, expectedVersion: initial.snapshot.version)
            XCTFail("stale version must fail")
        } catch { XCTAssertEqual(error as? ModelProfileFailure, .conflict) }
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("# Keep this fixture comment"))
        XCTAssertTrue(text.contains("[tui]"))
        XCTAssertTrue(text.contains("notifications = false"))
        XCTAssertFalse(text.contains("should-not-apply"))
        await client.shutdown()
    }
    func testIsolatedRealCodexPresetRPCAndOfficialRestore() async throws {
        guard let executable = CodexLocation.resolve().executable else { throw XCTSkip("Codex is not installed") }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("veyra-real-presets-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("config.toml")
        try "model = \"original-model\"\n# Keep this fixture comment\n[tui]\nnotifications = false\n".write(to: file, atomically: true, encoding: .utf8)
        let location = CodexLocation(home: home, executable: executable)
        let client = AppServerClient(requestTimeout: .seconds(8))
        let service = CodexModelProfileService(transport: client, root: home.appendingPathComponent("library"), credentials: MemoryCredentialStore(),
            helperExecutable: URL(fileURLWithPath: "/Applications/Veyra.app/Contents/MacOS/Veyra"), modelClient: ProviderModelFixture())
        var context = try await service.read(location: location)
        for preset in ProviderPreset.all {
            _ = try await service.saveDiscoveredProvider(ProviderSettings(preset: preset), newKey: "fixture-not-a-real-key", home: home)
            do { context = try await service.applyProvider(preset.id, location: location, expectedVersion: context.snapshot.version) }
            catch { XCTFail("Isolated \(preset.id) configuration transaction failed: \(error)"); throw error }
            XCTAssertEqual(context.snapshot.user["model_provider"].string, "veyra_preset_" + preset.id)
            XCTAssertNotNil(context.snapshot.configuredProvider["auth"].object)
        }
        context = try await service.restoreOpenAI(location: location, expectedVersion: context.snapshot.version)
        XCTAssertEqual(context.snapshot.user["model"].string, "original-model")
        XCTAssertEqual(context.snapshot.user["tui"]["notifications"].bool, false)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains("fixture-not-a-real-key")); XCTAssertTrue(text.contains("# Keep this fixture comment"))
        await client.shutdown()
    }

}

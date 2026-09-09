import Foundation
import XCTest

private actor SettingsGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        await withCheckedContinuation {
            continuation = $0
            observers.forEach { $0.resume() }
            observers = []
        }
    }
    func waitUntilHeld() async {
        if continuation == nil { await withCheckedContinuation { observers.append($0) } }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
final class CodexConfigurationTests: XCTestCase {
    private func fixture() throws -> (home: URL, executable: URL) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("veyra-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let executable = home.appendingPathComponent("codex")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        addTeardownBlock { try FileManager.default.removeItem(at: home) }
        return (home, executable)
    }

    private func defaults() -> UserDefaults {
        let suite = "veyra-settings-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func store(defaults: UserDefaults, location: CodexLocation,
                       validate: @escaping @Sendable (String, CodexPathField) async -> CodexPathError? = CodexConfiguration.validate) -> MonitorStore {
        let store = MonitorStore(defaults: defaults, inspectConfiguration: { _, _ in
            CodexConfigurationReport(location: location, state: .valid)
        }, validatePath: validate)
        store.isPreview = true
        return store
    }

    func testValidationAcceptsDirectoriesExecutablesSymlinksAndBlankOverrides() async throws {
        let fixture = try fixture()
        let link = fixture.home.appendingPathComponent("linked-codex")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.executable)
        let depth = FileManager.default.homeDirectoryForCurrentUser.pathComponents.count - 1
        let tildePath = "~/" + String(repeating: "../", count: depth) + fixture.home.path.dropFirst()
        for (path, field) in [(tildePath, CodexPathField.home), (fixture.home.path, CodexPathField.home), (fixture.executable.path, .executable),
                              (link.path, .executable), (" \n", .home), ("", .executable)] {
            let error = await CodexConfiguration.validate(path, field: field)
            XCTAssertNil(error, path)
        }
        XCTAssertEqual(CodexConfiguration.normalized(" \n/example path \n"), "/example path")
        let report = await CodexConfiguration.inspect(home: fixture.home.path, executable: link.path)
        XCTAssertEqual(report.state, .valid)
        XCTAssertEqual(report.location.executable?.path, link.path)
    }

    func testValidationRejectsRelativeMissingWrongKindAndNonExecutablePaths() async throws {
        let fixture = try fixture()
        let plain = fixture.home.appendingPathComponent("plain")
        try Data().write(to: plain)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plain.path)
        let broken = fixture.home.appendingPathComponent("broken")
        try FileManager.default.createSymbolicLink(at: broken, withDestinationURL: fixture.home.appendingPathComponent("missing"))
        let cases: [(String, CodexPathField, CodexPathError)] = [
            ("relative/codex", .executable, .absolutePathRequired),
            (fixture.executable.path, .home, .invalidDirectory),
            (fixture.home.path, .executable, .invalidExecutable),
            (plain.path, .executable, .invalidExecutable),
            (broken.path, .executable, .invalidExecutable),
            (fixture.home.appendingPathComponent("missing").path, .home, .invalidDirectory),
        ]
        for (path, field, expected) in cases {
            let error = await CodexConfiguration.validate(path, field: field)
            XCTAssertEqual(error, expected)
        }
        let badHome = await CodexConfiguration.inspect(home: plain.path, executable: fixture.executable.path)
        let badExecutable = await CodexConfiguration.inspect(home: fixture.home.path, executable: plain.path)
        XCTAssertEqual(badHome.state, .invalid(.home))
        XCTAssertEqual(badExecutable.state, .invalid(.executable))
    }

    func testCommitsPersistIndependentlyAndInvalidDraftNeverChangesSavedConfiguration() async throws {
        let fixture = try fixture(), defaults = defaults()
        let location = CodexLocation(home: fixture.home, executable: fixture.executable)
        let store = store(defaults: defaults, location: location)
        let homeResult = await store.commitPath(" \(fixture.home.path) \n", field: .home)
        XCTAssertEqual(homeResult, .applied)
        let badResult = await store.commitPath("bad-relative-path", field: .home)
        XCTAssertEqual(badResult, .rejected(.absolutePathRequired))
        let executableResult = await store.commitPath(fixture.executable.path, field: .executable)
        XCTAssertEqual(executableResult, .applied)
        XCTAssertEqual(store.homePath, fixture.home.path)
        XCTAssertEqual(defaults.string(forKey: "codexHome"), fixture.home.path)
        XCTAssertEqual(defaults.string(forKey: "codexExecutable"), fixture.executable.path)
        let reopened = self.store(defaults: defaults, location: location)
        XCTAssertEqual(reopened.homePath, fixture.home.path)
        XCTAssertEqual(reopened.executablePath, fixture.executable.path)
        XCTAssertTrue(reopened.hasManualPaths)
        let cleared = await store.commitPath("", field: .home)
        XCTAssertEqual(cleared, .applied)
        XCTAssertEqual(store.executablePath, fixture.executable.path)
        await store.restoreAutomaticPaths()
        XCTAssertFalse(store.hasManualPaths)
        XCTAssertEqual(defaults.string(forKey: "codexHome"), "")
        XCTAssertEqual(defaults.string(forKey: "codexExecutable"), "")
    }

    func testRepeatedSubmissionDoesNotClearExistingSnapshot() async throws {
        let fixture = try fixture(), defaults = defaults()
        let store = store(defaults: defaults, location: CodexLocation(home: fixture.home, executable: fixture.executable))
        _ = await store.commitPath(fixture.home.path, field: .home)
        store.tasksUpdatedAt = Date(timeIntervalSince1970: 100)
        let result = await store.commitPath(" \(fixture.home.path) ", field: .home)
        XCTAssertEqual(result, .unchanged)
        XCTAssertEqual(store.tasksUpdatedAt, Date(timeIntervalSince1970: 100))
    }

    func testRestoringAndClearingOverridesSucceedsEvenWhenDiscoveryFails() async throws {
        let fixture = try fixture(), defaults = defaults()
        defaults.set(fixture.home.path, forKey: "codexHome")
        let store = MonitorStore(defaults: defaults, inspectConfiguration: { _, _ in
            CodexConfigurationReport(location: CodexLocation(home: fixture.home, executable: nil), state: .notFound)
        })
        store.isPreview = true
        let result = await store.commitPath("", field: .home)
        XCTAssertEqual(result, .applied)
        XCTAssertEqual(store.configurationState, .notFound)
        await store.restoreAutomaticPaths()
        XCTAssertEqual(store.configurationState, .notFound)
        XCTAssertFalse(store.hasManualPaths)
    }

    func testNewerCommitAndRestoreSupersedePendingValidation() async throws {
        for restore in [false, true] {
            let fixture = try fixture(), defaults = defaults(), gate = SettingsGate()
            let location = CodexLocation(home: fixture.home, executable: fixture.executable)
            let store = store(defaults: defaults, location: location, validate: { path, _ in
                if !path.isEmpty { await gate.hold() }
                return nil
            })
            let oldResetVersion = store.pathResetRevision
            let pending = Task { await store.commitPath(fixture.home.path, field: .home) }
            await gate.waitUntilHeld()
            if restore { await store.restoreAutomaticPaths() }
            else { _ = await store.commitPath("", field: .home) }
            await gate.release()
            let result = await pending.value
            XCTAssertEqual(result, .superseded)
            XCTAssertEqual(store.homePath, "")
            XCTAssertNil(defaults.string(forKey: "codexHome"))
            if restore {
                let queued = await store.commitPath(fixture.home.path, field: .home, resetVersion: oldResetVersion)
                XCTAssertEqual(queued, .superseded)
            }
        }
    }

    func testOldDetectionCannotOverwriteNewConfiguration() async throws {
        let fixture = try fixture(), gate = SettingsGate(), defaults = defaults()
        let location = CodexLocation(home: fixture.home, executable: fixture.executable)
        let store = MonitorStore(defaults: defaults, inspectConfiguration: { home, _ in
            if home.isEmpty {
                await gate.hold()
                return CodexConfigurationReport(location: location, state: .notFound)
            }
            return CodexConfigurationReport(location: location, state: .valid)
        })
        store.isPreview = true
        let old = Task { await store.detectConfiguration() }
        await gate.waitUntilHeld()
        XCTAssertEqual(store.configurationState, .detecting)
        let result = await store.commitPath(fixture.home.path, field: .home)
        XCTAssertEqual(result, .applied)
        await gate.release()
        await old.value
        XCTAssertEqual(store.configurationState, .valid)
        XCTAssertEqual(store.configurationLocation, location)
    }
}

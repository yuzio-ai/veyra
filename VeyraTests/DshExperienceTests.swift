import Foundation
import XCTest

@MainActor
final class DshExperienceTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let suite = "veyra-dsh-experience-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return defaults
    }

    /// A defaults suite whose dsh data directory is a temp folder, so the
    /// default project resolver never reads the developer's real ~/.dsh.
    private func isolatedDefaults() -> UserDefaults {
        let suite = defaults()
        let dshHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("veyra-dsh-experience-home-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dshHome, withIntermediateDirectories: true)
        suite.set(dshHome.path, forKey: "dshHome")
        addTeardownBlock { try? FileManager.default.removeItem(at: dshHome) }
        return suite
    }

    private func task(_ id: String = "dsh:fixture", backend: TaskBackend = .dsh) -> TaskSnapshot {
        TaskSnapshot(id: id, title: "Fixture", model: "fixture-model", source: .desktop, parentID: nil,
                     startedAt: .now, updatedAt: .now, tokens: TokenUsage(input: 10, output: 2, total: 12),
                     activity: .running, backend: backend)
    }


    /// Detached refresh tasks need wall-clock time, not only a yield budget.
    private func drain() async {
        for _ in 0..<40 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for isolated source state")
    }

    func testPureDshCountsTasksAndNeverRequestsCodexQuota() async throws {
        let folder = try SQLiteFixture(), clock = TestPollingClock(), counter = DshRequestCounter()
        let absent = CodexLocation(home: folder.home.appendingPathComponent("no-codex"), executable: nil)
        let running = task()
        let store = MonitorStore(readDsh: { _ in
            DshTaskRead(tasks: [running], fetchedAt: .now, warning: nil, parsedFiles: 1, skippedFiles: 0)
        }, fetchQuota: { _ in await counter.fetch() }, clock: clock.clock, defaults: isolatedDefaults(),
        resolveLocation: { _, _ in absent })
        store.start(); await store.refreshAll(); await drain()
        store.setPanelVisible(true)
        await store.calibrateQuota()
        clock.advance(3600); await store.refreshAll(); await drain()
        XCTAssertEqual(store.codexReadState, .notFound)
        XCTAssertEqual(store.dshReadState, .available)
        XCTAssertEqual(store.menuTaskCount, "1")
        XCTAssertFalse(store.showsQuota)
        XCTAssertFalse(store.hasSourceWarning)
        let quotas = await counter.requests
        XCTAssertEqual(quotas, 0)
        store.sleep(); clock.advance(3600); store.wake(); await store.refreshAll(); await drain()
        let afterWake = await counter.requests
        XCTAssertEqual(afterWake, 0)
        store.stop(); clock.finish(); await drain()
    }

    func testNoSourcesIsNormalAndAnEmptyReadableDshDirectoryCountsZero() async throws {
        let folder = try SQLiteFixture()
        let absent = CodexLocation(home: folder.home.appendingPathComponent("no-codex"), executable: nil)
        // Resolve dsh through an isolated reader instead of the user's installation.
        let reader = DshTaskReader(collectEvidence: { _ in DshProcessEvidence() })
        let dshHome = folder.home
        let isolated = MonitorStore(readDsh: { _ in await reader.fetch(home: dshHome) },
                                    defaults: defaults(), resolveLocation: { _, _ in absent })
        XCTAssertEqual(isolated.menuTaskCount, "—")
        await isolated.refreshAll()
        XCTAssertTrue(isolated.noSourcesFound)
        XCTAssertFalse(isolated.hasSourceWarning)
        XCTAssertEqual(isolated.menuTaskCount, "0")
        let sessions = folder.home.appendingPathComponent("storages/session_projcache/sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        await isolated.refreshAll()
        XCTAssertEqual(isolated.dshReadState, .available)
        XCTAssertFalse(isolated.noSourcesFound)
        XCTAssertTrue(isolated.hasTaskSnapshot)
        XCTAssertEqual(isolated.menuTaskCount, "0")
        try FileManager.default.removeItem(at: sessions)
        await isolated.refreshAll()
        XCTAssertEqual(isolated.dshReadState, .failed)
        XCTAssertNotNil(isolated.dshWarning)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        await isolated.refreshAll()
        XCTAssertEqual(isolated.dshReadState, .available)
        XCTAssertNil(isolated.dshWarning)
    }

    func testDshReaderDistinguishesMissingFromInvalidDirectoryAndRecovers() async throws {
        let folder = try SQLiteFixture()
        let reader = DshTaskReader(collectEvidence: { _ in DshProcessEvidence() })
        var result = await reader.fetch(home: folder.home)
        XCTAssertEqual(result.state, .notFound); XCTAssertNil(result.warning)
        let sessions = folder.home.appendingPathComponent("storages/session_projcache/sessions")
        try FileManager.default.createDirectory(at: sessions.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("invalid directory".utf8).write(to: sessions)
        result = await reader.fetch(home: folder.home)
        XCTAssertEqual(result.state, .failed); XCTAssertNotNil(result.warning)
        try FileManager.default.removeItem(at: sessions)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        result = await reader.fetch(home: folder.home)
        XCTAssertEqual(result.state, .available); XCTAssertNil(result.warning)
    }

    func testCodexWithoutTaskDatabaseStillHasServicesButNoTaskError() async throws {
        let folder = try SQLiteFixture()
        let location = CodexLocation(home: folder.home, executable: URL(fileURLWithPath: "/usr/bin/true"))
        let store = MonitorStore(readDsh: { _ in .empty }, defaults: defaults(), resolveLocation: { _, _ in location })
        await store.refreshAll()
        XCTAssertTrue(store.showsQuota)
        XCTAssertTrue(store.codexHasNoTaskData)
        XCTAssertNil(store.taskError)
        XCTAssertEqual(store.menuTaskCount, "0")
    }

    func testDshPathValidationAndResetPreserveCodexTasksAndQuota() async throws {
        let folder = try SQLiteFixture(), settings = defaults()
        let codex = task("codex", backend: .codex), dsh = task()
        let location = CodexLocation(home: folder.home, executable: URL(fileURLWithPath: "/usr/bin/true"))
        let store = MonitorStore(readLocal: { _ in TaskReadResult(tasks: [codex], fetchedAt: .now, warning: nil) },
            readDsh: { _ in DshTaskRead(tasks: [dsh], fetchedAt: .now, warning: nil, parsedFiles: 1, skippedFiles: 0) },
            defaults: settings, resolveLocation: { _, _ in location })
        await store.refreshAll()
        let quota = QuotaSnapshot(windows: [], fetchedAt: .now, accountID: "fixture")
        store.quota.snapshot = quota
        let invalid = await store.commitDshPath("relative/path")
        XCTAssertEqual(invalid, .rejected(.absolutePathRequired))
        XCTAssertNil(settings.string(forKey: "dshHome"))
        let applied = await store.commitDshPath("  " + folder.home.path + " \n")
        XCTAssertEqual(applied, .applied)
        XCTAssertEqual(settings.string(forKey: "dshHome"), folder.home.path)
        XCTAssertEqual(store.tasks.first { $0.id == "codex" }?.activity, .running)
        XCTAssertEqual(store.quota.snapshot, quota)
        let reset = await store.commitDshPath("", restoringAutomatic: true)
        XCTAssertEqual(reset, .applied)
        XCTAssertEqual(store.dshHomePath, "")
        XCTAssertEqual(store.tasks.first { $0.id == "codex" }?.activity, .running)
        XCTAssertEqual(store.quota.snapshot, quota)
        store.stop()
    }

    func testServiceLossClearsQuotaAndRecoveryResumesMonitoring() async throws {
        let folder = try SQLiteFixture(), clock = TestPollingClock(), counter = DshRequestCounter()
        let executable = folder.home.appendingPathComponent("codex")
        try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        let location = CodexLocation(home: folder.home, executable: executable)
        let store = MonitorStore(readDsh: { _ in .empty }, fetchQuota: { _ in await counter.fetch() },
            clock: clock.clock, now: { Date(timeIntervalSince1970: 300 + Double(clock.instant.components.seconds)) },
            defaults: defaults(), resolveLocation: { _, _ in location })
        store.quota.snapshot = QuotaSnapshot(windows: [], fetchedAt: .now, accountID: "fixture")
        try FileManager.default.removeItem(at: executable)
        await store.refreshAll()
        XCTAssertFalse(store.showsQuota)
        XCTAssertNil(store.quota.snapshot)
        XCTAssertNotNil(store.codexServiceWarning)
        await store.calibrateQuota()
        let unavailableRequests = await counter.requests
        XCTAssertEqual(unavailableRequests, 0)
        try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        await store.refreshAll()
        XCTAssertTrue(store.showsQuota)
        XCTAssertNil(store.codexServiceWarning)
        await store.calibrateQuota()
        let recoveredRequests = await counter.requests
        XCTAssertEqual(recoveredRequests, 1)
        store.stop(); clock.finish(); await drain()
    }

    func testDshPathPrecedenceAndWhitespaceEnvironment() {
        XCTAssertEqual(DshLocation.resolve(homePath: " /tmp/explicit ", environment: ["DSH_HOME": "/tmp/env"]).home.path, "/tmp/explicit")
        XCTAssertEqual(DshLocation.resolve(environment: ["DSH_HOME": " /tmp/env \n"]).home.path, "/tmp/env")
        XCTAssertEqual(DshLocation.resolve(environment: ["DSH_HOME": " \n"]).home,
                       DshLocation.resolve(environment: [:]).home)
    }

    func testBenchmarkLaunchPathOverridesSavedDshDirectoryWithoutChangingIt() async throws {
        let folder = try SQLiteFixture()
        let manual = folder.home.appendingPathComponent("saved-dsh")
        let benchmark = folder.home.appendingPathComponent("benchmark-dsh")
        let sessions = "storages/session_projcache/sessions"
        for home in [manual, benchmark] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(sessions), withIntermediateDirectories: true)
        }
        // The saved directory would produce a warning if the benchmark read it.
        try Data("not a session".utf8).write(to: manual.appendingPathComponent(sessions + "/private.json"))
        let suite = "veyra-dsh-benchmark-" + UUID().uuidString
        let settings = UserDefaults(suiteName: suite)!
        settings.set(manual.path, forKey: "dshHome")
        let arguments = settings.volatileDomain(forName: UserDefaults.argumentDomain)
        defer {
            settings.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            settings.removePersistentDomain(forName: suite)
        }
        // Foundation places the benchmark's -dshHome argument in this domain.
        settings.setVolatileDomain(arguments.merging(["dshHome": benchmark.path]) { _, new in new },
                                   forName: UserDefaults.argumentDomain)
        let reader = DshTaskReader(collectEvidence: { _ in DshProcessEvidence() })
        let absent = CodexLocation(home: folder.home.appendingPathComponent("no-codex"), executable: nil)
        let store = MonitorStore(readDsh: { await reader.fetch(home: $0) }, defaults: settings,
                                 resolveLocation: { _, _ in absent })
        XCTAssertEqual(store.dshLocation.home.path, benchmark.path)
        await store.refreshAll()
        XCTAssertEqual(store.dshReadState, .available)
        XCTAssertNil(store.dshWarning)
        XCTAssertEqual(store.menuTaskCount, "0")
        XCTAssertEqual(settings.persistentDomain(forName: suite)?["dshHome"] as? String, manual.path)
        store.stop()
    }
}

private actor DshRequestCounter {
    private(set) var requests = 0
    func fetch() -> QuotaRefresh { requests += 1; return QuotaRefresh(error: .missingExecutable) }
}

@MainActor
extension DshExperienceTests {
    func testPendingOldDshReadCannotOverwriteNewDirectory() async throws {
        let folder = try SQLiteFixture(), settings = defaults(), gate = DshExperienceGate()
        let oldHome = folder.home.appendingPathComponent("old")
        let newHome = folder.home.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: oldHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newHome, withIntermediateDirectories: true)
        settings.set(oldHome.path, forKey: "dshHome")
        let location = CodexLocation(home: folder.home, executable: URL(fileURLWithPath: "/usr/bin/true"))
        let old = task("dsh:old"), new = task("dsh:new"), codex = task("codex", backend: .codex)
        let store = MonitorStore(readLocal: { _ in TaskReadResult(tasks: [codex], fetchedAt: .now, warning: nil) },
            readDsh: { home in
                if home.path == oldHome.path { await gate.hold() }
                return DshTaskRead(tasks: [home.path == oldHome.path ? old : new], fetchedAt: .now, warning: nil, parsedFiles: 1, skippedFiles: 0)
            }, defaults: settings, resolveLocation: { _, _ in location })
        let refresh = Task { await store.refreshAll() }
        await gate.waitUntilHeld()
        let change = Task { await store.commitDshPath(newHome.path) }
        try await waitUntil { store.dshHomePath == newHome.path }
        XCTAssertEqual(store.dshHomePath, newHome.path)
        await gate.release()
        await refresh.value
        let result = await change.value
        XCTAssertEqual(result, .applied)
        XCTAssertEqual(Set(store.tasks.map(\.id)), ["codex", "dsh:new"])
        XCTAssertEqual(store.menuTaskCount, "2")
        store.stop()
    }

    func testExplicitMissingDshDirectoryWarnsWithoutChangingCodexCount() async throws {
        let folder = try SQLiteFixture(), settings = defaults()
        settings.set(folder.home.appendingPathComponent("missing-dsh").path, forKey: "dshHome")
        let codex = task("codex", backend: .codex)
        let location = CodexLocation(home: folder.home, executable: URL(fileURLWithPath: "/usr/bin/true"))
        let store = MonitorStore(readLocal: { _ in TaskReadResult(tasks: [codex], fetchedAt: .now, warning: nil) },
                                 defaults: settings, resolveLocation: { _, _ in location })
        await store.refreshAll()
        XCTAssertEqual(store.dshReadState, .failed)
        XCTAssertNotNil(store.dshWarning)
        XCTAssertEqual(store.menuTaskCount, "1")
        XCTAssertTrue(store.hasSourceWarning)
        XCTAssertNil(store.taskError)
    }
}

private actor DshExperienceGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        await withCheckedContinuation {
            continuation = $0
            observers.forEach { $0.resume() }; observers = []
        }
    }
    func waitUntilHeld() async {
        if continuation == nil { await withCheckedContinuation { observers.append($0) } }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
extension DshExperienceTests {
    func testDshRestoreSupersedesPendingValidation() async throws {
        let folder = try SQLiteFixture(), settings = defaults(), gate = DshExperienceGate()
        let absent = CodexLocation(home: folder.home.appendingPathComponent("no-codex"), executable: nil)
        let store = MonitorStore(readDsh: { _ in .empty }, defaults: settings,
            validatePath: { path, _ in
                if !path.isEmpty { await gate.hold() }
                return nil
            }, resolveLocation: { _, _ in absent })
        let change = Task { await store.commitDshPath(folder.home.path) }
        await gate.waitUntilHeld()
        let reset = await store.commitDshPath("", restoringAutomatic: true)
        XCTAssertEqual(reset, .unchanged)
        await gate.release()
        let old = await change.value
        XCTAssertEqual(old, .superseded)
        XCTAssertEqual(store.dshHomePath, "")
        XCTAssertNil(settings.string(forKey: "dshHome"))
    }
}

@MainActor
extension DshExperienceTests {
    func testReadableCodexTasksDoNotRequireAnExecutable() async throws {
        let folder = try SQLiteFixture(), settings = defaults()
        settings.set(folder.home.path, forKey: "codexHome")
        let codex = task("codex", backend: .codex)
        let location = CodexLocation(home: folder.home, executable: nil)
        let store = MonitorStore(readLocal: { _ in TaskReadResult(tasks: [codex], fetchedAt: .now, warning: nil) },
            readDsh: { _ in .empty }, defaults: settings, resolveLocation: { _, _ in location })
        await store.refreshAll()
        XCTAssertEqual(store.codexReadState, .available)
        XCTAssertEqual(store.menuTaskCount, "1")
        XCTAssertFalse(store.showsQuota)
        XCTAssertFalse(store.hasSourceWarning)
    }
}

@MainActor
extension DshExperienceTests {
    func testReturningToDetectedDshPathSupersedesOlderValidationWithoutCreatingOverride() async throws {
        let folder = try SQLiteFixture(), settings = defaults(), gate = DshExperienceGate()
        let absent = CodexLocation(home: folder.home.appendingPathComponent("no-codex"), executable: nil)
        let requested = folder.home.appendingPathComponent("chosen").path
        let store = MonitorStore(readDsh: { _ in .empty }, defaults: settings,
            validatePath: { path, _ in
                if path == requested { await gate.hold() }
                return nil
            }, resolveLocation: { _, _ in absent })
        let old = Task { await store.commitDshPath(requested) }
        await gate.waitUntilHeld()
        let detected = store.dshLocation.home.path
        let current = await store.commitDshPath(detected)
        await gate.release()
        let outdated = await old.value
        XCTAssertEqual(current, .unchanged)
        XCTAssertEqual(outdated, .superseded)
        XCTAssertEqual(store.dshHomePath, "")
        XCTAssertNil(settings.string(forKey: "dshHome"))
    }

    func testCodexDatabaseInHomeIsReadableDespiteUnrelatedInvalidSQLitePath() async throws {
        let folder = try SQLiteFixture(); try folder.threads()
        try Data("unrelated file".utf8).write(to: folder.home.appendingPathComponent("sqlite"))
        let reader = LocalTaskReader(collectEvidence: { _ in ProcessEvidence() })
        let read = try await reader.fetch(home: folder.home)
        XCTAssertTrue(read.tasks.isEmpty)
        XCTAssertNil(read.warning)
    }

    func testCodexPathChangeDrainingDshReadDoesNotRestartMonitoringDuringSleep() async throws {
        let folder = try SQLiteFixture(), gate = DshExperienceGate(), clock = TestPollingClock()
        let probe = DshReviewReadProbe()
        let location = CodexLocation(home: folder.home, executable: nil)
        let store = MonitorStore(readLocal: { _ in
            await probe.read()
            return TaskReadResult(tasks: [], fetchedAt: .now, warning: nil)
        }, readDsh: { _ in
            if await probe.isFirstDshRead() { await gate.hold() }
            return .empty
        }, clock: clock.clock, defaults: defaults(), resolveLocation: { _, _ in location })
        store.start()
        await gate.waitUntilHeld()
        store.saveSettings(home: folder.home.path, executable: "")
        store.sleep()
        await gate.release()
        await drain()
        clock.advance(3600); await drain()
        let asleepReads = await probe.count
        XCTAssertEqual(asleepReads, 1, "A delayed path restart must not undo sleep suspension")
        store.wake(); await store.refreshAll()
        let awakeReads = await probe.count
        XCTAssertEqual(awakeReads, 2)
        store.stop(); clock.finish(); await drain()
    }
}

private actor DshReviewReadProbe {
    private(set) var count = 0
    private var dshReads = 0
    func read() { count += 1 }
    func isFirstDshRead() -> Bool { dshReads += 1; return dshReads == 1 }
}

@MainActor
extension DshExperienceTests {
    func testDshRestoreRejectsAQueuedSubmissionFromBeforeReset() async throws {
        let folder = try SQLiteFixture(), settings = defaults()
        let absent = CodexLocation(home: folder.home.appendingPathComponent("no-codex"), executable: nil)
        let store = MonitorStore(readDsh: { _ in .empty }, defaults: settings, resolveLocation: { _, _ in absent })
        let oldReset = store.dshPathResetRevision
        _ = await store.commitDshPath("", restoringAutomatic: true)
        let queued = await store.commitDshPath(folder.home.path, resetVersion: oldReset)
        XCTAssertEqual(queued, .superseded)
        XCTAssertEqual(store.dshHomePath, "")
        XCTAssertNil(settings.string(forKey: "dshHome"))
    }
}


@MainActor
extension DshExperienceTests {
    func testReorderedDshSubmissionTasksKeepLatestUIChoice() async throws {
        let folder = try SQLiteFixture(), settings = defaults()
        let absent = CodexLocation(home: folder.home.appendingPathComponent("no-codex"), executable: nil)
        let store = MonitorStore(readDsh: { _ in .empty }, defaults: settings, resolveLocation: { _, _ in absent })
        let old = store.beginDshPathSubmission()
        let current = store.beginDshPathSubmission()
        let latest = await store.commitDshPath(store.dshLocation.home.path, submissionVersion: current)
        let reordered = await store.commitDshPath(folder.home.path, submissionVersion: old)
        XCTAssertEqual(latest, .unchanged)
        XCTAssertEqual(reordered, .superseded)
        XCTAssertEqual(store.dshHomePath, "")
        XCTAssertNil(settings.string(forKey: "dshHome"))
    }
}

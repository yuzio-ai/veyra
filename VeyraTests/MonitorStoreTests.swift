import XCTest
import Foundation

private actor MonitorFixture {
    var localReads = 0
    var networkReads = 0
    var networkResult = QuotaRefresh(snapshot: QuotaSnapshot(windows: [], fetchedAt: Date(timeIntervalSince1970: 200), accountID: "fixture"), didRequestQuota: true)
    var networkGate: CheckedContinuation<Void, Never>?
    var gateWaiters: [CheckedContinuation<Void, Never>] = []
    var holdNetwork = false
    func read() -> TaskReadResult {
        localReads += 1
        return TaskReadResult(tasks: [], fetchedAt: .now, warning: nil)
    }
    func network() async -> QuotaRefresh {
        networkReads += 1
        let result = networkResult
        if holdNetwork {
            await withCheckedContinuation {
                networkGate = $0
                gateWaiters.forEach { $0.resume() }; gateWaiters = []
            }
        }
        return result
    }
    func counts() -> (Int, Int) { (localReads, networkReads) }
    func setNetwork(_ result: QuotaRefresh) { networkResult = result }
    func hold() { holdNetwork = true }
    func waitUntilHeld() async {
        if networkGate == nil { await withCheckedContinuation { gateWaiters.append($0) } }
    }
    func release() { holdNetwork = false; networkGate?.resume(); networkGate = nil }
}

@MainActor
final class MonitorStoreTests: XCTestCase {
    /// Give detached refresh tasks real wall-clock time, not only a fixed yield
    /// count: under load the scheduler can starve them for many yields, which
    /// made quota-count assertions flaky.
    private func drain() async {
        for _ in 0..<20 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    /// Poll for a condition that a detached refresh task satisfies, with a
    /// deadline instead of a fixed sleep budget.
    private func waitUntil(_ message: String, _ condition: @escaping @MainActor () async -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !(await condition()) {
            if Date() >= deadline {
                XCTFail("Timed out waiting for \(message)")
                return
            }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func defaults(home: URL) -> UserDefaults {
        let suite = "veyra-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(home.path, forKey: "codexHome")
        defaults.set("/usr/bin/true", forKey: "codexExecutable")
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return defaults
    }

    /// A suite whose dsh data directory is a temp folder. Use it only where the
    /// store actually produces dsh tasks: the default project resolver reads
    /// that directory, and a test must never inspect the developer's ~/.dsh.
    /// (Presetting a path would also turn a "dsh not installed" read into the
    /// configured-but-missing warning, so it is not the default suite.)
    private func dshIsolatedDefaults(home: URL) -> UserDefaults {
        let defaults = defaults(home: home)
        let dshHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("veyra-dsh-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dshHome, withIntermediateDirectories: true)
        defaults.set(dshHome.path, forKey: "dshHome")
        addTeardownBlock { try? FileManager.default.removeItem(at: dshHome) }
        return defaults
    }
    private var verifiedQuota: QuotaRefresh {
        let account = AccountSnapshot(json: .object(["type": .string("chatgpt"), "email": .string("a@example.invalid")]), accountID: "account-a")
        let window = QuotaWindow(id: "codex:primary", bucketID: "codex", bucketName: "Codex", isPrimary: true,
                                 usedPercent: 20, durationMinutes: 300, resetsAt: nil)
        return QuotaRefresh(account: account, snapshot: QuotaSnapshot(windows: [window],
                            fetchedAt: Date(timeIntervalSince1970: 200), accountID: "account-a"), didRequestQuota: true)
    }
    func testCalibrationInvalidatesChangedAuthenticationBeforeEarlyFailure() async throws {
        for failure: QuotaFailure in [.timeout, .disconnected] {
            let folder = try SQLiteFixture(), fixture = MonitorFixture()
            await fixture.setNetwork(verifiedQuota)
            var now = Date(timeIntervalSince1970: 300)
            let store = MonitorStore(readLocal: { _ in await fixture.read() }, readDsh: { _ in .empty }, fetchQuota: { _ in await fixture.network() },
                                     now: { now }, defaults: defaults(home: folder.home))
            await store.refreshAll()
            await store.calibrateQuota()
            XCTAssertEqual(store.quota.account?.identity, "account-a")
            try Data("changed auth fixture".utf8).write(to: folder.home.appendingPathComponent("auth.json"), options: .atomic)
            await fixture.setNetwork(QuotaRefresh(error: failure))
            now = now.addingTimeInterval(61)
            await store.calibrateQuota()
            XCTAssertNil(store.quota.account)
            XCTAssertNil(store.quota.snapshot)
            XCTAssertEqual(store.quota.error, failure.message)
            await store.refreshAll()
            XCTAssertNil(store.quota.account)
            XCTAssertNil(store.quota.snapshot)
            let counts = await fixture.counts()
            XCTAssertEqual(counts.1, 2)
            store.stop()
        }
    }
    func testCalibrationFailureKeepsVerifiedQuotaWhenAuthenticationIsUnchanged() async throws {
        let folder = try SQLiteFixture(), fixture = MonitorFixture()
        let verified = verifiedQuota
        await fixture.setNetwork(verified)
        var now = Date(timeIntervalSince1970: 300)
        let store = MonitorStore(readDsh: { _ in .empty }, fetchQuota: { _ in await fixture.network() }, now: { now }, defaults: defaults(home: folder.home))
        await store.calibrateQuota()
        await fixture.setNetwork(QuotaRefresh(error: .timeout))
        now = now.addingTimeInterval(61)
        await store.calibrateQuota()
        XCTAssertEqual(store.quota.account, verified.account)
        XCTAssertEqual(store.quota.snapshot, verified.snapshot)
        XCTAssertEqual(store.quota.error, QuotaFailure.timeout.message)
    }
    func testAuthenticationChangeDuringCooldownInvalidatesWithoutRequestingQuota() async throws {
        let folder = try SQLiteFixture(), fixture = MonitorFixture()
        await fixture.setNetwork(verifiedQuota)
        let now = Date(timeIntervalSince1970: 300)
        let store = MonitorStore(readLocal: { _ in await fixture.read() }, readDsh: { _ in .empty }, fetchQuota: { _ in await fixture.network() },
                                 now: { now }, defaults: defaults(home: folder.home))
        await store.refreshAll()
        await store.calibrateQuota()
        let deadline = store.nextCalibrationAt
        try Data("changed auth fixture".utf8).write(to: folder.home.appendingPathComponent("auth.json"))
        await store.calibrateQuota()
        XCTAssertNil(store.quota.account)
        XCTAssertNil(store.quota.snapshot)
        XCTAssertEqual(store.nextCalibrationAt, deadline)
        let counts = await fixture.counts()
        XCTAssertEqual(counts.1, 1)
        store.stop()
    }
    func testAuthenticationChangeDuringRequestDiscardsResponseWithOrWithoutLocalPolling() async throws {
        for pollWhilePending in [false, true] {
            let folder = try SQLiteFixture(), fixture = MonitorFixture()
            await fixture.setNetwork(verifiedQuota)
            var now = Date(timeIntervalSince1970: 300)
            let store = MonitorStore(readLocal: { _ in await fixture.read() }, readDsh: { _ in .empty }, fetchQuota: { _ in await fixture.network() },
                                     now: { now }, defaults: defaults(home: folder.home))
            await store.refreshAll()
            await store.calibrateQuota()
            now = now.addingTimeInterval(61)
            await fixture.hold()
            let request = Task { await store.calibrateQuota() }
            await fixture.waitUntilHeld()
            XCTAssertTrue(store.quotaBusy)
            try Data("changed auth fixture".utf8).write(to: folder.home.appendingPathComponent("auth.json"))
            if pollWhilePending { await store.refreshAll() }
            await fixture.release(); await request.value
            XCTAssertNil(store.quota.account)
            XCTAssertNil(store.quota.snapshot)
            XCTAssertEqual(store.quota.error, L10n.text("Your sign-in has changed. Sync quota again."))
            XCTAssertEqual(store.nextCalibrationAt, now.addingTimeInterval(60))
            XCTAssertFalse(store.quotaBusy)
            store.stop()
        }
    }
    func testAutomaticQuotaUsesHourlyIdleAndMinuteActiveCadence() async throws {
        let folder = try SQLiteFixture(), fixture = MonitorFixture(), clock = TestPollingClock(), active = Flag()
        let store = MonitorStore(readLocal: { _ in
            TaskReadResult(tasks: await active.get() ? [Self.codexTask()] : [], fetchedAt: .now, warning: nil)
        }, readDsh: { _ in .empty }, fetchQuota: { _ in await fixture.network() }, clock: clock.clock,
        now: { Date(timeIntervalSince1970: 300 + Double(clock.instant.components.seconds)) }, defaults: defaults(home: folder.home))
        store.start(); await store.refreshAll(); await drain()
        var counts = await fixture.counts(); XCTAssertEqual(counts.1, 1)
        clock.advance(3599); await store.refreshAll(); await drain()
        counts = await fixture.counts(); XCTAssertEqual(counts.1, 1)
        clock.advance(1); await drain()
        counts = await fixture.counts(); XCTAssertEqual(counts.1, 2)
        await active.set(true); await store.refreshAll(); await drain()
        clock.advance(59); await drain()
        counts = await fixture.counts(); XCTAssertEqual(counts.1, 2)
        clock.advance(1); await drain()
        counts = await fixture.counts(); XCTAssertEqual(counts.1, 3)
        await active.set(false); await store.refreshAll(); await drain()
        clock.advance(60); await drain()
        counts = await fixture.counts(); XCTAssertEqual(counts.1, 3)
        store.sleep(); clock.advance(7200); await drain()
        counts = await fixture.counts(); XCTAssertEqual(counts.1, 3)
        store.wake(); await store.refreshAll(); await drain()
        counts = await fixture.counts(); XCTAssertEqual(counts.1, 4)
        store.stop(); clock.finish(); await drain()
    }

    func testActiveTransitionFetchesOverdueQuotaWithoutWaitingForIdleDeadline() async throws {
        let folder = try SQLiteFixture(), fixture = MonitorFixture(), clock = TestPollingClock(), active = Flag()
        let store = MonitorStore(readLocal: { _ in
            TaskReadResult(tasks: await active.get() ? [Self.codexTask()] : [], fetchedAt: .now, warning: nil)
        }, readDsh: { _ in .empty }, fetchQuota: { _ in await fixture.network() }, clock: clock.clock,
        now: { Date(timeIntervalSince1970: 300 + Double(clock.instant.components.seconds)) }, defaults: defaults(home: folder.home))
        store.start(); await store.refreshAll(); await drain()
        clock.advance(120); await drain()
        await active.set(true); await store.refreshAll(); await drain()
        let counts = await fixture.counts(); XCTAssertEqual(counts.1, 2)
        store.stop(); clock.finish(); await drain()
    }

    func testLocalTaskRefreshAndPanelOpeningPreserveOnlineQuota() async throws {
        let folder = try SQLiteFixture(), fixture = MonitorFixture(), clock = TestPollingClock()
        try folder.threads()
        let log = try folder.log("running", used: 99)
        try folder.insert("running", path: log)
        let reader = LocalTaskReader(collectEvidence: { _ in ProcessEvidence(threadIDs: ["running"]) })
        let online = verifiedQuota
        await fixture.setNetwork(online)
        let store = MonitorStore(readLocal: { try await reader.fetch(home: $0) }, readDsh: { _ in .empty },
            fetchQuota: { _ in await fixture.network() }, clock: clock.clock, defaults: defaults(home: folder.home))
        store.start(); await store.refreshAll(); await store.calibrateQuota(); await drain()
        for _ in 0..<3 {
            let update = #"{"type":"event_msg","timestamp":"2026-10-30T06:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":456}},"rate_limits":{"primary":{"used_percent":99,"window_minutes":300}}}}"# + "\n"
            let handle = try FileHandle(forWritingTo: log)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(update.utf8))
            try handle.close()
            store.setPanelVisible(false); store.setPanelVisible(true)
            await store.refreshAll()
            XCTAssertEqual(store.tasks.map(\.id), ["running"])
            XCTAssertEqual(store.tasks.first?.tokens.total, 456)
            XCTAssertEqual(store.quota.snapshot, online.snapshot)
            XCTAssertEqual(store.menuQuotaPercent, 80)
            XCTAssertFalse(store.menuLabel.contains("~"))
        }
        let counts = await fixture.counts(); XCTAssertEqual(counts.1, 1)
        store.stop(); clock.finish(); await drain()
    }

    func testConfigurationChangesDoNotHideQuotaOrDiscardPendingResponse() async throws {
        let folder = try SQLiteFixture(), fixture = MonitorFixture(), clock = TestPollingClock()
        await fixture.setNetwork(verifiedQuota)
        let store = MonitorStore(readLocal: { _ in TaskReadResult(tasks: [Self.codexTask()], fetchedAt: .now, warning: nil) }, readDsh: { _ in .empty },
            fetchQuota: { _ in await fixture.network() }, clock: clock.clock,
            now: { Date(timeIntervalSince1970: 300 + Double(clock.instant.components.seconds)) }, defaults: defaults(home: folder.home))
        await fixture.hold()
        let request = Task { await store.calibrateQuota() }
        await fixture.waitUntilHeld()
        let config = folder.home.appendingPathComponent("config.toml")
        let contents = "model_provider = \"custom\"\nopenai_base_url = \"https://gateway.example.invalid/v1\"\n"
        try Data(contents.utf8).write(to: config)
        await store.refreshAll()
        XCTAssertTrue(store.showsQuota)
        await fixture.release(); await request.value
        XCTAssertEqual(store.menuQuotaPercent, 80)
        XCTAssertFalse(store.quotaBusy)
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), contents)
        store.start(); await store.refreshAll(); await drain()
        clock.advance(59); await drain()
        var counts = await fixture.counts(); XCTAssertEqual(counts.1, 1)
        clock.advance(1); await drain()
        counts = await fixture.counts(); XCTAssertEqual(counts.1, 2)
        XCTAssertEqual(store.menuQuotaPercent, 80)
        store.stop(); clock.finish(); await drain()
    }

    func testAutomaticFailureBackoffAndManualRequestsShareOneRequest() async throws {
        let folder = try SQLiteFixture(), fixture = MonitorFixture(), clock = TestPollingClock()
        await fixture.setNetwork(QuotaRefresh(error: .rateLimited, didRequestQuota: true))
        let store = MonitorStore(readLocal: { _ in
            TaskReadResult(tasks: [Self.codexTask()], fetchedAt: .now, warning: nil)
        }, readDsh: { _ in .empty }, fetchQuota: { _ in await fixture.network() }, clock: clock.clock,
        now: { Date(timeIntervalSince1970: 300 + Double(clock.instant.components.seconds)) }, defaults: defaults(home: folder.home))
        store.start(); await store.refreshAll(); await drain()
        clock.advance(299); await drain(); await store.calibrateQuota()
        var counts = await fixture.counts(); XCTAssertEqual(counts.1, 1)
        await fixture.setNetwork(verifiedQuota)
        clock.advance(1); await drain()
        counts = await fixture.counts(); XCTAssertEqual(counts.1, 2)
        XCTAssertNil(store.quota.error)
        store.stop(); clock.finish(); await drain()
    }

    func testManualRequestsCoalesceAndAuthenticationChangeInvalidatesNetworkResult() async throws {
        let folder = try SQLiteFixture(), fixture = MonitorFixture(), clock = TestPollingClock()
        let now = Date(timeIntervalSince1970: 300)
        let store = MonitorStore(readLocal: { _ in await fixture.read() }, readDsh: { _ in .empty }, fetchQuota: { _ in await fixture.network() },
                                 clock: clock.clock, now: { now }, defaults: defaults(home: folder.home))
        await store.refreshAll()
        await fixture.hold()
        let first = Task { await store.calibrateQuota() }
        let second = Task { await store.calibrateQuota() }
        await drain()
        let pending = await fixture.counts()
        XCTAssertEqual(pending.1, 1)
        await fixture.release(); await first.value; await second.value
        XCTAssertFalse(store.quotaBusy)
        XCTAssertNotNil(store.quota.snapshot)
        await store.calibrateQuota()
        let throttled = await fixture.counts()
        XCTAssertEqual(throttled.1, 1)
        try Data("fixture auth changed".utf8).write(to: folder.home.appendingPathComponent("auth.json"))
        await store.refreshAll()
        XCTAssertNil(store.quota.snapshot)
        XCTAssertNil(store.quota.account)
        store.stop(); clock.finish(); await drain()
    }
    func testAutomaticPathCommitRefreshesTasksAndOnlineQuota() async throws {
        let firstHome = try SQLiteFixture(), secondHome = try SQLiteFixture(), fixture = MonitorFixture(), clock = TestPollingClock()
        let store = MonitorStore(readLocal: { _ in await fixture.read() }, readDsh: { _ in .empty }, fetchQuota: { _ in await fixture.network() },
                                 clock: clock.clock, defaults: defaults(home: firstHome.home))
        await store.refreshAll()
        let before = await fixture.counts()
        let result = await store.commitPath(secondHome.home.path, field: .home)
        XCTAssertEqual(result, .applied)
        await store.refreshAll()
        let after = await fixture.counts()
        XCTAssertGreaterThan(after.0, before.0)
        await drain()
        let finalCounts = await fixture.counts()
        XCTAssertEqual(finalCounts.1, 1)
        XCTAssertNotNil(store.quota.snapshot)
        store.stop(); clock.finish(); await drain()
    }

    func testSavingSettingsClearsCachesAndStartsQuotaForNewLocation() async throws {
        let firstHome = try SQLiteFixture(), secondHome = try SQLiteFixture(), fixture = MonitorFixture(), clock = TestPollingClock()
        let store = MonitorStore(readLocal: { _ in await fixture.read() }, readDsh: { _ in .empty }, fetchQuota: { _ in await fixture.network() },
                                 clock: clock.clock, defaults: defaults(home: firstHome.home))
        await store.calibrateQuota()
        XCTAssertNotNil(store.nextCalibrationAt)
        store.saveSettings(home: secondHome.home.path, executable: "")
        XCTAssertNil(store.nextCalibrationAt)
        XCTAssertNil(store.quota.snapshot)
        await waitUntil("quota refetch for the new location") { await fixture.counts().1 == 2 }
        let counts = await fixture.counts()
        XCTAssertEqual(counts.1, 2)
        XCTAssertNotNil(store.quota.snapshot)
        store.stop(); clock.finish(); await drain()
    }

    func testOnlineQuotaAndCreditsSurviveTaskRefreshAndClearOnSettingsChange() async throws {
        let folder = try SQLiteFixture(), fixture = MonitorFixture()
        var now = Date(timeIntervalSince1970: 300)
        let store = MonitorStore(readLocal: { _ in await fixture.read() }, readDsh: { _ in .empty }, fetchQuota: { _ in await fixture.network() },
                                 now: { now }, defaults: defaults(home: folder.home))
        await store.refreshAll()
        for count: Int64 in [3, 2] {
            let credits = ResetCreditsSnapshot(availableCount: count, credits: [],
                                              fetchedAt: Date(timeIntervalSince1970: 200), hasIncompleteDetails: true)
            var result = verifiedQuota
            result.snapshot?.resetCredits = credits
            await fixture.setNetwork(result)
            await store.calibrateQuota()
            XCTAssertEqual(store.quota.snapshot?.windows, verifiedQuota.snapshot?.windows)
            await store.refreshAll()
            XCTAssertEqual(store.quota.snapshot, result.snapshot)
            XCTAssertEqual(store.quota.resetCredits, credits)
            now = now.addingTimeInterval(61)
        }
        await fixture.setNetwork(QuotaRefresh(error: .timeout))
        await store.calibrateQuota()
        XCTAssertEqual(store.quota.resetCredits?.availableCount, 2)
        XCTAssertEqual(store.quota.error, QuotaFailure.timeout.message)
        store.saveSettings(home: folder.home.path, executable: "/fixture/codex")
        XCTAssertNil(store.quota.resetCredits)
        store.stop()
        await drain()
    }

    private nonisolated static func codexTask(id: String = "cx-1") -> TaskSnapshot {
        TaskSnapshot(id: id, title: "Codex task", model: nil, source: .desktop, parentID: nil,
                     startedAt: nil, updatedAt: .distantPast, tokens: TokenUsage(), activity: .running)
    }
    private nonisolated static func dshTask(id: String = "dsh:s1") -> TaskSnapshot {
        TaskSnapshot(id: id, title: "dsh task", model: nil, source: .desktop, parentID: nil,
                     startedAt: nil, updatedAt: .distantPast, tokens: TokenUsage(), activity: .running, backend: .dsh)
    }
    private nonisolated static func dshRead(_ tasks: [TaskSnapshot], warning: String? = nil) -> DshTaskRead {
        DshTaskRead(tasks: tasks, fetchedAt: .now, warning: warning, parsedFiles: tasks.count, skippedFiles: 0)
    }

    func testMergesBothBackendsIntoTasksAndRunningCount() async throws {
        let folder = try SQLiteFixture(), fixture = MonitorFixture()
        let store = MonitorStore(
            readLocal: { _ in TaskReadResult(tasks: [Self.codexTask()], fetchedAt: .now, warning: nil) },
            readDsh: { _ in Self.dshRead([Self.dshTask()]) },
            fetchQuota: { _ in await fixture.network() }, defaults: dshIsolatedDefaults(home: folder.home))
        await store.refreshAll()
        XCTAssertEqual(Set(store.tasks.map(\.id)), ["cx-1", "dsh:s1"])
        XCTAssertEqual(store.runningTasks.count, 2)
        XCTAssertNil(store.dshWarning)
        store.stop()
    }

    func testDshWarningEmptiesDshTasksButLeavesCodexIntact() async throws {
        let folder = try SQLiteFixture(), fixture = MonitorFixture()
        let broken = Flag()
        let store = MonitorStore(
            readLocal: { _ in TaskReadResult(tasks: [Self.codexTask()], fetchedAt: .now, warning: nil) },
            readDsh: { _ in await broken.get()
                ? Self.dshRead([], warning: "dsh broken")
                : Self.dshRead([Self.dshTask()]) },
            fetchQuota: { _ in await fixture.network() }, defaults: dshIsolatedDefaults(home: folder.home))
        await store.refreshAll()
        XCTAssertEqual(Set(store.tasks.map(\.id)), ["cx-1", "dsh:s1"])
        XCTAssertNil(store.dshWarning)
        // The dsh backend degrades alone: its tasks leave, Codex stays running.
        await broken.set(true)
        await store.refreshAll()
        XCTAssertEqual(store.tasks.map(\.id), ["cx-1"])
        XCTAssertEqual(store.tasks.first?.activity, .running)
        XCTAssertEqual(store.dshWarning, "dsh broken")
        XCTAssertNil(store.taskError)
        // Recovery clears the warning and restores dsh tasks.
        await broken.set(false)
        await store.refreshAll()
        XCTAssertEqual(Set(store.tasks.map(\.id)), ["cx-1", "dsh:s1"])
        XCTAssertNil(store.dshWarning)
        store.stop()
    }

    func testCodexFailureMarksOnlyCodexTasksUncertain() async throws {
        let folder = try SQLiteFixture(), fixture = MonitorFixture()
        let fail = Flag()
        let store = MonitorStore(
            readLocal: { _ in
                if await fail.get() { throw MonitorFailure("fixture") }
                return TaskReadResult(tasks: [Self.codexTask()], fetchedAt: .now, warning: nil)
            },
            readDsh: { _ in Self.dshRead([Self.dshTask()]) },
            fetchQuota: { _ in await fixture.network() }, defaults: dshIsolatedDefaults(home: folder.home))
        await store.refreshAll()
        XCTAssertEqual(store.runningTasks.count, 2)
        await fail.set(true)
        await store.refreshAll()
        XCTAssertEqual(store.tasks.first { $0.id == "cx-1" }?.activity, .unknown)
        XCTAssertEqual(store.tasks.first { $0.id == "dsh:s1" }?.activity, .running)
        XCTAssertNotNil(store.taskError)
        XCTAssertNil(store.dshWarning)
        store.stop()
    }

    func testSaveCodexSettingsPreservesDshState() async throws {
        let folder = try SQLiteFixture(), fixture = MonitorFixture()
        let store = MonitorStore(
            readLocal: { _ in TaskReadResult(tasks: [], fetchedAt: .now, warning: nil) },
            readDsh: { _ in Self.dshRead([Self.dshTask()], warning: "dsh broken") },
            fetchQuota: { _ in await fixture.network() }, defaults: dshIsolatedDefaults(home: folder.home))
        await store.refreshAll()
        XCTAssertEqual(store.tasks.map(\.id), ["dsh:s1"])
        XCTAssertEqual(store.dshWarning, "dsh broken")
        store.saveSettings(home: folder.home.path, executable: "")
        XCTAssertEqual(store.tasks.map(\.id), ["dsh:s1"])
        XCTAssertEqual(store.dshWarning, "dsh broken")
        store.stop()
        await drain()
    }
}

private actor Flag {
    private var value = false
    func get() -> Bool { value }
    func set(_ new: Bool) { value = new }
}


@MainActor
extension MonitorStoreTests {
    func testQuotaRemainsAvailableAcrossDifferentAndInvalidConfigurations() async throws {
        let folder = try SQLiteFixture(), fixture = MonitorFixture()
        await fixture.setNetwork(verifiedQuota)
        var now = Date(timeIntervalSince1970: 300)
        let store = MonitorStore(readLocal: { _ in await fixture.read() }, readDsh: { _ in .empty },
            fetchQuota: { _ in await fixture.network() }, now: { now }, defaults: defaults(home: folder.home))
        await store.calibrateQuota()
        let original = store.quota.snapshot
        let config = folder.home.appendingPathComponent("config.toml")
        for contents in ["model_provider = 'external'", "model_provider = 'openai'\nopenai_base_url = 'https://gateway.example.invalid'", "invalid [config"] {
            try Data(contents.utf8).write(to: config, options: .atomic)
            await store.refreshAll()
            XCTAssertTrue(store.showsQuota)
            XCTAssertEqual(store.quota.snapshot, original)
            XCTAssertEqual(store.menuQuotaPercent, 80)
            now = now.addingTimeInterval(61)
            await store.calibrateQuota()
            XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), contents)
        }
        let counts = await fixture.counts()
        XCTAssertEqual(counts.1, 4)
        store.stop()
    }

    func testConfigurationEditsPreserveServerRetryAfter() async throws {
        let folder = try SQLiteFixture(), fixture = MonitorFixture()
        let config = folder.home.appendingPathComponent("config.toml")
        try Data("model_provider = \"openai\"\n".utf8).write(to: config)
        let error = try JSONValue.decode(Data(#"{"code":-32000,"data":{"status":429,"retryAfterSeconds":7200}}"#.utf8))
        await fixture.setNetwork(QuotaRefresh(error: .rateLimited, failureDetails: QuotaFailureDetails(rpcError: error), didRequestQuota: true))
        let now = Date(timeIntervalSince1970: 300)
        let store = MonitorStore(readLocal: { _ in await fixture.read() }, readDsh: { _ in .empty },
            fetchQuota: { _ in await fixture.network() }, now: { now }, defaults: defaults(home: folder.home))
        await store.calibrateQuota()
        let retryAt = try XCTUnwrap(store.nextCalibrationAt)
        XCTAssertEqual(retryAt, now.addingTimeInterval(7200))
        try Data("model_provider = \"deepseek\"\n".utf8).write(to: config)
        await store.refreshAll()
        try Data("model_provider = \"openai\"\n".utf8).write(to: config)
        await store.refreshAll()
        XCTAssertEqual(store.nextCalibrationAt, retryAt, "Configuration edits must retain account-level retry deadline")
        await fixture.setNetwork(verifiedQuota)
        await store.calibrateQuota()
        let counts = await fixture.counts()
        XCTAssertEqual(counts.1, 1, "Configuration edits must not bypass Retry-After")
        store.stop()
    }

    func testLocalRefreshRemainsIndependentOfPendingQuotaAndCooldown() async throws {
        let folder = try SQLiteFixture(), fixture = MonitorFixture()
        let now = Date(timeIntervalSince1970: 300)
        let store = MonitorStore(readLocal: { _ in await fixture.read() }, readDsh: { _ in .empty },
            fetchQuota: { _ in await fixture.network() }, now: { now }, defaults: defaults(home: folder.home))
        await store.refreshAll()
        await fixture.hold()
        let quota = Task { await store.calibrateQuota() }
        await fixture.waitUntilHeld()
        XCTAssertTrue(store.quotaBusy)
        await store.refreshAll()
        XCTAssertTrue(store.quotaBusy)
        XCTAssertFalse(store.tasksBusy)
        var counts = await fixture.counts()
        XCTAssertEqual(counts.0, 2)
        XCTAssertEqual(counts.1, 1)
        await fixture.release(); await quota.value
        XCTAssertEqual(store.nextCalibrationAt, now.addingTimeInterval(60))
        await store.refreshAll()
        counts = await fixture.counts()
        XCTAssertEqual(counts.0, 3)
        XCTAssertEqual(counts.1, 1)
        store.stop()
    }


    func testConfigurationEditsRetainPendingRetryAfterAndResumeAtDeadline() async throws {
        let folder = try SQLiteFixture(), fixture = MonitorFixture(), clock = TestPollingClock()
        let config = folder.home.appendingPathComponent("config.toml")
        try Data("model_provider = \"openai\"\n".utf8).write(to: config)
        let error = try JSONValue.decode(Data(#"{"code":-32000,"data":{"status":429,"retryAfterSeconds":7200}}"#.utf8))
        await fixture.setNetwork(QuotaRefresh(error: .rateLimited, failureDetails: QuotaFailureDetails(rpcError: error), didRequestQuota: true))
        let store = MonitorStore(readLocal: { _ in
            TaskReadResult(tasks: [Self.codexTask()], fetchedAt: .now, warning: nil)
        }, readDsh: { _ in .empty }, fetchQuota: { _ in await fixture.network() }, clock: clock.clock,
            now: { Date(timeIntervalSince1970: 300 + Double(clock.instant.components.seconds)) }, defaults: defaults(home: folder.home))
        await fixture.hold()
        let first = Task { await store.calibrateQuota() }
        await fixture.waitUntilHeld()
        try Data("model_provider = \"deepseek\"\n".utf8).write(to: config)
        await store.refreshAll()
        try Data("model_provider = \"openai\"\n".utf8).write(to: config)
        await store.refreshAll()
        let rejoined = Task { await store.calibrateQuota() }
        store.start(); await store.refreshAll(); await drain()
        var counts = await fixture.counts()
        XCTAssertEqual(counts.1, 1, "Configuration edits must join the pending account request")
        await fixture.setNetwork(verifiedQuota)
        await fixture.release(); await first.value; await rejoined.value; await drain()
        XCTAssertNil(store.quota.snapshot, "A rate-limited response has no quota data to publish")
        XCTAssertFalse(store.quotaBusy)
        XCTAssertEqual(store.nextCalibrationAt, Date(timeIntervalSince1970: 7500))
        clock.advance(7199); await drain()
        counts = await fixture.counts(); XCTAssertEqual(counts.1, 1)
        clock.advance(1); await drain()
        counts = await fixture.counts(); XCTAssertEqual(counts.1, 2)
        XCTAssertEqual(store.menuQuotaPercent, 80)
        store.stop(); clock.finish(); await drain()
    }


}

@MainActor
extension MonitorStoreTests {
    func testServiceLossAndRecoveryDiscardAnOlderPendingQuotaResponse() async throws {
        let folder = try SQLiteFixture(), fixture = MonitorFixture(), clock = TestPollingClock()
        let executable = folder.home.appendingPathComponent("codex")
        try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        let settings = defaults(home: folder.home)
        settings.set(executable.path, forKey: "codexExecutable")
        await fixture.setNetwork(verifiedQuota)
        let store = MonitorStore(readLocal: { _ in await fixture.read() }, readDsh: { _ in .empty },
            fetchQuota: { _ in await fixture.network() }, clock: clock.clock,
            now: { Date(timeIntervalSince1970: 300 + Double(clock.instant.components.seconds)) }, defaults: settings)
        await fixture.hold()
        let pending = Task { await store.calibrateQuota() }
        await fixture.waitUntilHeld()
        try FileManager.default.removeItem(at: executable)
        await store.refreshAll()
        XCTAssertFalse(store.showsQuota)
        try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        await store.refreshAll()
        XCTAssertTrue(store.showsQuota)
        await fixture.release(); await pending.value
        XCTAssertNil(store.quota.snapshot)
        XCTAssertFalse(store.quotaBusy)
        clock.advance(60)
        await store.calibrateQuota()
        XCTAssertEqual(store.menuQuotaPercent, 80)
        store.stop(); clock.finish(); await drain()
    }

    func testOldDirectoryResponseCannotReplaceNewDirectoryQuota() async throws {
        let oldHome = try SQLiteFixture(), newHome = try SQLiteFixture()
        let old = MonitorFixture(), current = MonitorFixture(), clock = TestPollingClock()
        await old.setNetwork(verifiedQuota)
        var newResult = verifiedQuota
        newResult.snapshot = QuotaSnapshot(windows: [QuotaWindow(id: "codex:primary", bucketID: "codex", bucketName: "Codex",
            isPrimary: true, usedPercent: 60, durationMinutes: 300, resetsAt: nil)], fetchedAt: .now, accountID: "new-account")
        await current.setNetwork(newResult)
        let oldURL = oldHome.home
        let store = MonitorStore(readLocal: { _ in await current.read() }, readDsh: { _ in .empty },
            fetchQuota: { location in await (location.home.path == oldURL.path ? old : current).network() },
            clock: clock.clock, defaults: defaults(home: oldHome.home))
        await old.hold()
        let pending = Task { await store.calibrateQuota() }
        await old.waitUntilHeld()
        store.saveSettings(home: newHome.home.path, executable: "/usr/bin/true")
        await store.calibrateQuota()
        XCTAssertEqual(store.menuQuotaPercent, 40)
        await old.release(); await pending.value
        XCTAssertEqual(store.menuQuotaPercent, 40)
        store.stop(); clock.finish(); await drain()
    }
}

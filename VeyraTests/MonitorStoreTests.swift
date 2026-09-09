import XCTest
import Foundation

private actor MonitorFixture {
    var localReads = 0
    var networkReads = 0
    var local: QuotaSnapshot? = QuotaSnapshot(windows: [], fetchedAt: Date(timeIntervalSince1970: 100), accountID: nil, source: .local)
    var networkResult = QuotaRefresh(snapshot: QuotaSnapshot(windows: [], fetchedAt: Date(timeIntervalSince1970: 200), accountID: "fixture"), didRequestQuota: true)
    var networkGate: CheckedContinuation<Void, Never>?
    var gateWaiters: [CheckedContinuation<Void, Never>] = []
    var holdNetwork = false
    func read() -> TaskReadResult {
        localReads += 1
        return TaskReadResult(tasks: [], fetchedAt: .now, warning: nil, localQuota: local)
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
    func setLocal(_ snapshot: QuotaSnapshot?) { local = snapshot }
    func setNetwork(_ result: QuotaRefresh) { networkResult = result }
    func hold() { holdNetwork = true }
    func waitUntilHeld() async {
        if networkGate == nil { await withCheckedContinuation { gateWaiters.append($0) } }
    }
    func release() { holdNetwork = false; networkGate?.resume(); networkGate = nil }
}

@MainActor
final class MonitorStoreTests: XCTestCase {
    private func drain() async { for _ in 0..<40 { await Task.yield() } }
    private func defaults(home: URL) -> UserDefaults {
        let suite = "veyra-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(home.path, forKey: "codexHome")
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
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
            for hasLocal in [false, true] {
                let folder = try SQLiteFixture(), fixture = MonitorFixture()
                let local = hasLocal ? await fixture.read().localQuota : nil
                await fixture.setLocal(local)
                await fixture.setNetwork(verifiedQuota)
                var now = Date(timeIntervalSince1970: 300)
                let store = MonitorStore(readLocal: { _ in await fixture.read() }, fetchQuota: { _ in await fixture.network() },
                                         now: { now }, defaults: defaults(home: folder.home))
                await store.refreshAll()
                await store.calibrateQuota()
                XCTAssertEqual(store.quota.account?.identity, "account-a")
                try Data("changed auth fixture".utf8).write(to: folder.home.appendingPathComponent("auth.json"), options: .atomic)
                await fixture.setNetwork(QuotaRefresh(error: failure))
                now = now.addingTimeInterval(61)
                await store.calibrateQuota()
                XCTAssertNil(store.quota.account)
                XCTAssertEqual(store.quota.snapshot, local)
                XCTAssertEqual(store.quota.error, failure.message)
                await store.refreshAll()
                XCTAssertNil(store.quota.account)
                XCTAssertEqual(store.quota.snapshot, local)
                let counts = await fixture.counts()
                XCTAssertEqual(counts.1, 2)
                store.stop()
            }
        }
    }
    func testCalibrationFailureKeepsVerifiedQuotaWhenAuthenticationIsUnchanged() async throws {
        let folder = try SQLiteFixture(), fixture = MonitorFixture()
        let verified = verifiedQuota
        await fixture.setNetwork(verified)
        var now = Date(timeIntervalSince1970: 300)
        let store = MonitorStore(fetchQuota: { _ in await fixture.network() }, now: { now }, defaults: defaults(home: folder.home))
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
        let store = MonitorStore(readLocal: { _ in await fixture.read() }, fetchQuota: { _ in await fixture.network() },
                                 now: { now }, defaults: defaults(home: folder.home))
        await store.refreshAll()
        await store.calibrateQuota()
        let deadline = store.nextCalibrationAt
        try Data("changed auth fixture".utf8).write(to: folder.home.appendingPathComponent("auth.json"))
        await store.calibrateQuota()
        XCTAssertNil(store.quota.account)
        XCTAssertEqual(store.quota.snapshot?.source, .local)
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
            let store = MonitorStore(readLocal: { _ in await fixture.read() }, fetchQuota: { _ in await fixture.network() },
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
            XCTAssertEqual(store.quota.snapshot?.source, .local)
            XCTAssertEqual(store.quota.error, L10n.text("Your sign-in has changed. Sync quota again."))
            XCTAssertEqual(store.nextCalibrationAt, now.addingTimeInterval(60))
            XCTAssertFalse(store.quotaBusy)
            store.stop()
        }
    }
    func testStartupVisibilityWakeAndNormalRefreshNeverRequestQuota() async throws {
        let folder = try SQLiteFixture(), fixture = MonitorFixture(), clock = TestPollingClock()
        let store = MonitorStore(readLocal: { _ in await fixture.read() }, fetchQuota: { _ in await fixture.network() },
                                 clock: clock.clock, defaults: defaults(home: folder.home))
        store.start(); await drain()
        await store.refreshAll()
        store.setPanelVisible(true); await drain()
        store.sleep(); clock.advance(100); await drain()
        store.wake(); await drain()
        let counts = await fixture.counts()
        XCTAssertGreaterThanOrEqual(counts.0, 3)
        XCTAssertEqual(counts.1, 0)
        XCTAssertEqual(store.quota.snapshot?.source, .local)
        XCTAssertFalse(store.quotaBusy)
        store.stop(); clock.finish(); await drain()
    }
    func testReopeningPanelKeepsSparkAndPlanAfterNewerLocalCodexRecord() async throws {
        let folder = try SQLiteFixture(), fixture = MonitorFixture(), clock = TestPollingClock()
        let account = AccountSnapshot(json: .object(["type": .string("chatgpt"), "planType": .string("prolite")]),
                                      accountID: "account-a")
        let codex = verifiedQuota.snapshot!.windows[0]
        let spark = QuotaWindow(id: "spark:primary", bucketID: "spark", bucketName: "Spark", isPrimary: true,
                                usedPercent: 0, durationMinutes: 300, resetsAt: nil)
        let network = QuotaSnapshot(windows: [codex, spark], fetchedAt: Date(timeIntervalSince1970: 200), accountID: "account-a")
        await fixture.setNetwork(QuotaRefresh(account: account, snapshot: network, didRequestQuota: true))
        let store = MonitorStore(readLocal: { _ in await fixture.read() }, fetchQuota: { _ in await fixture.network() },
                                 clock: clock.clock, defaults: defaults(home: folder.home))
        store.start()
        await store.refreshAll()
        store.setPanelVisible(true)
        await store.refreshAll()
        await store.calibrateQuota()
        XCTAssertEqual(store.quota.snapshot, network)

        let updated = QuotaWindow(id: codex.id, bucketID: "codex", bucketName: "Codex", isPrimary: true,
                                  usedPercent: 89, durationMinutes: 300, resetsAt: nil)
        let local = QuotaSnapshot(windows: [updated], fetchedAt: Date(timeIntervalSince1970: 210), accountID: nil, source: .local)
        await fixture.setLocal(local)
        for _ in 0..<3 {
            store.setPanelVisible(false)
            store.setPanelVisible(true)
            // Join the local read scheduled by reopening the menu.
            await store.refreshAll()
            XCTAssertEqual(store.quota.snapshot?.windows, [updated, spark])
            XCTAssertEqual(store.quota.account?.plan, "prolite")
            XCTAssertEqual(store.quota.snapshot?.source(for: "spark"), .network)
            XCTAssertEqual(store.quota.snapshot?.recordedAt(for: "spark"), network.fetchedAt)
            XCTAssertEqual(store.quota.snapshot?.source(for: "codex"), .local)
            XCTAssertTrue(store.menuLabel.contains("11%"))
            XCTAssertTrue(store.menuLabel.contains("~"))
        }
        let counts = await fixture.counts()
        XCTAssertEqual(counts.1, 1)
        try Data("changed auth fixture".utf8).write(to: folder.home.appendingPathComponent("auth.json"))
        await store.refreshAll()
        XCTAssertEqual(store.quota.snapshot, local)
        XCTAssertNil(store.quota.account)
        store.stop(); clock.finish(); await drain()
    }
    func testManualRequestsCoalesceAndAuthenticationChangeInvalidatesNetworkResult() async throws {
        let folder = try SQLiteFixture(), fixture = MonitorFixture(), clock = TestPollingClock()
        let now = Date(timeIntervalSince1970: 300)
        let store = MonitorStore(readLocal: { _ in await fixture.read() }, fetchQuota: { _ in await fixture.network() },
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
        XCTAssertEqual(store.quota.snapshot?.source, .network)
        await store.calibrateQuota()
        let throttled = await fixture.counts()
        XCTAssertEqual(throttled.1, 1)
        try Data("fixture auth changed".utf8).write(to: folder.home.appendingPathComponent("auth.json"))
        await store.refreshAll()
        XCTAssertEqual(store.quota.snapshot?.source, .local)
        XCTAssertNil(store.quota.account)
        store.stop(); clock.finish(); await drain()
    }
    func testSavingSettingsClearsCachesWithoutNetworkRequest() async throws {
        let firstHome = try SQLiteFixture(), secondHome = try SQLiteFixture(), fixture = MonitorFixture(), clock = TestPollingClock()
        let store = MonitorStore(readLocal: { _ in await fixture.read() }, fetchQuota: { _ in await fixture.network() },
                                 clock: clock.clock, defaults: defaults(home: firstHome.home))
        await store.calibrateQuota()
        XCTAssertNotNil(store.nextCalibrationAt)
        store.saveSettings(home: secondHome.home.path, executable: "")
        XCTAssertNil(store.nextCalibrationAt)
        XCTAssertNil(store.quota.snapshot)
        await drain()
        let counts = await fixture.counts()
        XCTAssertEqual(counts.1, 1)
        XCTAssertEqual(store.quota.snapshot?.source, .local)
        store.stop(); clock.finish(); await drain()
    }

    func testCreditsPublishIndependentlyOfNewerLocalQuotaAndClearOnSettingsChange() async throws {
        let folder = try SQLiteFixture(), fixture = MonitorFixture()
        var now = Date(timeIntervalSince1970: 300)
        let local = QuotaSnapshot(windows: [QuotaWindow(id: "codex:primary", bucketID: "codex", bucketName: "Codex",
            isPrimary: true, usedPercent: 89, durationMinutes: 300, resetsAt: nil)],
            fetchedAt: Date(timeIntervalSince1970: 1_000), accountID: nil, source: .local)
        await fixture.setLocal(local)
        let store = MonitorStore(readLocal: { _ in await fixture.read() }, fetchQuota: { _ in await fixture.network() },
                                 now: { now }, defaults: defaults(home: folder.home))
        await store.refreshAll()
        for count: Int64 in [3, 2] {
            let credits = ResetCreditsSnapshot(availableCount: count, credits: [],
                                              fetchedAt: Date(timeIntervalSince1970: 200), hasIncompleteDetails: true)
            var result = verifiedQuota
            result.snapshot?.resetCredits = credits
            await fixture.setNetwork(result)
            await store.calibrateQuota()
            XCTAssertEqual(store.quota.snapshot?.windows, local.windows)
            XCTAssertEqual(store.quota.snapshot?.source(for: "codex"), .local)
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
}

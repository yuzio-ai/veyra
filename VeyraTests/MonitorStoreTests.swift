import XCTest
import Foundation

private actor MonitorFixture {
    var localReads = 0
    var networkReads = 0
    var local = QuotaSnapshot(windows: [], fetchedAt: Date(timeIntervalSince1970: 100), accountID: nil, source: .local)
    var networkGate: CheckedContinuation<Void, Never>?
    var holdNetwork = false
    func read() -> TaskReadResult {
        localReads += 1
        return TaskReadResult(tasks: [], fetchedAt: .now, warning: nil, localQuota: local)
    }
    func network() async -> QuotaRefresh {
        networkReads += 1
        if holdNetwork { await withCheckedContinuation { networkGate = $0 } }
        return QuotaRefresh(snapshot: QuotaSnapshot(windows: [], fetchedAt: Date(timeIntervalSince1970: 200), accountID: "fixture"), didRequestQuota: true)
    }
    func counts() -> (Int, Int) { (localReads, networkReads) }
    func hold() { holdNetwork = true }
    func release() { networkGate?.resume(); networkGate = nil }
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
}

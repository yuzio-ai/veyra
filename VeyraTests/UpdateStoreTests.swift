import Foundation
import XCTest

private actor UpdateFixture {
    var calls = 0
    var failure: UpdateFailure?
    var hold = false
    var continuation: CheckedContinuation<Void, Never>?
    var waiting: [CheckedContinuation<Void, Never>] = []

    func fetch() async throws -> AppRelease {
        calls += 1
        if hold {
            await withCheckedContinuation {
                continuation = $0
                waiting.forEach { $0.resume() }
                waiting = []
            }
        }
        if let failure { throw failure }
        return try AppRelease(version: "1.2.0", pageURL: URL(string: "https://github.com/yuzio-ai/veyra/releases/tag/v1.2.0")!)
    }
    func count() -> Int { calls }
    func fail(_ value: UpdateFailure?) { failure = value }
    func pause() { hold = true }
    func waitUntilHeld() async {
        if continuation == nil { await withCheckedContinuation { waiting.append($0) } }
    }
    func release() { hold = false; continuation?.resume(); continuation = nil }
}

@MainActor
private final class UpdateTestClock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
}

@MainActor
final class UpdateStoreTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let suite = "veyra-updates-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func store(_ fixture: UpdateFixture, _ clock: UpdateTestClock, defaults: UserDefaults? = nil,
                       version: String = "1.1.0", enabled: Bool = true) -> UpdateStore {
        UpdateStore(currentVersion: version, defaults: defaults, networkEnabled: enabled,
                    now: { clock.date }, fetch: { try await fixture.fetch() })
    }

    func testSettingsStatusIsLocalizedAndHidesFailureDetails() {
        for language in ["en", "zh-Hans"] {
            L10n.$languageOverride.withValue(language) {
                let chinese = language == "zh-Hans"
                XCTAssertEqual(UpdateStore.preview(.idle).settingsStatus, chinese ? "当前版本 1.1.0" : "Current version 1.1.0")
                XCTAssertEqual(UpdateStore.preview(.current).settingsStatus, chinese
                    ? "当前版本 1.1.0 · 已是最新版本" : "Current version 1.1.0 · You’re up to date")
                XCTAssertEqual(UpdateStore.preview(.checking).settingsStatus, chinese ? "正在检查更新…" : "Checking for updates…")
                for state: UpdateStore.PreviewState in [.failed, .limited, .availableFailed] {
                    let store = UpdateStore.preview(state)
                    XCTAssertEqual(store.settingsStatus, chinese ? "当前版本 1.1.0 · 暂时无法检查更新"
                        : "Current version 1.1.0 · Unable to check for updates right now")
                    XCTAssertFalse(store.settingsStatus.contains("GitHub"))
                    if state == .availableFailed { XCTAssertEqual(store.availableRelease?.version, "1.2.0") }
                }
            }
        }
    }

    func testAutomaticChecksAreThrottledAcrossFailuresAndRelaunches() async {
        let fixture = UpdateFixture(), clock = UpdateTestClock(), defaults = defaults()
        let store = store(fixture, clock, defaults: defaults)
        await store.checkAutomatically()
        XCTAssertEqual(store.availableRelease?.version, "1.2.0")
        clock.advance(86_399)
        await store.checkAutomatically()
        let restarted = self.store(fixture, clock, defaults: defaults)
        await restarted.checkAutomatically()
        var count = await fixture.count()
        XCTAssertEqual(count, 1)
        clock.advance(1)
        await fixture.fail(.network)
        await restarted.checkAutomatically()
        XCTAssertEqual(restarted.result, .available)
        XCTAssertNotNil(restarted.availableRelease)
        await restarted.checkAutomatically()
        count = await fixture.count()
        XCTAssertEqual(count, 2)
        clock.advance(86_400)
        await restarted.checkAutomatically()
        count = await fixture.count()
        XCTAssertEqual(count, 3)
    }

    func testManualChecksBypassDailyIntervalButRespectCooldown() async {
        let fixture = UpdateFixture(), clock = UpdateTestClock(), store = store(fixture, clock)
        await store.checkAutomatically()
        await store.checkManually()
        var count = await fixture.count()
        XCTAssertEqual(count, 1)
        clock.advance(60)
        await fixture.fail(.network)
        await store.checkManually()
        XCTAssertEqual(store.result, .failed(.network))
        XCTAssertNotNil(store.availableRelease)
        count = await fixture.count()
        XCTAssertEqual(count, 2)
        clock.advance(60)
        await fixture.fail(nil)
        await store.checkManually()
        XCTAssertEqual(store.result, .available)
    }

    func testTogglePersistsAndReenablingChecksWhenDue() async {
        let fixture = UpdateFixture(), clock = UpdateTestClock(), defaults = defaults()
        let store = store(fixture, clock, defaults: defaults)
        XCTAssertTrue(store.automaticallyChecks)
        store.setAutomaticallyChecks(false)
        await store.checkAutomatically()
        var count = await fixture.count()
        XCTAssertEqual(count, 0)
        let restarted = self.store(fixture, clock, defaults: defaults)
        XCTAssertFalse(restarted.automaticallyChecks)
        await restarted.checkManually()
        XCTAssertNotNil(restarted.availableRelease)
        clock.advance(86_400)
        await fixture.pause()
        restarted.setAutomaticallyChecks(true)
        await fixture.waitUntilHeld()
        XCTAssertTrue(restarted.isChecking)
        await fixture.release()
        while restarted.isChecking { await Task.yield() }
        count = await fixture.count()
        XCTAssertEqual(count, 2)
        restarted.setAutomaticallyChecks(false)
        XCTAssertNotNil(restarted.availableRelease)
    }

    func testConcurrentRequestsAreDeduplicated() async {
        let fixture = UpdateFixture(), clock = UpdateTestClock(), store = store(fixture, clock)
        await fixture.pause()
        let request = Task { await store.checkAutomatically() }
        await fixture.waitUntilHeld()
        await store.checkManually()
        await store.checkAutomatically()
        let count = await fixture.count()
        XCTAssertEqual(count, 1)
        await fixture.release()
        await request.value
        XCTAssertFalse(store.isChecking)
    }

    func testRateLimitSurvivesRestartAndBlocksBothModes() async {
        let fixture = UpdateFixture(), clock = UpdateTestClock(), defaults = defaults()
        let until = clock.date.addingTimeInterval(90_000)
        await fixture.fail(.rateLimited(until: until))
        let store = store(fixture, clock, defaults: defaults)
        await store.checkManually()
        XCTAssertEqual(store.nextManualCheckAt, until)
        XCTAssertEqual(store.result, .failed(.rateLimited(until: until)))
        clock.advance(86_400)
        let restarted = self.store(fixture, clock, defaults: defaults)
        await restarted.checkAutomatically()
        await restarted.checkManually()
        var count = await fixture.count()
        XCTAssertEqual(count, 1)
        clock.advance(3_600)
        await fixture.fail(nil)
        await restarted.checkAutomatically()
        count = await fixture.count()
        XCTAssertEqual(count, 2)
        XCTAssertEqual(restarted.result, .available)
    }

    func testCachedReleaseIsComparedToInstalledVersionAndCorruptCacheIgnored() async {
        let fixture = UpdateFixture(), clock = UpdateTestClock(), defaults = defaults()
        let store = store(fixture, clock, defaults: defaults)
        await store.checkManually()
        for version in ["1.2.0", "1.3.0"] {
            let updated = self.store(fixture, clock, defaults: defaults, version: version)
            XCTAssertNil(updated.availableRelease)
            XCTAssertEqual(updated.result, .upToDate)
        }
        let invalid = self.store(fixture, clock, defaults: defaults, version: "unknown")
        XCTAssertEqual(invalid.result, .failed(.invalidData))
        defaults.set(Data("invalid".utf8), forKey: "updates.release")
        let corrupt = self.store(fixture, clock, defaults: defaults)
        XCTAssertNil(corrupt.availableRelease)
        XCTAssertEqual(corrupt.result, .notChecked)
    }

    func testCurrentOrOlderReleaseDoesNotPromptAndSuccessClearsFailure() async {
        let fixture = UpdateFixture(), clock = UpdateTestClock()
        for version in ["1.2.0", "1.3.0"] {
            let store = store(fixture, clock, version: version)
            await fixture.fail(.noRelease)
            await store.checkManually()
            XCTAssertEqual(store.result, .failed(.noRelease))
            clock.advance(60)
            await fixture.fail(nil)
            await store.checkManually()
            XCTAssertEqual(store.result, .upToDate)
            XCTAssertNil(store.availableRelease)
        }
    }

    func testDisabledInstancesAndInvalidVersionsDoNotRequestNetwork() async {
        let fixture = UpdateFixture(), clock = UpdateTestClock()
        let disabled = store(fixture, clock, enabled: false)
        await disabled.checkAutomatically()
        await disabled.checkManually()
        let invalid = store(fixture, clock, version: "dev")
        await invalid.checkManually()
        XCTAssertEqual(invalid.result, .failed(.invalidData))
        let count = await fixture.count()
        XCTAssertEqual(count, 0)
        for state in UpdateStore.PreviewState.allCases {
            let preview = UpdateStore.preview(state)
            let result = preview.result
            await preview.checkAutomatically()
            await preview.checkManually()
            XCTAssertEqual(preview.result, result)
        }
    }

    func testTimeoutIsShownOnlyForManualChecks() async {
        let clock = UpdateTestClock()
        let store = UpdateStore(currentVersion: "1.1.0", networkEnabled: true, now: { clock.date },
                                fetch: { throw URLError(.timedOut) })
        await store.checkAutomatically()
        XCTAssertEqual(store.result, .notChecked)
        clock.advance(60)
        await store.checkManually()
        XCTAssertEqual(store.result, .failed(.network))
        XCTAssertFalse(store.isChecking)
    }
}

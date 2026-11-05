import Foundation
import XCTest

@MainActor
final class CodexOnlyMonitoringTests: XCTestCase {
    private func defaults(home: URL) -> UserDefaults {
        let suite = "veyra-codex-only-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(home.path, forKey: "codexHome")
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return defaults
    }

    private nonisolated static var task: TaskSnapshot {
        TaskSnapshot(id: "fixture", title: "Task", model: "another-provider-model", source: .cli,
                     parentID: nil, startedAt: .distantPast, updatedAt: .distantPast,
                     tokens: TokenUsage(), activity: .running)
    }

    func testTaskAndQuotaCapabilitiesRemainIndependent() async throws {
        let folder = try SQLiteFixture()
        for services in [false, true] {
            for missingData in [false, true] {
                let store = MonitorStore(readLocal: { _ in
                    if missingData { throw LocalTaskReadFailure.databaseMissing }
                    return TaskReadResult(tasks: [Self.task], fetchedAt: .now, warning: nil)
                }, fetchQuota: { _ in QuotaRefresh(error: .notLoggedIn) },
                    defaults: defaults(home: folder.home), inspectServices: { _ in services },
                    resolveLocation: { [home = folder.home] _, _ in CodexLocation(home: home, executable: nil) })
                XCTAssertEqual(store.menuTaskCount, "—")
                await store.refreshAll()
                XCTAssertEqual(store.showsQuota, services)
                XCTAssertEqual(store.menuTaskCount, missingData ? "0" : "1")
                XCTAssertEqual(store.noSourcesFound, missingData && !services)
                XCTAssertEqual(store.codexHasNoTaskData, missingData && services)
                XCTAssertTrue(store.sourceDetectionFinished)
                XCTAssertFalse(store.hasSourceWarning)
                if !missingData {
                    XCTAssertEqual(store.tasks.first?.model, "another-provider-model")
                }
                store.stop()
            }
        }
    }

    func testRetiredDshPreferenceIsIgnoredAndPreserved() async throws {
        let folder = try SQLiteFixture(), defaults = defaults(home: folder.home)
        let oldPath = "/unreadable/retired-source-fixture"
        defaults.set(oldPath, forKey: "dshHome")
        let store = MonitorStore(readLocal: { [expectedHome = folder.home] home in
            XCTAssertEqual(home, expectedHome)
            return TaskReadResult(tasks: [Self.task], fetchedAt: .now, warning: nil)
        }, fetchQuota: { _ in QuotaRefresh(error: .notLoggedIn) }, defaults: defaults,
            inspectServices: { _ in false },
            resolveLocation: { [home = folder.home] _, _ in CodexLocation(home: home, executable: nil) })
        await store.refreshAll()
        XCTAssertEqual(store.runningTasks.map(\.id), ["fixture"])
        XCTAssertFalse(store.hasSourceWarning)
        XCTAssertEqual(defaults.string(forKey: "dshHome"), oldPath)
        store.saveSettings(home: folder.home.path, executable: "")
        store.stop()
        XCTAssertEqual(defaults.string(forKey: "dshHome"), oldPath)
    }

    func testChangingCodexPathsClearsTasksAncestorsAndReadTime() async throws {
        let folder = try SQLiteFixture()
        let store = MonitorStore(readLocal: { _ in
            TaskReadResult(tasks: [Self.task], fetchedAt: .now, warning: nil,
                           ancestors: [TaskReference(id: "ancestor", title: "Parent", parentID: nil)])
        }, fetchQuota: { _ in QuotaRefresh(error: .notLoggedIn) },
            defaults: defaults(home: folder.home), inspectServices: { _ in false },
            resolveLocation: { home, _ in CodexLocation(home: URL(fileURLWithPath: home), executable: nil) })
        await store.refreshAll()
        XCTAssertEqual(store.taskAncestors.count, 1)
        XCTAssertNotNil(store.tasksUpdatedAt)
        store.saveSettings(home: folder.home.appendingPathComponent("other").path, executable: "")
        store.stop()
        XCTAssertTrue(store.tasks.isEmpty)
        XCTAssertTrue(store.taskAncestors.isEmpty)
        XCTAssertNil(store.tasksUpdatedAt)
        XCTAssertFalse(store.hasTaskSnapshot)
        XCTAssertEqual(store.menuTaskCount, "—")
        XCTAssertFalse(store.sourceDetectionFinished)
    }

    func testCodexPathChangeDrainingReadDoesNotRestartMonitoringDuringSleep() async throws {
        let first = try SQLiteFixture(), second = try SQLiteFixture()
        let probe = CodexPathReadProbe(), clock = TestPollingClock()
        let store = MonitorStore(readLocal: { home in
            await probe.read(home: home)
            return TaskReadResult(tasks: [], fetchedAt: .now, warning: nil)
        }, clock: clock.clock, defaults: defaults(home: first.home), inspectServices: { _ in false },
            resolveLocation: { home, _ in CodexLocation(home: URL(fileURLWithPath: home), executable: nil) })
        defer { store.stop(); clock.finish() }

        store.start()
        let deadline = Date().addingTimeInterval(3)
        while !(await probe.isHeld), Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard await probe.isHeld else {
            XCTFail("The first Codex read did not reach its gate")
            await probe.release()
            return
        }

        store.saveSettings(home: second.home.path, executable: "")
        store.sleep()
        await probe.release()
        await drain()
        clock.advance(3600)
        await drain()
        let asleepHomes = await probe.homes
        XCTAssertEqual(asleepHomes.map(\.path), [first.home.path], "A delayed path restart must not undo sleep suspension")
        XCTAssertFalse(store.hasTaskSnapshot, "The superseded read must not publish an old snapshot")

        store.wake()
        await store.refreshAll()
        let awakeHomes = await probe.homes
        XCTAssertEqual(awakeHomes.map(\.path), [first.home.path, second.home.path])
        XCTAssertTrue(store.hasTaskSnapshot)
    }

    private func drain() async {
        for _ in 0..<20 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}

private actor CodexPathReadProbe {
    private(set) var homes: [URL] = []
    private var firstReadGate: CheckedContinuation<Void, Never>?
    var isHeld: Bool { firstReadGate != nil }

    func read(home: URL) async {
        homes.append(home)
        if homes.count == 1 {
            await withCheckedContinuation { firstReadGate = $0 }
        }
    }

    func release() {
        firstReadGate?.resume()
        firstReadGate = nil
    }
}

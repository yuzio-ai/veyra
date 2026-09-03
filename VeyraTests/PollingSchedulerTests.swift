import XCTest
import Foundation

@MainActor
final class TestPollingClock {
    private(set) var instant: Duration = .zero
    private var sleepers: [(Duration, CheckedContinuation<Void, Never>)] = []
    var clock: PollingClock {
        PollingClock(now: { self.instant }, sleep: { delay in
            await withCheckedContinuation { self.sleepers.append((self.instant + delay, $0)) }
        })
    }
    func advance(_ seconds: Int) {
        instant += .seconds(seconds)
        let ready = sleepers.filter { $0.0 <= instant }
        sleepers.removeAll { $0.0 <= instant }
        ready.forEach { $0.1.resume() }
    }
    func finish() { sleepers.forEach { $0.1.resume() }; sleepers = [] }
}

@MainActor
final class PollingSchedulerTests: XCTestCase {
    private func drain() async { for _ in 0..<20 { await Task.yield() } }
    func testIdleActiveOpeningAndSleepWakeSchedules() async {
        let clock = TestPollingClock()
        var reads = 0
        let scheduler = PollingScheduler(clock: clock.clock) { reads += 1 }
        scheduler.start(); await drain()
        XCTAssertEqual(reads, 1)
        clock.advance(29); await drain(); XCTAssertEqual(reads, 1)
        clock.advance(1); await drain(); XCTAssertEqual(reads, 2)
        scheduler.update(panelVisible: true, hasRunningTasks: false)
        await drain(); XCTAssertEqual(reads, 3)
        clock.advance(5); await drain(); XCTAssertEqual(reads, 4)
        scheduler.update(panelVisible: false, hasRunningTasks: true)
        clock.advance(5); await drain(); XCTAssertEqual(reads, 5)
        scheduler.stop()
        clock.advance(1000); await drain(); XCTAssertEqual(reads, 5)
        scheduler.start(); await drain(); XCTAssertEqual(reads, 6)
        scheduler.stop(); clock.finish(); await drain()
    }
    func testConcurrentTriggersJoinAndSlowReadDoesNotCatchUp() async {
        let clock = TestPollingClock()
        var reads = 0
        var complete: CheckedContinuation<Void, Never>?
        let scheduler = PollingScheduler(clock: clock.clock) {
            reads += 1
            await withCheckedContinuation { complete = $0 }
        }
        scheduler.start(); await drain()
        let first = Task { await scheduler.refreshNow() }
        let second = Task { await scheduler.refreshNow() }
        scheduler.update(panelVisible: true, hasRunningTasks: false)
        clock.advance(100); await drain()
        XCTAssertEqual(reads, 1)
        complete?.resume(); await first.value; await second.value; await drain()
        XCTAssertEqual(reads, 1)
        clock.advance(1); await drain(); XCTAssertEqual(reads, 2)
        scheduler.stop(); complete?.resume(); clock.finish(); await drain()
    }
    func testReturningToIdleReplacesFastWait() async {
        let clock = TestPollingClock()
        var reads = 0
        let scheduler = PollingScheduler(clock: clock.clock) { reads += 1 }
        scheduler.update(panelVisible: false, hasRunningTasks: true)
        scheduler.start(); await drain()
        scheduler.update(panelVisible: false, hasRunningTasks: false)
        await drain()
        clock.advance(5); await drain(); XCTAssertEqual(reads, 1)
        clock.advance(25); await drain(); XCTAssertEqual(reads, 2)
        scheduler.stop(); clock.finish(); await drain()
    }
}

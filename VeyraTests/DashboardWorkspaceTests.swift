import Foundation
import XCTest

final class DashboardWorkspaceTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-28T09:00:00Z")!
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return value
    }
    private var interval: DateInterval { calendar.dateInterval(of: .day, for: now)! }
    private func turn(_ id: String, result: ExecutionResult = .completed, age: TimeInterval = 60, tokens: Int64? = 10) -> HistoryTurn {
        let end = now.addingTimeInterval(-age)
        return HistoryTurn(id: id, startedAt: end.addingTimeInterval(-30), endedAt: result == .running ? nil : end,
                           observedAt: end, result: result, samples: [HistoryTokenSample(id: id, date: end, tokens: HistoryTokens(TokenUsage(total: tokens)))])
    }
    private func task(_ id: String, parent: String? = nil, turns: [HistoryTurn]) -> HistoryTask {
        HistoryTask(id: id, title: id, project: "/fixture/project", source: "desktop", parentID: parent, turns: turns)
    }
    private func snapshot(_ tasks: [HistoryTask]) -> HistorySnapshot { HistorySnapshot(tasks: tasks, updatedAt: now) }
    private func liveTask(_ id: String, parent: String? = nil, activity: TaskActivity = .running, backend: TaskBackend = .codex) -> TaskSnapshot {
        TaskSnapshot(id: id, title: id, model: nil, source: .desktop, parentID: parent, startedAt: now.addingTimeInterval(-20),
                     updatedAt: now, tokens: TokenUsage(), activity: activity, backend: backend)
    }
    func testChildOnlyActivityPreservesRootAndDeduplicatesFamilies() {
        let tree = DashboardFamilyTree(tasks: [task("root", turns: []), task("child", parent: "root", turns: [turn("a")]),
                                               task("child2", parent: "root", turns: [turn("b")])])
        let values = tree.families(interval: interval, filter: DashboardFilter(), now: now)
        XCTAssertEqual(values.map(\.id), ["root"])
        XCTAssertEqual(values[0].usage.tokens, 20)
        XCTAssertEqual(values[0].childCount, 2)
        let matched = tree.families(interval: interval, filter: DashboardFilter(search: "child2"), now: now)
        XCTAssertEqual(matched[0].title, "root"); XCTAssertEqual(matched[0].usage.tokens, 10)
    }
    func testMissingAncestorAndCyclesRetainEveryMemberOnce() {
        let missing = DashboardFamilyTree(tasks: [task("child", parent: "missing", turns: [turn("one")])])
        XCTAssertEqual(missing.rootByID["child"], "missing")
        XCTAssertNotNil(missing.tasks["missing"])
        let cycle = DashboardFamilyTree(tasks: [task("a", parent: "b", turns: [turn("one")]), task("b", parent: "a", turns: [turn("two")])])
        XCTAssertEqual(cycle.rootByID["a"], "a"); XCTAssertEqual(cycle.rootByID["b"], "a")
        let families = cycle.families(interval: interval, filter: DashboardFilter(), now: now)
        XCTAssertEqual(families.count, 1); XCTAssertEqual(families[0].turnCount, 2); XCTAssertEqual(families[0].usage.tokens, 20)
    }
    func testPartialUsageKeepsKnownSamplesAndEndedDuration() {
        var incomplete = turn("partial", result: .running, tokens: nil)
        incomplete.hasTokenGap = true
        incomplete.samples.append(HistoryTokenSample(id: "known", date: now, tokens: HistoryTokens(TokenUsage(total: 7))))
        let tree = DashboardFamilyTree(tasks: [task("root", turns: [turn("finished"), incomplete])])
        let usage = tree.families(interval: interval, filter: DashboardFilter(), now: now)[0].usage
        XCTAssertEqual(usage.tokens, 17); XCTAssertEqual(usage.endedDuration, 30)
        XCTAssertEqual(usage.missingTokens, 1); XCTAssertEqual(usage.openTurns, 1)
        XCTAssertEqual(usage.missingDuration, 1)
    }
    func testUnknownAndZeroAreDifferentAndOverflowNeverWraps() {
        let unknown = DashboardFamilyTree(tasks: [task("root", turns: [turn("x", tokens: nil)])])
        XCTAssertNil(unknown.families(interval: interval, filter: DashboardFilter(), now: now)[0].usage.tokens)
        XCTAssertEqual(DashboardUsage.summarize([], in: interval).tokens, 0)
        XCTAssertNil(DashboardUsage.summarize([], in: interval, reliableEmpty: false).tokens)
        let overflow = DashboardFamilyTree(tasks: [task("root", turns: [turn("one", tokens: Int64.max), turn("two")])])
        XCTAssertNil(overflow.families(interval: interval, filter: DashboardFilter(), now: now)[0].usage.tokens)
    }
    func testRunningUsesFreshReliableCodexEvidenceAndRootIDs() {
        let data = snapshot([task("root", turns: [])])
        var live = DashboardLiveSnapshot(tasks: [liveTask("child", parent: "root"), liveTask("other", backend: .dsh)], updatedAt: now, reliable: true)
        let global = DashboardGlobalState.make(snapshot: data, live: live, now: now, calendar: calendar)
        XCTAssertEqual(global.runningCount, 1); XCTAssertEqual(global.runningIDs, ["root"])
        live.updatedAt = now.addingTimeInterval(-61)
        XCTAssertNil(DashboardGlobalState.make(snapshot: data, live: live, now: now, calendar: calendar).runningCount)
        live.updatedAt = now; live.reliable = false
        XCTAssertNil(DashboardGlobalState.make(snapshot: data, live: live, now: now, calendar: calendar).runningCount)
    }
    func testAttentionUsesLatestRecordAndTwentyFourHourWindow() {
        var archived = task("archived", turns: [turn("fail", result: .failed)]); archived.archived = true
        let data = snapshot([
            task("recovered", turns: [turn("old", result: .failed, age: 120), turn("new")]),
            task("failed", turns: [turn("fail", result: .failed)]),
            task("interrupted", turns: [turn("abort", result: .interrupted)]),
            task("stale", turns: [turn("open", result: .running, age: 86_401)]),
            task("open", turns: [turn("open", result: .running)]), archived])
        let state = DashboardGlobalState.make(snapshot: data, live: DashboardLiveSnapshot(), now: now, calendar: calendar)
        XCTAssertEqual(Set(state.attention.map(\.id)), ["failed", "interrupted", "open"])
        XCTAssertEqual(state.attention.last?.id, "open")
    }
    func testLiveTurnSupersedesHistoricalFailureAndEndedTurnSupersedesStaleLive() {
        let data = snapshot([task("root", turns: [turn("failed", result: .failed)])])
        let live = DashboardLiveSnapshot(tasks: [liveTask("root")], updatedAt: now, reliable: true)
        XCTAssertTrue(DashboardGlobalState.make(snapshot: data, live: live, now: now, calendar: calendar).attention.isEmpty)
        var stale = liveTask("root", activity: .unknown)
        let complete = snapshot([task("root", turns: [turn("complete", age: 0)])])
        stale.activity = .unknown
        XCTAssertTrue(DashboardGlobalState.make(snapshot: complete,
            live: DashboardLiveSnapshot(tasks: [stale], updatedAt: now, reliable: true), now: now, calendar: calendar).attention.isEmpty)
    }
    func testAttentionCombinesChildReasonsAndTargetsFailedChild() {
        let data = snapshot([task("root", turns: []), task("child", parent: "root", turns: [turn("failed", result: .failed)]),
                             task("child2", parent: "root", turns: [turn("open", result: .running, age: 10)])])
        let state = DashboardGlobalState.make(snapshot: data, live: DashboardLiveSnapshot(), now: now, calendar: calendar)
        XCTAssertEqual(state.attention.count, 1); XCTAssertEqual(state.attention[0].id, "root")
        XCTAssertEqual(state.attention[0].taskID, "child"); XCTAssertEqual(state.attention[0].turnID, "failed")
        XCTAssertEqual(Set(state.attention[0].reasons), [.failed, .uncertain])
    }
    func testWeeklyCountsAreUniqueRootsRatherThanSumOfDays() {
        let tree = DashboardFamilyTree(tasks: [task("root", turns: [turn("today"), turn("yesterday", age: 86_400)])])
        let data = snapshot(Array(tree.tasks.values))
        let range = DashboardPeriod.week.interval(containing: now, calendar: calendar)
        let daily = DashboardAnalytics.make(snapshot: data, tree: tree, interval: range, filter: DashboardFilter(), weekly: false, now: now, calendar: calendar)
        let weekly = DashboardAnalytics.make(snapshot: data, tree: tree, interval: range, filter: DashboardFilter(), weekly: true, now: now, calendar: calendar)
        XCTAssertEqual(daily.taskCount, 1); XCTAssertEqual(daily.buckets.map(\.tasks).reduce(0, +), 2)
        XCTAssertEqual(weekly.buckets.first?.tasks, 1)
        XCTAssertEqual(daily.usage.tokens, weekly.usage.tokens)
    }
    func testCalendarHasSevenRowsAndRealDateIdentitiesAcrossDSTAndLeapYear() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let leapNow = ISO8601DateFormatter().date(from: "2024-03-10T19:00:00Z")!
        let tree = DashboardFamilyTree(tasks: [])
        let data = HistorySnapshot(updatedAt: leapNow)
        let range = calendar.dateInterval(of: .day, for: leapNow)!
        let analytics = DashboardAnalytics.make(snapshot: data, tree: tree, interval: range, filter: DashboardFilter(), weekly: false, now: leapNow, calendar: calendar)
        XCTAssertEqual(analytics.cells.count % 7, 0)
        XCTAssertEqual(calendar.component(.weekday, from: analytics.cells[0].date), 2)
        let valid = analytics.cells.compactMap(\.bucket)
        XCTAssertEqual(valid.count, 366)
        XCTAssertTrue(valid.contains { calendar.component(.month, from: $0.id) == 2 && calendar.component(.day, from: $0.id) == 29 })
        XCTAssertEqual(Set(analytics.cells.map(\.id)).count, analytics.cells.count)
        XCTAssertTrue(valid.contains { $0.interval.duration == 23 * 3600 })
    }
    func testMissingBucketBreaksLineSegmentsAndThresholdsAreDistinct() {
        let data = snapshot([task("root", turns: [turn("a", age: 2 * 86_400), turn("b", age: 86_400, tokens: nil), turn("c")])])
        let tree = DashboardFamilyTree(tasks: data.tasks)
        let range = DateInterval(start: calendar.date(byAdding: .day, value: -2, to: interval.start)!, end: interval.end)
        let values = DashboardAnalytics.make(snapshot: data, tree: tree, interval: range, filter: DashboardFilter(), weekly: false, now: now, calendar: calendar)
        XCTAssertNil(values.buckets[1].usage.tokens)
        XCTAssertNotEqual(values.buckets[0].segment, values.buckets[2].segment)
        XCTAssertEqual(DashboardAnalytics.thresholds([0, 1, 1, 1, 10, 10]), [1, 10])
        XCTAssertGreaterThanOrEqual(DashboardAnalytics.axisMaximum(123), 123)
    }
    func testUnavailableFilesDoNotHideVerifiedTokenSubtotal() {
        var data = snapshot([task("root", turns: [turn("known")])]); data.unreadableFiles = 1
        let tree = DashboardFamilyTree(tasks: data.tasks)
        let values = DashboardAnalytics.make(snapshot: data, tree: tree, interval: interval, filter: DashboardFilter(), weekly: false, now: now, calendar: calendar)
        XCTAssertEqual(values.usage.tokens, 10)
        XCTAssertTrue(values.usage.sourceIncomplete); XCTAssertTrue(values.usage.incomplete)
        XCTAssertEqual(values.usage.missingTokens, 0, "Unknown source coverage is not a fabricated count of missing rounds")
        XCTAssertTrue(values.buckets[0].covered); XCTAssertEqual(values.buckets[0].usage.tokens, 10)
    }
    func testThreadURLsValidateIdentifierWithoutInjectingActions() {
        let id = "01a181c8-5ee0-7402-ba40-ec1ed7b4705f"
        XCTAssertEqual(DashboardThreadLink.url(for: id)?.absoluteString, "codex://threads/" + id)
        XCTAssertNil(DashboardThreadLink.url(for: "new?prompt=run"))
        XCTAssertNil(DashboardThreadLink.url(for: "../../private"))
    }

    func testFutureDatesAreNotReportedAsKnownZeroUsage() {
        let data = snapshot([task("root", turns: [turn("known")])])
        let tree = DashboardFamilyTree(tasks: data.tasks)
        let values = DashboardAnalytics.make(snapshot: data, tree: tree, interval: DashboardPeriod.year.interval(containing: now, calendar: calendar),
            filter: DashboardFilter(), weekly: false, now: now, calendar: calendar)
        let future = values.buckets.filter { $0.interval.start > now }
        XCTAssertFalse(future.isEmpty)
        XCTAssertTrue(future.allSatisfy { !$0.covered && $0.usage.tokens == nil })
    }

    func testNewEmptyIndexDoesNotClaimPastYearCoverage() {
        let data = HistorySnapshot(updatedAt: now)
        let tree = DashboardFamilyTree(tasks: [])
        let values = DashboardAnalytics.make(snapshot: data, tree: tree, interval: interval, filter: DashboardFilter(), weekly: false, now: now, calendar: calendar)
        let knownDays = values.cells.compactMap(\.bucket).filter(\.covered)
        XCTAssertEqual(knownDays.count, 1)
        XCTAssertEqual(knownDays[0].id, interval.start)
        XCTAssertEqual(knownDays[0].usage.tokens, 0)
    }
    func testNewerTerminalHistoryPreventsStaleRunningCount() {
        let data = snapshot([task("root", turns: [turn("ended", age: 0)])])
        let live = DashboardLiveSnapshot(tasks: [liveTask("root")], updatedAt: now, reliable: true)
        let values = DashboardGlobalState.make(snapshot: data, live: live, now: now, calendar: calendar)
        XCTAssertNil(values.runningCount, "Conflicting evidence is not a confirmed zero or a confirmed running task")
        XCTAssertTrue(values.runningIDs.isEmpty)
        XCTAssertTrue(values.attention.isEmpty)
    }

}

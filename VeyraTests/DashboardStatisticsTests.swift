import Foundation
import XCTest

final class DashboardStatisticsTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return value
    }
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private func turn(_ id: String, start: String, end: String, result: ExecutionResult = .completed, tokens: Int64 = 10) -> HistoryTurn {
        let end = date(end)
        return HistoryTurn(id: id, startedAt: date(start), endedAt: end, result: result, model: "fixture",
            samples: [HistoryTokenSample(id: id, date: end.addingTimeInterval(-1), tokens: HistoryTokens(TokenUsage(input: tokens, output: 0, cachedInput: 0, total: tokens)))])
    }
    private func snapshot(_ turns: [HistoryTurn], parent: String? = nil) -> HistorySnapshot {
        HistorySnapshot(tasks: [HistoryTask(id: "task", title: "Title", project: "/project", source: "cli", parentID: parent, turns: turns)])
    }

    func testCrossMidnightDurationAndEndCountsAreAssignedIndependently() {
        let value = turn("one", start: "2026-10-12T15:30:00Z", end: "2026-10-12T16:30:00Z")
        let first = DashboardPeriod.day.interval(containing: date("2026-10-12T12:00:00Z"), calendar: calendar)
        let second = DashboardPeriod.day.interval(containing: date("2026-10-12T17:00:00Z"), calendar: calendar)
        let a = DashboardStatistics.report(snapshot: snapshot([value]), interval: first, period: .day, calendar: calendar)
        let b = DashboardStatistics.report(snapshot: snapshot([value]), interval: second, period: .day, calendar: calendar)
        XCTAssertEqual(a.metrics.elapsed, 1800); XCTAssertEqual(a.metrics.normal, 0)
        XCTAssertEqual(b.metrics.elapsed, 1800); XCTAssertEqual(b.metrics.normal, 1)
        XCTAssertEqual(a.metrics.tokens.total, 0); XCTAssertEqual(b.metrics.tokens.total, 10)
        XCTAssertEqual(a.buckets.compactMap { $0.metrics.elapsed }.reduce(0, +), 1800)
        XCTAssertEqual(DashboardStatistics.resultCount(.completed, turns: a.rows[0].turns, in: first), 0)
        XCTAssertEqual(DashboardStatistics.resultCount(.completed, turns: b.rows[0].turns, in: second), 1)
        let resultLabel = ExecutionResult.completed.label + ": 1"
        XCTAssertFalse(DashboardExport.markdown(a, snapshot: snapshot([value]), hideTitles: false, hideProjects: false).contains(resultLabel))
        XCTAssertTrue(DashboardExport.markdown(b, snapshot: snapshot([value]), hideTitles: false, hideProjects: false).contains(resultLabel))
    }

    func testCountsUseHalfOpenPeriodAndSubtasksRemainSeparate() {
        let value = turn("one", start: "2026-10-12T15:59:00Z", end: "2026-10-12T16:00:00Z")
        let interval = DashboardPeriod.day.interval(containing: date("2026-10-12T12:00:00Z"), calendar: calendar)
        var data = snapshot([value])
        data.tasks.append(HistoryTask(id: "child", title: "child", source: "desktop", parentID: "task", turns: [value]))
        let report = DashboardStatistics.report(snapshot: data, interval: interval, period: .day, calendar: calendar)
        XCTAssertEqual(report.metrics.activeTasks, 1); XCTAssertEqual(report.metrics.subtasks, 1)
        XCTAssertEqual(report.metrics.normal, 0); XCTAssertEqual(report.metrics.elapsed, 120)
        XCTAssertEqual(report.metrics.tokens.total, 20)
    }

    func testMedianP90AndUnknownAreNotGoalCompletion() {
        let interval = DashboardPeriod.day.interval(containing: date("2026-10-13T01:00:00Z"), calendar: calendar)
        let values = [turn("a", start: "2026-10-13T01:00:00Z", end: "2026-10-13T01:01:00Z"),
                      turn("b", start: "2026-10-13T02:00:00Z", end: "2026-10-13T02:03:00Z", result: .failed),
                      turn("c", start: "2026-10-13T03:00:00Z", end: "2026-10-13T03:10:00Z", result: .interrupted)]
        let m = DashboardStatistics.report(snapshot: snapshot(values), interval: interval, period: .day, calendar: calendar).metrics
        XCTAssertEqual(m.median, 180); XCTAssertEqual(m.p90, 600)
        XCTAssertEqual(m.normal, 1); XCTAssertEqual(m.failed, 1); XCTAssertEqual(m.interrupted, 1)
        XCTAssertEqual(m.activeTasks, 1); XCTAssertEqual(m.activeDays, 1)
    }

    func testMissingTokensAndDurationAreNilNotZeroAndSuppressComparison() {
        let interval = DashboardPeriod.day.interval(containing: date("2026-10-13T01:00:00Z"), calendar: calendar)
        let open = HistoryTurn(id: "open", startedAt: interval.start, observedAt: interval.start.addingTimeInterval(60), result: .running)
        let report = DashboardStatistics.report(snapshot: snapshot([open]), interval: interval, period: .day, calendar: calendar)
        XCTAssertNil(report.metrics.elapsed); XCTAssertNil(report.metrics.tokens.total)
        XCTAssertEqual(report.metrics.missingDuration, 1); XCTAssertEqual(report.metrics.missingTokens, 1)
        XCTAssertNil(report.previous); XCTAssertEqual(report.metrics.open, 1)
    }

    func testFiltersApplyConsistentlyToSummaryChartsDetailsAndDistributions() {
        let interval = DashboardPeriod.day.interval(containing: date("2026-10-13T01:00:00Z"), calendar: calendar)
        let data = snapshot([turn("a", start: "2026-10-13T01:00:00Z", end: "2026-10-13T01:01:00Z"),
                             turn("b", start: "2026-10-13T02:00:00Z", end: "2026-10-13T02:01:00Z", result: .failed)])
        let filter = DashboardFilter(search: "title", project: "/project", model: "fixture", source: "cli", result: .failed)
        let report = DashboardStatistics.report(snapshot: data, interval: interval, period: .day, filter: filter, calendar: calendar)
        XCTAssertEqual(report.rows.count, 1); XCTAssertEqual(report.rows[0].turns.count, 1)
        XCTAssertEqual(report.metrics.normal, 0); XCTAssertEqual(report.metrics.failed, 1)
        XCTAssertEqual(report.buckets.map { $0.metrics.failed }.reduce(0, +), 1)
        XCTAssertEqual(report.projects[0].executions, 1); XCTAssertEqual(report.models[0].tokens, 10)
        XCTAssertEqual(report.sources[0].id, "cli")
    }

    func testNaturalPeriodsWeekStartsMondayAndYearHasTwelveBuckets() {
        let value = date("2026-10-13T01:00:00Z")
        let week = DashboardPeriod.week.interval(containing: value, calendar: calendar)
        XCTAssertEqual(calendar.component(.weekday, from: week.start), 2)
        XCTAssertEqual(DashboardPeriod.week.buckets(in: week, calendar: calendar).count, 7)
        let year = DashboardPeriod.year.interval(containing: value, calendar: calendar)
        XCTAssertEqual(calendar.component(.month, from: year.start), 1)
        XCTAssertEqual(DashboardPeriod.year.buckets(in: year, calendar: calendar).count, 12)
    }

    func testCurrentPeriodComparisonUsesEqualElapsedTimeAcrossYearBoundary() {
        let value = date("2027-01-02T04:00:00Z")
        let interval = DashboardPeriod.year.interval(containing: value, calendar: calendar)
        let before = DashboardPeriod.year.previousComparison(for: interval, now: value, calendar: calendar)!
        XCTAssertEqual(before.duration, value.timeIntervalSince(interval.start))
        XCTAssertEqual(calendar.component(.year, from: before.start), 2026)
        XCTAssertNil(DashboardPeriod.custom.previousComparison(for: interval, now: value, calendar: calendar))
    }

    func testDSTHourBucketsUseCalendarNotFixedTwentyFourHours() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let short = DashboardPeriod.day.interval(containing: date("2026-03-08T12:00:00Z"), calendar: calendar)
        let long = DashboardPeriod.day.interval(containing: date("2026-11-01T12:00:00Z"), calendar: calendar)
        XCTAssertEqual(DashboardPeriod.day.buckets(in: short, calendar: calendar).count, 23)
        XCTAssertEqual(DashboardPeriod.day.buckets(in: long, calendar: calendar).count, 25)
    }

    func testTokenOverflowAndCacheAreNotDoubleCounted() {
        let a = HistoryTokens(TokenUsage(input: 80, output: 20, cachedInput: 50, total: 100))
        XCTAssertEqual(HistoryTokens.sum([a, a]).total, 200)
        XCTAssertNil(HistoryTokens.sum([HistoryTokens(TokenUsage(total: Int64.max)), a]).total)
        XCTAssertNil(HistoryTokens.difference(a, HistoryTokens(TokenUsage(total: 200))).total)
    }

    func testExportRedactionCSVFormulaEscapingAndMarkdownEscaping() {
        let interval = DashboardPeriod.day.interval(containing: date("2026-10-13T01:00:00Z"), calendar: calendar)
        var data = snapshot([turn("a", start: "2026-10-13T01:00:00Z", end: "2026-10-13T01:01:00Z")])
        data.tasks[0].title = "=SECRET,\"title\"\n<script>|"; data.tasks[0].project = "/private/SECRET"
        let report = DashboardStatistics.report(snapshot: data, interval: interval, period: .day, calendar: calendar)
        let csv = DashboardExport.csv(report, hideTitles: false, hideProjects: false)
        XCTAssertTrue(csv.contains("'=")); XCTAssertTrue(csv.contains("\"\"title\"\""))
        let md = DashboardExport.markdown(report, snapshot: data, hideTitles: false, hideProjects: false)
        XCTAssertFalse(md.contains("<script>")); XCTAssertTrue(md.contains("&#124;"))
        for redacted in [DashboardExport.csv(report, hideTitles: true, hideProjects: true),
                         DashboardExport.markdown(report, snapshot: data, hideTitles: true, hideProjects: true)] {
            XCTAssertFalse(redacted.contains("SECRET")); XCTAssertFalse(redacted.contains("/private"))
        }
    }

    func testUnavailableSourceCannotProduceZeroUsageForEmptyHistory() {
        let interval = DashboardPeriod.day.interval(containing: date("2026-10-13T01:00:00Z"), calendar: calendar)
        let data = HistorySnapshot(unreadableFiles: 1)
        let report = DashboardStatistics.report(snapshot: data, interval: interval, period: .day, calendar: calendar)
        XCTAssertNil(report.metrics.tokens.total); XCTAssertNil(report.metrics.elapsed); XCTAssertNil(report.previous)
        XCTAssertTrue(report.buckets.allSatisfy { $0.metrics.tokens.total == nil && $0.metrics.elapsed == nil })
    }

    func testCompletedComparisonRequiresCoverageAndUsesSameExposure() {
        let now = date("2026-10-13T01:00:00Z")
        let interval = DashboardPeriod.day.interval(containing: now, calendar: calendar)
        let values = [turn("coverage", start: "2026-10-11T15:00:00Z", end: "2026-10-11T15:01:00Z"),
            turn("before", start: "2026-10-12T00:00:00Z", end: "2026-10-12T00:01:00Z"),
            turn("later", start: "2026-10-12T10:00:00Z", end: "2026-10-12T10:01:00Z"),
            turn("current", start: "2026-10-13T00:00:00Z", end: "2026-10-13T00:01:00Z")]
        let report = DashboardStatistics.report(snapshot: snapshot(values), interval: interval, period: .day, now: now, calendar: calendar)
        XCTAssertEqual(report.previous?.normal, 1)
        var incomplete = snapshot(values); incomplete.malformedEvents = 1
        XCTAssertNil(DashboardStatistics.report(snapshot: incomplete, interval: interval, period: .day, now: now, calendar: calendar).previous)
    }
}

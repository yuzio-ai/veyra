import Foundation
import XCTest

@MainActor
final class DashboardStoreTests: XCTestCase {
    private let anchor = Date(timeIntervalSince1970: 1791853200)

    private func snapshot() -> HistorySnapshot {
        let tokens = HistoryTokens(TokenUsage(input: 8, output: 2, cachedInput: 4, total: 10))
        let turn = HistoryTurn(id: "turn", startedAt: anchor.addingTimeInterval(-60), endedAt: anchor,
            result: .completed, samples: [HistoryTokenSample(id: "usage", date: anchor, tokens: tokens)])
        return HistorySnapshot(tasks: [
            HistoryTask(id: "cli", title: "CLI fixture", source: "cli", turns: [turn]),
            HistoryTask(id: "desktop", title: "Desktop fixture", source: "desktop", turns: [turn])
        ], updatedAt: anchor)
    }

    private func ready(_ store: DashboardStore) async throws -> DashboardStore.ExportContext {
        for _ in 0..<500 {
            if let context = store.exportContext { return context }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw MonitorFailure("Fixture report did not become exportable")
    }

    func testPeriodChangeBlocksStaleExportWithoutRemovingVisibleReport() async throws {
        let fixture = try SQLiteFixture()
        let store = DashboardStore(index: HistoryIndex(indexURL: fixture.home.appendingPathComponent("index.json")))
        defer { store.stop() }
        store.configurePreview(snapshot(), anchor: anchor)
        let previous = try XCTUnwrap(store.exportContext)
        XCTAssertEqual(previous.period, .week)

        store.period = .month
        XCTAssertNil(store.exportContext)
        XCTAssertEqual(store.report?.interval, previous.report.interval, "Keep content visible during calculation")
        let next = try await ready(store)
        XCTAssertEqual(next.period, .month)
        XCTAssertEqual(next.report.interval, store.interval)
        XCTAssertNotEqual(next.report.interval, previous.report.interval)
        XCTAssertEqual(next.report.metrics.normal, 2)
        XCTAssertTrue(DashboardExport.csv(next.report, hideTitles: false, hideProjects: false)
            .contains(ISO8601DateFormatter().string(from: next.report.interval.start)))
    }

    func testFilterChangeCannotExportRowsFromPreviousFilter() async throws {
        let fixture = try SQLiteFixture()
        let store = DashboardStore(index: HistoryIndex(indexURL: fixture.home.appendingPathComponent("index.json")))
        defer { store.stop() }
        store.configurePreview(snapshot(), anchor: anchor)
        store.filter.source = "cli"
        XCTAssertNil(store.exportContext)
        let filtered = try await ready(store)
        XCTAssertEqual(filtered.report.rows.map(\.id), ["cli"])
        XCTAssertEqual(filtered.report.metrics.tokens.total, 10)
        let csv = DashboardExport.csv(filtered.report, hideTitles: false, hideProjects: false)
        let markdown = DashboardExport.markdown(filtered.report, snapshot: filtered.snapshot, hideTitles: false, hideProjects: false)
        XCTAssertTrue(csv.contains("CLI fixture")); XCTAssertFalse(csv.contains("Desktop fixture"))
        XCTAssertTrue(markdown.contains("CLI fixture")); XCTAssertFalse(markdown.contains("Desktop fixture"))
    }

    func testExportKeepsReportCoverageAndPeriodFromOnePublishedSnapshot() async throws {
        let fixture = try SQLiteFixture()
        let store = DashboardStore(index: HistoryIndex(indexURL: fixture.home.appendingPathComponent("index.json")))
        defer { store.stop() }
        store.configurePreview(snapshot(), anchor: anchor)
        let captured = try XCTUnwrap(store.exportContext)
        store.snapshot = HistorySnapshot(updatedAt: anchor.addingTimeInterval(30))
        store.calculate()
        XCTAssertNil(store.exportContext)
        let next = try await ready(store)
        XCTAssertTrue(next.report.rows.isEmpty); XCTAssertTrue(next.snapshot.tasks.isEmpty)
        XCTAssertEqual(next.snapshot.updatedAt, anchor.addingTimeInterval(30))
        XCTAssertEqual(captured.report.rows.count, 2); XCTAssertEqual(captured.snapshot.tasks.count, 2)
        XCTAssertEqual(captured.snapshot.updatedAt, anchor)
        XCTAssertEqual(captured.period, .week)
        store.stop()
        XCTAssertNil(store.exportContext)
    }

    func testRapidPeriodAndFilterChangesPublishOnlyCurrentExport() async throws {
        let fixture = try SQLiteFixture()
        let store = DashboardStore(index: HistoryIndex(indexURL: fixture.home.appendingPathComponent("index.json")))
        defer { store.stop() }
        store.configurePreview(snapshot(), anchor: anchor)
        store.period = .year
        store.period = .month
        store.filter.source = "desktop"
        store.filter.search = "no matching fixture"
        XCTAssertNil(store.exportContext)
        let context = try await ready(store)
        XCTAssertEqual(context.period, .month)
        XCTAssertEqual(context.report.interval, store.interval)
        XCTAssertTrue(context.report.rows.isEmpty)
    }
}

@MainActor
final class DashboardWorkspaceStoreTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-28T09:00:00Z")!
    private func fixture() -> HistorySnapshot {
        let usage = HistoryTokens(TokenUsage(total: 10))
        return HistorySnapshot(tasks: [HistoryTask(id: "fixture", title: "Fixture", source: "desktop", turns: [
            HistoryTurn(id: "turn", startedAt: now.addingTimeInterval(-120), endedAt: now.addingTimeInterval(-60), result: .failed,
                        samples: [HistoryTokenSample(id: "usage", date: now.addingTimeInterval(-60), tokens: usage)])
        ])], updatedAt: now)
    }
    private func settle(_ store: DashboardStore) async throws {
        for _ in 0..<500 {
            if store.exportContext != nil && !store.calculationPending { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Workspace did not settle")
    }
    func testPageQueriesAreIndependentAndAnalyticsDefaultsToThirtyDays() async throws {
        let store = DashboardStore(); defer { store.stop() }
        store.configurePreview(fixture(), anchor: now)
        store.period = .day; store.filter.search = "Fixture"; try await settle(store)
        let overview = store.interval
        store.switchPage(.analytics); try await settle(store)
        XCTAssertEqual(Calendar.current.dateComponents([.day], from: store.interval.start, to: store.interval.end).day, 30)
        XCTAssertTrue(store.filter.search.isEmpty)
        store.filter.source = "desktop"
        store.switchPage(.overview); try await settle(store)
        XCTAssertEqual(store.interval, overview); XCTAssertEqual(store.filter.search, "Fixture"); XCTAssertNil(store.filter.source)
        store.switchPage(.analytics); try await settle(store)
        XCTAssertEqual(store.filter.source, "desktop"); XCTAssertTrue(store.filter.search.isEmpty)
    }
    func testChartSelectionChangesDetailsWithoutChangingSummaryOrExport() async throws {
        let store = DashboardStore(); defer { store.stop() }
        store.configurePreview(fixture(), anchor: now); store.switchPage(.analytics); try await settle(store)
        let range = store.interval, count = store.analytics.taskCount
        store.selectedFamilyID = "fixture"
        let older = Calendar.current.date(byAdding: .day, value: -200, to: now)!
        store.chartInterval = Calendar.current.dateInterval(of: .day, for: older)
        try await settle(store)
        XCTAssertEqual(store.interval, range); XCTAssertEqual(store.analytics.taskCount, count)
        XCTAssertEqual(store.exportContext?.report.interval, range)
        XCTAssertEqual(store.exportContext?.report.rows.count, 1)
        XCTAssertTrue(store.families.isEmpty); XCTAssertEqual(store.selectedFamilyID, "fixture")
    }
    func testGlobalStateIgnoresFiltersAndFocusRetainsQuery() async throws {
        let store = DashboardStore(); defer { store.stop() }
        store.configurePreview(fixture(), anchor: now); store.period = .day; try await settle(store)
        let count = store.global.attention.count, range = store.interval
        store.filter.search = "not found"; try await settle(store)
        XCTAssertEqual(store.global.attention.count, count); XCTAssertEqual(count, 1)
        store.focus = .attention
        XCTAssertEqual(store.displayedFamilies.map(\.id), ["fixture"])
        store.focus = .period
        XCTAssertEqual(store.interval, range); XCTAssertEqual(store.filter.search, "not found"); XCTAssertTrue(store.displayedFamilies.isEmpty)
    }
    func testRunningBeforeHistoryIndexingHasSelectableFamily() {
        let store = DashboardStore(); defer { store.stop() }
        store.configurePreview(HistorySnapshot(updatedAt: now), anchor: now)
        let live = TaskSnapshot(id: "live-only", title: "Live only", model: nil, source: .desktop, parentID: nil,
            startedAt: now.addingTimeInterval(-60), updatedAt: now, tokens: TokenUsage(), activity: .running)
        store.updateLive(DashboardLiveSnapshot(tasks: [live], updatedAt: now, reliable: true))
        store.focus = .running
        XCTAssertEqual(store.global.runningCount, 1); XCTAssertEqual(store.displayedFamilies.map(\.id), ["live-only"])
        XCTAssertTrue(store.displayedFamilies[0].rows[0].turns.isEmpty)
    }
}

import AppKit
import SwiftUI

/// Isolated fixtures only. This path never reads the user's Codex home or production index.
@MainActor
enum DashboardPreview {
    static let referenceDate = ISO8601DateFormatter().date(from: "2026-10-28T09:30:00Z")!
    private static var window: NSWindow?

    static func fixture(scenario: String) -> HistorySnapshot {
        if scenario == "empty" || scenario == "empty-analytics" { return HistorySnapshot(updatedAt: referenceDate) }
        let calendar = Calendar.autoupdatingCurrent
        let count = scenario == "overflow" ? 100 : 10
        let titles = ["模型设置 · 服务商设置重构", "Dashboard · 全局状态与任务聚焦", "模型配置 · 默认方案切换",
                      "任务编排 · 执行与独立评审", "健康首页 · 调整模块顺序", "网站架构 · 迁移至 Next.js",
                      "任务编排 · 完善执行记录", "健康 · 模块结构核对", "配置 · 执行结果检查", "记录 · 汇总核对"]
        var tasks: [HistoryTask] = []
        for index in 0..<count {
            var turns: [HistoryTurn] = []
            let rounds = index == 0 ? (scenario == "many-rounds" ? 1000 : 12) : 5
            for round in 0..<rounds {
                let age = round == 0 ? 100 + index * 30 : 400 + round * 1800
                let end = referenceDate.addingTimeInterval(-Double(age))
                let open = index == 0 && round == 0
                let failed = index == 5 && round == 0 || index == 0 && round == 2
                let missing = scenario.contains("gaps") && round == 0
                let amount = Int64((index + 1) * (round + 1) * 110_000)
                turns.append(HistoryTurn(id: "turn-\(index)-\(round)", startedAt: end.addingTimeInterval(-Double(60 + round * 9)),
                    endedAt: open ? nil : end, observedAt: end,
                    result: open ? .running : failed ? .failed : .completed, model: round % 4 == 0 ? "gpt-6-astra" : "gpt-6.1-sol",
                    samples: [HistoryTokenSample(id: "usage-\(index)-\(round)", date: end,
                        tokens: HistoryTokens(TokenUsage(input: amount, output: 200, cachedInput: 100, total: missing ? nil : amount + 200)))],
                    hasTokenGap: missing))
            }
            // Real annual coverage and an uneven daily rhythm; no token snapshots are guessed.
            if index < 7 {
                for day in stride(from: 3 + index, through: 360, by: 11 + index) {
                    let date = calendar.date(byAdding: .day, value: -day, to: referenceDate)!
                    let missing = scenario.contains("gaps") && day % 7 == 0
                    turns.append(HistoryTurn(id: "past-\(index)-\(day)", startedAt: date.addingTimeInterval(-120), endedAt: date,
                        result: .completed, model: "gpt-6.1-sol", samples: [HistoryTokenSample(id: "past-usage-\(index)-\(day)", date: date,
                        tokens: HistoryTokens(TokenUsage(total: missing ? nil : Int64(day % 9 + 1) * 90_000)))], hasTokenGap: missing))
                }
            }
            tasks.append(HistoryTask(id: "fixture-\(index)", title: scenario == "long" ? String(repeating: "任务标题与多语言展示 ", count: 12) : titles[index % titles.count],
                project: index % 4 == 0 ? "/fixtures/veyra" : index % 4 == 1 ? "/fixtures/mewoo-ios" : index % 4 == 2 ? "/fixtures/codistra" : "/fixtures/skills",
                source: index.isMultiple(of: 2) ? "desktop" : "cli", parentID: index == 8 || index == 9 ? "fixture-0" : nil,
                sourceAvailable: index != 7, turns: turns))
        }
        return HistorySnapshot(tasks: tasks, updatedAt: referenceDate, unreadableFiles: scenario.contains("gaps") ? 1 : 0)
    }

    private static func configure(_ store: DashboardStore, scenario: String) async throws {
        store.configurePreview(fixture(scenario: scenario), anchor: referenceDate)
        store.period = .day
        let ids = ["fixture-1", "fixture-3"]
        let live = ids.map { id in
            TaskSnapshot(id: id, title: id, model: "gpt-6.1-sol", source: .desktop, parentID: nil,
                         startedAt: referenceDate.addingTimeInterval(-60), updatedAt: referenceDate,
                         tokens: TokenUsage(), activity: .running)
        }
        store.updateLive(DashboardLiveSnapshot(tasks: scenario.hasPrefix("empty") ? [] : live, updatedAt: referenceDate, reliable: scenario != "gaps"))
        if scenario == "detail" || scenario == "many-rounds" || scenario == "long" { store.selectedFamilyID = "fixture-0" }
        if scenario.hasPrefix("analytics") || scenario == "selected" || scenario == "empty-analytics" {
            store.switchPage(.analytics)
            if scenario == "selected" { store.chartInterval = Calendar.current.dateInterval(of: .day, for: referenceDate.addingTimeInterval(-20 * 86_400)) }
        }
        if scenario == "many-rounds" { store.period = .year; store.selectedTurnID = "fixture-0:turn-0-999" }
        try await settled(store)
    }

    private static func settled(_ store: DashboardStore) async throws {
        for _ in 0..<400 {
            if !store.calculationPending { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw MonitorFailure("Dashboard fixture calculation did not finish")
    }

    static func render(to directory: URL) {
        Task { @MainActor in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var checks: [[String: Any]] = []
                for scenario in ["overview", "detail", "analytics", "analytics-gaps", "selected", "empty", "empty-analytics", "gaps", "overflow", "long", "many-rounds"] {
                    for (style, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua),
                                               ("light-increased", .accessibilityHighContrastAqua), ("dark-increased", .accessibilityHighContrastDarkAqua)] {
                        let store = DashboardStore(index: HistoryIndex(indexURL: directory.appendingPathComponent("unused-index.json")))
                        try await configure(store, scenario: scenario)
                        let hosting = NSHostingView(rootView: DashboardView(store: store))
                        let native = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 1050),
                                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                        native.isReleasedWhenClosed = false; native.title = L10n.text("Task overview")
                        native.appearance = NSAppearance(named: appearance); native.contentView = hosting
                        native.orderFront(nil); window = native
                        try await Task.sleep(for: .milliseconds(scenario == "many-rounds" ? 400 : 180)); hosting.layoutSubtreeIfNeeded()
                        try PreviewSupport.saveBitmap(hosting, to: directory.appendingPathComponent("\(scenario)-\(style).png"))
                        try checkOverflow(hosting)
                        if scenario == "many-rounds" {
                            let positioned = scrollViews(in: hosting).contains { scroll in
                                hosting.convert(scroll.bounds, from: scroll).midX > hosting.bounds.midX
                                    && scroll.contentView.bounds.minY > 10
                            }
                            guard positioned else { throw MonitorFailure("Selected old execution did not scroll into view") }
                        }
                        if scenario == "detail" || scenario == "analytics" || scenario == "long" {
                            for width: CGFloat in [1120, 900] {
                                native.setContentSize(NSSize(width: width, height: 800))
                                try await Task.sleep(for: .milliseconds(130)); hosting.layoutSubtreeIfNeeded()
                                try checkOverflow(hosting)
                                try PreviewSupport.saveBitmap(hosting, to: directory.appendingPathComponent("\(scenario)-\(Int(width))-\(style).png"))
                            }
                        }
                        let selected = store.selectedFamilyID
                        let global = store.global.runningCount
                        store.filter.source = "cli"
                        try await settled(store)
                        guard store.report?.rows.allSatisfy({ $0.task.source == "cli" }) == true else { throw MonitorFailure("Dashboard filter mismatch") }
                        guard store.global.runningCount == global else { throw MonitorFailure("Historical filters changed global state") }
                        guard store.selectedFamilyID == selected else { throw MonitorFailure("Filters silently replaced task selection") }
                        store.period = .year; try await settled(store)
                        guard store.report?.buckets.count == 12 else { throw MonitorFailure("Legacy year buckets changed") }
                        checks.append(["scenario": scenario, "appearance": style, "filterPassed": true,
                                       "selectionPassed": true, "globalIsolationPassed": true, "calendarPassed": store.analytics.cells.count % 7 == 0])
                        store.stop(); native.orderOut(nil); window = nil
                    }
                }
                guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("unused-index.json").path) else {
                    throw MonitorFailure("Preview unexpectedly wrote an index")
                }
                try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys])
                    .write(to: directory.appendingPathComponent("layouts.json"))
                print("Rendered \(checks.count) Dashboard scenarios; overflow, filters, selection, global scope and calendars passed")
                NSApp.terminate(nil)
            } catch {
                FileHandle.standardError.write(Data("Dashboard preview failed: \(error)\n".utf8)); exit(1)
            }
        }
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }

    private static func checkOverflow(_ view: NSView) throws {
        if let scroll = view as? NSScrollView, let document = scroll.documentView {
            guard document.bounds.width <= scroll.contentView.bounds.width + 1 else { throw MonitorFailure("Dashboard horizontal overflow") }
        }
        for child in view.subviews { try checkOverflow(child) }
    }
}

import Foundation
import Observation

@MainActor @Observable
final class DashboardStore {
    struct ExportContext: Sendable {
        let report: DashboardReport
        let snapshot: HistorySnapshot
        let period: DashboardPeriod
    }

    var snapshot = HistorySnapshot()
    var report: DashboardReport?
    private(set) var exportContext: ExportContext?
    var scanning = false
    var progress = HistoryScanProgress(completed: 0, total: 0)
    var error: String?
    var period: DashboardPeriod = .day { didSet { selectedBucket = nil; chartInterval = nil; calculate() } }
    var anchor = Date() { didSet { selectedBucket = nil; chartInterval = nil; calculate() } }
    var customStart = Calendar.current.startOfDay(for: Date()) {
        didSet {
            if customEnd < customStart { customEnd = customStart }
            selectedBucket = nil; chartInterval = nil; calculate()
        }
    }
    var customEnd = Date() { didSet { selectedBucket = nil; chartInterval = nil; calculate() } }
    var filter = DashboardFilter() { didSet { calculate() } }
    var selectedBucket: Date?
    var page: DashboardPage = .overview
    var focus: DashboardFocus = .period
    var selectedFamilyID: String? { didSet { if oldValue != selectedFamilyID { selectedTurnID = nil } } }
    var selectedTurnID: String?
    var chartInterval: DateInterval? { didSet { calculate() } }
    var weekly = false { didSet { calculate() } }
    private(set) var families: [DashboardFamily] = []
    private(set) var analytics = DashboardAnalytics()
    private(set) var global = DashboardGlobalState()
    private(set) var live = DashboardLiveSnapshot()
    private(set) var calculationPending = false
    @ObservationIgnored private var previewNow: Date?
    @ObservationIgnored private var resetting = false
    @ObservationIgnored private var queries: [DashboardPage: Query] = [:]
    private struct Query {
        var period: DashboardPeriod
        var anchor: Date
        var start: Date
        var end: Date
        var filter: DashboardFilter
    }
    private(set) var homePath = ""
    @ObservationIgnored private let index: HistoryIndex
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var calculationTask: Task<Void, Never>?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var scanRevision = 0

    init(index: HistoryIndex = HistoryIndex(indexURL: HistoryIndex.defaultURL)) { self.index = index }

    var now: Date { previewNow ?? Date() }
    var detailInterval: DateInterval {
        if page == .overview && focus != .period { return DateInterval(start: now.addingTimeInterval(-86_400), end: now) }
        return page == .analytics ? chartInterval ?? interval : interval
    }

    var displayedFamilies: [DashboardFamily] {
        guard page == .overview, focus != .period else { return families }
        let ids = focus == .running ? global.runningIDs : Set(global.attention.map(\.id))
        let range = detailInterval
        var rows = DashboardStatistics.rows(tasks: Array(global.tree.tasks.values), interval: range, filter: DashboardFilter(), now: now)
        let present = Set(rows.map { global.tree.rootByID[$0.id] ?? $0.id })
        for id in ids.subtracting(present) {
            if let task = global.tree.tasks[id] { rows.append(DashboardTaskRow(task: task, turns: [], elapsed: nil, tokens: HistoryTokens())) }
        }
        return global.tree.families(rows: rows, interval: range).filter { ids.contains($0.id) }
    }

    func switchPage(_ next: DashboardPage) {
        guard next != page else { return }
        queries[page] = Query(period: period, anchor: anchor, start: customStart, end: customEnd, filter: filter)
        page = next
        let calendar = Calendar.autoupdatingCurrent
        let query = queries[next] ?? Query(period: .custom, anchor: now,
            start: calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now))!, end: now, filter: DashboardFilter())
        period = query.period; anchor = query.anchor; customStart = query.start; customEnd = query.end; filter = query.filter
        calculate()
    }

    func updateLive(_ value: DashboardLiveSnapshot) {
        live = value.homePath == homePath || homePath.isEmpty ? value : DashboardLiveSnapshot()
        global = DashboardGlobalState.make(snapshot: snapshot, live: live, now: now, calendar: .autoupdatingCurrent)
    }

    func selectAttention(_ item: DashboardAttention) {
        focus = .attention; selectedFamilyID = item.id
        selectedTurnID = item.turnID.map { item.taskID + ":" + $0 }
    }

    var interval: DateInterval {
        if period == .custom {
            let calendar = Calendar.autoupdatingCurrent
            let start = calendar.startOfDay(for: customStart)
            let endDay = calendar.startOfDay(for: max(customStart, customEnd))
            return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: endDay)!)
        }
        return period.interval(containing: anchor, calendar: .autoupdatingCurrent)
    }

    func start(home: URL) {
        stop()
        resetting = true
        if homePath != home.path {
            snapshot = HistorySnapshot(); report = nil; selectedBucket = nil
            selectedFamilyID = nil; selectedTurnID = nil; families = []; analytics = DashboardAnalytics(); global = DashboardGlobalState()
            chartInterval = nil
            live = DashboardLiveSnapshot(); focus = .period; queries = [:]; filter = DashboardFilter()
        }
        homePath = home.path
        resetting = false
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func stop() {
        pollingTask?.cancel(); pollingTask = nil
        scanTask?.cancel(); scanTask = nil
        scanRevision += 1; scanning = false
        calculationTask?.cancel(); calculationTask = nil; revision += 1
        exportContext = nil
        calculationPending = false
    }

    func refresh() {
        guard !scanning, !homePath.isEmpty else { return }
        scanning = true; error = nil; progress = HistoryScanProgress(completed: 0, total: 0)
        scanRevision += 1
        let generation = scanRevision, home = URL(fileURLWithPath: homePath), index = index
        scanTask = Task { [weak self] in
            do {
                let next = try await index.scan(home: home, progress: { [weak self] value in
                    await self?.updateProgress(value, generation: generation)
                })
                guard let self, !Task.isCancelled, self.scanRevision == generation else { return }
                self.snapshot = next; self.scanning = false; self.calculate()
            } catch is CancellationError { }
            catch {
                guard let self, self.scanRevision == generation else { return }
                self.scanning = false
                self.error = (error as? MonitorFailure)?.message ?? L10n.text("Unable to update the history index. Check file permissions or clear the index to rebuild.")
            }
        }
    }

    private func updateProgress(_ value: HistoryScanProgress, generation: Int) {
        if scanRevision == generation { progress = value }
    }

    func clear() async {
        let home = URL(fileURLWithPath: homePath)
        stop()
        do {
            try await index.clear()
            snapshot = HistorySnapshot(); report = nil
            families = []; analytics = DashboardAnalytics(); selectedFamilyID = nil; selectedTurnID = nil
            global = DashboardGlobalState.make(snapshot: snapshot, live: live, now: now, calendar: .autoupdatingCurrent)
            start(home: home)
        } catch { self.error = L10n.text("Unable to clear the history index. Check file permissions.") }
    }

    func move(_ direction: Int) {
        if period == .custom {
            let days = Calendar.current.dateComponents([.day], from: interval.start, to: interval.end).day ?? 1
            let start = Calendar.current.date(byAdding: .day, value: direction * days, to: customStart)!
            let end = Calendar.current.date(byAdding: .day, value: direction * days, to: customEnd)!
            customStart = start; customEnd = end
        } else {
            anchor = Calendar.current.date(byAdding: period.component, value: direction, to: interval.start)!
        }
    }

    func current() {
        let recent = page == .analytics && period == .custom
            && Calendar.current.dateComponents([.day], from: interval.start, to: interval.end).day == 30
        anchor = Date()
        if recent { recentThirtyDays() }
        else if period == .custom { customStart = Calendar.current.startOfDay(for: Date()); customEnd = Date() }
    }

    func recentThirtyDays() {
        period = .custom
        customStart = Calendar.autoupdatingCurrent.date(byAdding: .day, value: -29, to: Calendar.autoupdatingCurrent.startOfDay(for: now))!
        customEnd = now
    }

    func calculate() {
        guard !resetting else { return }
        revision += 1
        // Keep the visible report stable, but never export a report for superseded inputs.
        exportContext = nil
        calculationPending = true
        let generation = revision, snapshot = snapshot, interval = interval, period = period, filter = filter
        let detailInterval = self.detailInterval, weekly = weekly, now = now
        calculationTask?.cancel()
        calculationTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                let tree = DashboardFamilyTree(tasks: snapshot.tasks)
                let report = DashboardStatistics.report(snapshot: snapshot, interval: interval, period: period, filter: filter, now: now)
                let families = tree.families(interval: detailInterval, filter: filter, now: now)
                let analytics = DashboardAnalytics.make(snapshot: snapshot, tree: tree, interval: interval, filter: filter,
                                                        weekly: weekly, now: now, calendar: .autoupdatingCurrent)
                return (report, families, analytics)
            }.value
            guard let self, !Task.isCancelled, self.revision == generation else { return }
            self.report = result.0; self.families = result.1; self.analytics = result.2
            self.calculationPending = false
            self.global = DashboardGlobalState.make(snapshot: snapshot, live: self.live, now: now, calendar: .autoupdatingCurrent)
            self.exportContext = ExportContext(report: result.0, snapshot: snapshot, period: period)
        }
    }

    func configurePreview(_ snapshot: HistorySnapshot, anchor: Date) {
        stop()
        previewNow = anchor
        self.anchor = anchor
        self.period = .week
        calculationTask?.cancel(); revision += 1
        self.snapshot = snapshot
        let tree = DashboardFamilyTree(tasks: snapshot.tasks)
        families = tree.families(interval: interval, filter: filter, now: anchor)
        analytics = DashboardAnalytics.make(snapshot: snapshot, tree: tree, interval: interval, filter: filter,
                                            weekly: weekly, now: anchor, calendar: .autoupdatingCurrent)
        global = DashboardGlobalState.make(snapshot: snapshot, live: live, now: anchor, calendar: .autoupdatingCurrent)
        report = DashboardStatistics.report(snapshot: snapshot, interval: interval, period: period, now: anchor)
        if let report { exportContext = ExportContext(report: report, snapshot: snapshot, period: period) }
    }
}

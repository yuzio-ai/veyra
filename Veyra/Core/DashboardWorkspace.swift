import Foundation

enum DashboardThreadLink {
    static func url(for identifier: String) -> URL? {
        guard UUID(uuidString: identifier) != nil else { return nil }
        return URL(string: "codex://threads/\(identifier)")
    }
}

enum DashboardPage: String, CaseIterable, Sendable {
    case overview, analytics
    var label: String { self == .overview ? L10n.text("Overview") : L10n.text("Analytics") }
}

enum DashboardFocus: String, CaseIterable, Sendable {
    case period, running, attention
    var label: String {
        switch self {
        case .period: L10n.text("Entire period")
        case .running: L10n.text("Currently running")
        case .attention: L10n.text("Needs attention · Last 24 hours")
        }
    }
}

/// A known subtotal and its coverage travel together. Raw historical fields remain unchanged.
struct DashboardUsage: Equatable, Sendable {
    var tokens: Int64?
    var endedDuration: TimeInterval?
    var missingTokens = 0
    var missingDuration = 0
    var openTurns = 0
    var sourceIncomplete = false
    var incomplete: Bool { missingTokens > 0 || sourceIncomplete }

    static func summarize(_ rows: [DashboardTaskRow], in interval: DateInterval, reliableEmpty: Bool = true) -> Self {
        var result = Self()
        var total: Int64 = 0, known = false, overflow = false
        var duration: TimeInterval = 0, knownDuration = false
        var seenTurns: Set<String> = [], seenSamples: Set<String> = []
        for row in rows {
            for turn in row.turns where seenTurns.insert(row.id + "\u{1f}" + turn.id).inserted {
                if turn.result == .running { result.openTurns += 1 }
                if let elapsed = turn.elapsed(in: interval) { duration += elapsed; knownDuration = true }
                else { result.missingDuration += 1 }
                var turnHasKnown = false, turnHasGap = turn.hasTokenGap || turn.samples.isEmpty
                for sample in turn.samples where interval.start <= sample.date && sample.date < interval.end {
                    guard seenSamples.insert(row.id + "\u{1f}" + sample.id).inserted else { continue }
                    guard let value = sample.tokens.total, value >= 0 else { turnHasGap = true; continue }
                    let next = total.addingReportingOverflow(value)
                    if next.overflow { overflow = true } else { total = next.partialValue }
                    turnHasKnown = true; known = true
                }
                // Reliable samples exist, just outside this interval: its known contribution is zero.
                if !turnHasKnown && !turnHasGap { known = true }
                if turnHasGap { result.missingTokens += 1 }
            }
        }
        if rows.isEmpty && reliableEmpty { known = true; knownDuration = true }
        result.tokens = known && !overflow ? total : nil
        if overflow { result.missingTokens += 1 }
        result.endedDuration = knownDuration ? duration : nil
        return result
    }
}

struct DashboardFamily: Identifiable, Sendable {
    let id: String
    let title: String
    let project: String?
    let members: [HistoryTask]
    let rows: [DashboardTaskRow]
    let usage: DashboardUsage
    let latestActivity: Date?
    var turnCount: Int { rows.reduce(0) { $0 + $1.turns.count } }
    var childCount: Int { members.filter { $0.id != id }.count }
}

struct DashboardFamilyTree: Sendable {
    let tasks: [String: HistoryTask]
    let rootByID: [String: String]

    init(tasks input: [HistoryTask], live: [TaskSnapshot] = [], ancestors: [TaskReference] = []) {
        var tasks = Dictionary(input.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for ref in ancestors where tasks[ref.id] == nil {
            tasks[ref.id] = HistoryTask(id: ref.id, title: ref.title, source: "desktop", parentID: ref.parentID)
        }
        for task in live where task.backend == .codex && tasks[task.id] == nil {
            tasks[task.id] = HistoryTask(id: task.id, title: task.title, source: task.sourceLabel, parentID: task.parentID)
        }
        var parents: [String: String] = [:]
        for task in Array(tasks.values) {
            if let parent = task.parentID {
                parents[task.id] = parent
                if tasks[parent] == nil {
                    tasks[parent] = HistoryTask(id: parent, title: L10n.text("Parent task · \(String(parent.prefix(8)))"), source: "desktop")
                }
            }
        }
        var checked: Set<String> = []
        for start in tasks.keys.sorted() where !checked.contains(start) {
            var path: [String] = [], positions: [String: Int] = [:], next: String? = start
            while let id = next, !checked.contains(id) {
                if let position = positions[id] {
                    if let root = path[position...].min() { parents.removeValue(forKey: root) }
                    break
                }
                positions[id] = path.count; path.append(id); next = parents[id]
            }
            checked.formUnion(path)
        }
        var roots: [String: String] = [:]
        for id in tasks.keys {
            var root = id
            while let parent = parents[root] { root = parent }
            roots[id] = root
        }
        self.tasks = tasks; rootByID = roots
    }

    func families(interval: DateInterval, filter: DashboardFilter, now: Date) -> [DashboardFamily] {
        let raw = DashboardStatistics.rows(tasks: Array(tasks.values), interval: interval, filter: filter, now: now)
        return families(rows: raw, interval: interval)
    }

    func families(rows: [DashboardTaskRow], interval: DateInterval) -> [DashboardFamily] {
        let grouped = Dictionary(grouping: rows) { rootByID[$0.id] ?? $0.id }
        let members = Dictionary(grouping: tasks.values) { rootByID[$0.id] ?? $0.id }
        return grouped.map { root, rows in
            let rootTask = tasks[root]!
            let all = (members[root] ?? []).sorted { $0.id == $1.id ? false : $0.id == root ? true : $1.id == root ? false : $0.id < $1.id }
            return DashboardFamily(id: root, title: rootTask.title,
                project: rootTask.project ?? all.compactMap(\.project).first,
                members: all, rows: rows, usage: .summarize(rows, in: interval),
                latestActivity: rows.flatMap(\.turns).compactMap(\.lastActivity).max())
        }.sorted { ($0.latestActivity ?? .distantPast) != ($1.latestActivity ?? .distantPast)
            ? ($0.latestActivity ?? .distantPast) > ($1.latestActivity ?? .distantPast) : $0.id < $1.id }
    }
}

extension HistoryTurn {
    var lastActivity: Date? { ([startedAt, endedAt, observedAt].compactMap { $0 } + samples.map(\.date)).max() }
}

struct DashboardLiveSnapshot: Sendable {
    var tasks: [TaskSnapshot] = []
    var ancestors: [TaskReference] = []
    var updatedAt: Date?
    var reliable = false
    var homePath = ""
    func isFresh(at now: Date) -> Bool {
        guard reliable, let updatedAt else { return false }
        return (0...60).contains(now.timeIntervalSince(updatedAt))
    }
}

enum DashboardAttentionReason: String, CaseIterable, Sendable {
    case failed, interrupted, uncertain
    var label: String {
        switch self {
        case .failed: L10n.text("Latest execution failed")
        case .interrupted: L10n.text("Latest execution interrupted")
        case .uncertain: L10n.text("Current status unconfirmed")
        }
    }
    var rank: Int { self == .uncertain ? 1 : 0 }
}

struct DashboardAttention: Identifiable, Sendable {
    let familyID: String
    let taskID: String
    let turnID: String?
    let title: String
    let project: String?
    let reasons: [DashboardAttentionReason]
    let date: Date
    var id: String { familyID }
}

struct DashboardGlobalState: Sendable {
    var runningIDs: Set<String> = []
    var runningCount: Int?
    var todayCount = 0
    var todayProjects = 0
    var attention: [DashboardAttention] = []
    var tree = DashboardFamilyTree(tasks: [])

    static func make(snapshot: HistorySnapshot, live: DashboardLiveSnapshot, now: Date, calendar: Calendar) -> Self {
        let codex = live.tasks.filter { $0.backend == .codex }
        let tree = DashboardFamilyTree(tasks: snapshot.tasks, live: codex, ancestors: live.ancestors)
        let fresh = live.isFresh(at: now)
        let conflicting = Set(codex.filter { current in
            guard current.activity == .running,
                  let latest = tree.tasks[current.id]?.turns.max(by: { ($0.lastActivity ?? .distantPast) < ($1.lastActivity ?? .distantPast) }),
                  let endedAt = latest.endedAt else { return false }
            return endedAt >= (current.startedAt ?? .distantPast)
        }.map(\.id))
        let running = fresh ? Set(codex.filter { $0.activity == .running && !conflicting.contains($0.id) }.map { tree.rootByID[$0.id] ?? $0.id }) : []
        let today = calendar.dateInterval(of: .day, for: now)!
        let active = tree.families(interval: today, filter: DashboardFilter(), now: now)
        let cutoff = now.addingTimeInterval(-86_400)
        var found: [String: [DashboardAttention]] = [:]
        let liveByID = Dictionary(codex.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for task in tree.tasks.values where !task.archived {
            let latest = task.turns.max { ($0.lastActivity ?? .distantPast) < ($1.lastActivity ?? .distantPast) }
            let candidate = liveByID[task.id]
            let superseded = latest?.endedAt != nil && (candidate?.updatedAt ?? .distantPast) <= (latest?.lastActivity ?? .distantPast)
            let current = superseded ? nil : candidate
            let date = [latest?.lastActivity, current?.updatedAt].compactMap { $0 }.max() ?? .distantPast
            guard date >= cutoff, date <= now else { continue }
            var reasons: [DashboardAttentionReason] = []
            // A newer current turn supersedes an older failed turn.
            let hasNewerLive = current.map { $0.updatedAt > (latest?.lastActivity ?? .distantPast) } ?? false
            if !hasNewerLive && latest?.result == .failed { reasons.append(.failed) }
            if !hasNewerLive && latest?.result == .interrupted { reasons.append(.interrupted) }
            if current?.activity != .running || !fresh {
                if current != nil || latest?.result == .running || latest?.result == .unknown { reasons.append(.uncertain) }
            }
            guard !reasons.isEmpty else { continue }
            let root = tree.rootByID[task.id] ?? task.id
            let rootTask = tree.tasks[root]
            found[root, default: []].append(DashboardAttention(familyID: root, taskID: task.id, turnID: latest?.id,
                title: rootTask?.title ?? task.title, project: rootTask?.project ?? task.project, reasons: reasons, date: date))
        }
        let attention = found.values.compactMap { entries -> DashboardAttention? in
            guard let newest = entries.max(by: { $0.date < $1.date }) else { return nil }
            let reasons = DashboardAttentionReason.allCases.filter { reason in entries.contains { $0.reasons.contains(reason) } }
            let target = entries.sorted { a, b in
                let ar = a.reasons.map(\.rank).min() ?? 1, br = b.reasons.map(\.rank).min() ?? 1
                return ar != br ? ar < br : a.date > b.date
            }.first!
            return DashboardAttention(familyID: newest.familyID, taskID: target.taskID, turnID: target.turnID,
                title: newest.title, project: newest.project, reasons: reasons, date: newest.date)
        }.sorted { a, b in
            let ar = a.reasons.map(\.rank).min() ?? 1, br = b.reasons.map(\.rank).min() ?? 1
            return ar != br ? ar < br : a.date != b.date ? a.date > b.date : a.id < b.id
        }
        var result = Self()
        result.tree = tree; result.runningIDs = running; result.runningCount = fresh && conflicting.isEmpty ? running.count : nil
        result.todayCount = active.count; result.todayProjects = Set(active.map { $0.project ?? "" }).count
        result.attention = attention
        return result
    }
}

struct DashboardDailyBucket: Identifiable, Sendable {
    let interval: DateInterval
    let tasks: Int
    let usage: DashboardUsage
    let covered: Bool
    let segment: Int
    var id: Date { interval.start }
}

struct DashboardCalendarCell: Identifiable, Sendable {
    let date: Date
    let bucket: DashboardDailyBucket?
    var id: Date { date }
}

struct DashboardAnalytics: Sendable {
    var buckets: [DashboardDailyBucket] = []
    var cells: [DashboardCalendarCell] = []
    var annualInterval: DateInterval?
    var usage = DashboardUsage()
    var taskCount = 0
    var activeDays = 0

    static func make(snapshot: HistorySnapshot, tree: DashboardFamilyTree, interval: DateInterval,
                     filter: DashboardFilter, weekly: Bool, now: Date, calendar input: Calendar) -> Self {
        var calendar = input; calendar.firstWeekday = 2; calendar.minimumDaysInFirstWeek = 4
        let reliable = !snapshot.historyUnavailable && !snapshot.metadataUnavailable && snapshot.unreadableFiles == 0
        let sampleStart = snapshot.tasks.flatMap(\.turns).flatMap(\.samples).map(\.date).min()
        let coverageStart = [snapshot.indexedRange?.start, sampleStart].compactMap { $0 }.min() ?? snapshot.updatedAt
        let rows = DashboardStatistics.rows(tasks: Array(tree.tasks.values), interval: interval, filter: filter, now: now)
        var usage = DashboardUsage.summarize(rows, in: interval, reliableEmpty: reliable)
        usage.sourceIncomplete = !reliable
        func buckets(_ range: DateInterval, unit: Calendar.Component) -> [DashboardDailyBucket] {
            var cursor = range.start, result: [DashboardDailyBucket] = [], segment = 0
            while cursor < range.end {
                let end = min(calendar.dateInterval(of: unit, for: cursor)!.end, range.end)
                let bucketRange = DateInterval(start: cursor, end: end)
                let rows = DashboardStatistics.rows(tasks: Array(tree.tasks.values), interval: bucketRange, filter: filter, now: now)
                let families = tree.families(rows: rows, interval: bucketRange)
                let covered = cursor <= now && (!rows.isEmpty || reliable && (coverageStart.map { $0 < end } ?? false))
                var usage = DashboardUsage.summarize(rows, in: bucketRange, reliableEmpty: covered)
                usage.sourceIncomplete = !reliable
                if usage.tokens == nil || usage.incomplete || !covered { segment += 1 }
                result.append(DashboardDailyBucket(interval: bucketRange, tasks: families.count, usage: usage, covered: covered, segment: segment))
                if usage.tokens == nil || usage.incomplete || !covered { segment += 1 }
                cursor = end
            }
            return result
        }
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        let annual = DateInterval(start: calendar.date(byAdding: .year, value: -1, to: end)!, end: end)
        let days = buckets(annual, unit: .day)
        let byDate = Dictionary(uniqueKeysWithValues: days.map { ($0.id, $0) })
        let gridStart = calendar.dateInterval(of: .weekOfYear, for: annual.start)!.start
        let gridEnd = calendar.dateInterval(of: .weekOfYear, for: annual.end.addingTimeInterval(-1))!.end
        var cursor = gridStart, cells: [DashboardCalendarCell] = []
        while cursor < gridEnd {
            cells.append(DashboardCalendarCell(date: cursor, bucket: byDate[cursor]))
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
        }
        return Self(buckets: buckets(interval, unit: weekly ? .weekOfYear : .day), cells: cells, annualInterval: annual,
                    usage: usage, taskCount: tree.families(rows: rows, interval: interval).count,
                    activeDays: buckets(interval, unit: .day).filter { $0.tasks > 0 }.count)
    }

    static func thresholds(_ values: [Int64]) -> [Int64] {
        let positive = values.filter { $0 > 0 }.sorted()
        guard !positive.isEmpty else { return [] }
        return Array(Set((1...5).map { positive[max(0, Int(ceil(Double(positive.count) * Double($0) / 5)) - 1)] })).sorted()
    }

    static func axisMaximum(_ value: Double) -> Double {
        guard value > 0, value.isFinite else { return 1 }
        let magnitude = pow(10, floor(log10(value)))
        return ceil(value / magnitude / 2) * 2 * magnitude
    }
}

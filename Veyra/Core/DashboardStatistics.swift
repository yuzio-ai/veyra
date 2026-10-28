import Foundation

struct DashboardTaskRow: Identifiable, Sendable {
    let task: HistoryTask
    let turns: [HistoryTurn]
    let elapsed: TimeInterval?
    let tokens: HistoryTokens
    var id: String { task.id }
}

struct DashboardMetrics: Sendable {
    var activeTasks = 0
    var subtasks = 0
    var activeDays = 0
    var normal = 0
    var failed = 0
    var interrupted = 0
    var unknown = 0
    var open = 0
    var elapsed: TimeInterval?
    var median: TimeInterval?
    var p90: TimeInterval?
    var tokens = HistoryTokens()
    var missingDuration = 0
    var missingTokens = 0
    var cachePercent: Double? {
        guard let input = tokens.input, input > 0, let cached = tokens.cachedInput, cached <= input else { return nil }
        return Double(cached) / Double(input) * 100
    }
}

struct DashboardBucket: Identifiable, Sendable {
    let interval: DateInterval
    let metrics: DashboardMetrics
    var id: Date { interval.start }
}

struct DashboardDistribution: Identifiable, Sendable {
    let id: String
    let executions: Int
    let elapsed: TimeInterval?
    let tokens: Int64?
}

struct DashboardReport: Sendable {
    let interval: DateInterval
    let metrics: DashboardMetrics
    let rows: [DashboardTaskRow]
    let buckets: [DashboardBucket]
    let previous: DashboardMetrics?
    let projects: [DashboardDistribution]
    let models: [DashboardDistribution]
    let sources: [DashboardDistribution]
}

enum DashboardStatistics {
    static func report(snapshot: HistorySnapshot, interval: DateInterval, period: DashboardPeriod,
                       filter: DashboardFilter = DashboardFilter(), now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> DashboardReport {
        let rows = rows(tasks: snapshot.tasks, interval: interval, filter: filter, now: now)
        var metrics = metrics(rows: rows, interval: interval, calendar: calendar)
        if rows.isEmpty && (snapshot.unreadableFiles > 0 || snapshot.metadataUnavailable || snapshot.historyUnavailable) {
            metrics.tokens = HistoryTokens(); metrics.elapsed = nil
        }
        let buckets = period.buckets(in: interval, calendar: calendar).map { bucket in
            let bucketRows = self.rows(tasks: snapshot.tasks, interval: bucket, filter: filter, now: now)
            var metrics = self.metrics(rows: bucketRows, interval: bucket, calendar: calendar)
            if bucketRows.isEmpty && (snapshot.unreadableFiles > 0 || snapshot.metadataUnavailable || snapshot.historyUnavailable) {
                metrics.tokens = HistoryTokens(); metrics.elapsed = nil
            }
            return DashboardBucket(interval: bucket, metrics: metrics)
        }
        var previous: DashboardMetrics?
        if let before = period.previousComparison(for: interval, now: now, calendar: calendar),
           let range = snapshot.indexedRange, range.start <= before.start,
           snapshot.unreadableFiles == 0, snapshot.malformedEvents == 0,
           !snapshot.metadataUnavailable, !snapshot.historyUnavailable, metrics.missingDuration == 0, metrics.missingTokens == 0 {
            let earlier = self.metrics(rows: self.rows(tasks: snapshot.tasks, interval: before, filter: filter, now: now), interval: before, calendar: calendar)
            if earlier.missingTokens == 0 && earlier.missingDuration == 0 { previous = earlier }
        }
        return DashboardReport(interval: interval, metrics: metrics, rows: rows, buckets: buckets, previous: previous,
            projects: distribution(rows: rows, interval: interval) { task, _ in task.project ?? L10n.text("Unknown project") },
            models: distribution(rows: rows, interval: interval) { _, turn in turn.model ?? L10n.text("Unknown model") },
            sources: distribution(rows: rows, interval: interval) { task, _ in task.source })
    }

    static func rows(tasks: [HistoryTask], interval: DateInterval, filter: DashboardFilter, now: Date) -> [DashboardTaskRow] {
        tasks.filter(filter.matches).compactMap { task in
            let turns = task.turns.filter { filter.matches($0) && $0.intersects(interval, now: now) }
            guard !turns.isEmpty else { return nil }
            let durations = turns.map { $0.elapsed(in: interval) }
            let elapsed = durations.contains(where: { $0 == nil }) ? nil : durations.compactMap { $0 }.reduce(0, +)
            return DashboardTaskRow(task: task, turns: turns, elapsed: elapsed, tokens: .sum(turns.map { tokens($0, in: interval) }))
        }.sorted {
            let a = $0.turns.compactMap { $0.endedAt ?? $0.observedAt ?? $0.startedAt }.max() ?? .distantPast
            let b = $1.turns.compactMap { $0.endedAt ?? $0.observedAt ?? $0.startedAt }.max() ?? .distantPast
            return a != b ? a > b : $0.id < $1.id
        }
    }

    static func tokens(_ turn: HistoryTurn, in interval: DateInterval) -> HistoryTokens {
        guard !turn.hasTokenGap, !turn.samples.isEmpty else { return HistoryTokens() }
        let samples = turn.samples.filter { interval.start <= $0.date && $0.date < interval.end }
        if samples.isEmpty { return HistoryTokens(TokenUsage(input: 0, output: 0, cachedInput: 0, total: 0)) }
        return .sum(samples.map(\.tokens))
    }

    static func resultCount(_ result: ExecutionResult, turns: [HistoryTurn], in interval: DateInterval) -> Int {
        turns.filter { turn in
            guard turn.result == result else { return false }
            if result == .completed || result == .failed || result == .interrupted {
                guard let end = turn.endedAt else { return false }
                return interval.start <= end && end < interval.end
            }
            return true
        }.count
    }

    static func metrics(rows: [DashboardTaskRow], interval: DateInterval, calendar: Calendar) -> DashboardMetrics {
        var result = DashboardMetrics()
        result.activeTasks = rows.filter { $0.task.parentID == nil }.count
        result.subtasks = rows.filter { $0.task.parentID != nil }.count
        let turns = rows.flatMap(\.turns)
        var days: Set<Date> = [], durations: [TimeInterval] = []
        for turn in turns {
            if let end = turn.endedAt, interval.start <= end, end < interval.end {
                switch turn.result {
                case .completed: result.normal += 1
                case .failed: result.failed += 1
                case .interrupted: result.interrupted += 1
                case .unknown: result.unknown += 1
                case .running: break
                }
                if let duration = turn.duration { durations.append(duration) }
            } else if turn.result == .unknown { result.unknown += 1 }
            if turn.result == .running { result.open += 1 }
            if turn.elapsed(in: interval) == nil { result.missingDuration += 1 }
            if tokens(turn, in: interval).total == nil { result.missingTokens += 1 }
            if let start = turn.startedAt, let end = turn.endedAt, end >= start {
                var date = max(start, interval.start)
                let stop = min(end, interval.end)
                while date < stop {
                    let day = calendar.startOfDay(for: date); days.insert(day)
                    guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > date else { break }
                    date = next
                }
            }
            for date in [turn.startedAt, turn.endedAt, turn.observedAt].compactMap({ $0 })
                + turn.samples.map(\.date) where interval.start <= date && date < interval.end {
                days.insert(calendar.startOfDay(for: date))
            }
        }
        result.activeDays = days.count
        result.elapsed = rows.contains(where: { $0.elapsed == nil }) ? nil : rows.compactMap(\.elapsed).reduce(0, +)
        result.tokens = .sum(rows.map(\.tokens))
        if rows.isEmpty { result.tokens = HistoryTokens(TokenUsage(input: 0, output: 0, cachedInput: 0, total: 0)) }
        durations.sort()
        if !durations.isEmpty {
            let middle = durations.count / 2
            result.median = durations.count.isMultiple(of: 2) ? (durations[middle - 1] + durations[middle]) / 2 : durations[middle]
            result.p90 = durations[max(0, Int(ceil(Double(durations.count) * 0.9)) - 1)]
        }
        return result
    }

    private static func distribution(rows: [DashboardTaskRow], interval: DateInterval,
                                     group: (HistoryTask, HistoryTurn) -> String) -> [DashboardDistribution] {
        var groups: [String: [HistoryTurn]] = [:]
        for row in rows { for turn in row.turns { groups[group(row.task, turn), default: []].append(turn) } }
        return groups.map { key, turns in
            let elapsed = turns.map { $0.elapsed(in: interval) }
            return DashboardDistribution(id: key, executions: turns.count,
                elapsed: elapsed.contains(where: { $0 == nil }) ? nil : elapsed.compactMap { $0 }.reduce(0, +),
                tokens: HistoryTokens.sum(turns.map { tokens($0, in: interval) }).total)
        }.sorted { $0.executions != $1.executions ? $0.executions > $1.executions : $0.id < $1.id }
    }
}

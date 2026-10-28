import Foundation

enum ExecutionResult: String, Codable, CaseIterable, Sendable {
    case completed, failed, interrupted, running, unknown

    var label: String {
        switch self {
        case .completed: L10n.text("Ended normally")
        case .failed: L10n.text("Failed")
        case .interrupted: L10n.text("Interrupted")
        case .running: L10n.text("Open execution")
        case .unknown: L10n.text("Unknown result")
        }
    }
}

struct HistoryTokens: Codable, Equatable, Sendable {
    var input: Int64?
    var output: Int64?
    var cachedInput: Int64?
    var total: Int64?

    init(_ usage: TokenUsage = TokenUsage()) {
        input = usage.input; output = usage.output
        cachedInput = usage.cachedInput; total = usage.total
    }

    static func difference(_ next: Self, _ previous: Self) -> Self {
        func subtract(_ a: Int64?, _ b: Int64?) -> Int64? {
            guard let a, let b, a >= b else { return nil }
            return a - b
        }
        var result = Self()
        result.input = subtract(next.input, previous.input)
        result.output = subtract(next.output, previous.output)
        result.cachedInput = subtract(next.cachedInput, previous.cachedInput)
        result.total = subtract(next.total, previous.total)
        return result
    }

    static func sum(_ values: [Self]) -> Self {
        func sum(_ key: KeyPath<Self, Int64?>) -> Int64? {
            guard !values.isEmpty else { return nil }
            var total: Int64 = 0
            for item in values {
                guard let value = item[keyPath: key] else { return nil }
                let next = total.addingReportingOverflow(value)
                guard !next.overflow else { return nil }
                total = next.partialValue
            }
            return total
        }
        var result = Self()
        result.input = sum(\.input); result.output = sum(\.output)
        result.cachedInput = sum(\.cachedInput); result.total = sum(\.total)
        return result
    }
}

struct HistoryTokenSample: Codable, Equatable, Sendable {
    let id: String
    let date: Date
    let tokens: HistoryTokens
}

struct HistoryTurn: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var startedAt: Date?
    var endedAt: Date?
    var observedAt: Date?
    var result: ExecutionResult = .unknown
    var model: String?
    var samples: [HistoryTokenSample] = []
    var hasTokenGap = false
    var sourceAvailable = true

    var duration: TimeInterval? {
        guard let startedAt, let endedAt, endedAt >= startedAt else { return nil }
        return endedAt.timeIntervalSince(startedAt)
    }

    func intersects(_ interval: DateInterval, now: Date) -> Bool {
        if let start = startedAt {
            let end = endedAt ?? (result == .running ? max(start, observedAt ?? start) : start)
            if start < interval.end && end > interval.start { return true }
            if interval.start <= start && start < interval.end { return true }
        }
        return [endedAt, observedAt].compactMap { $0 }.contains { interval.start <= $0 && $0 < interval.end }
            || samples.contains { interval.start <= $0.date && $0.date < interval.end }
    }

    func elapsed(in interval: DateInterval) -> TimeInterval? {
        guard let startedAt, let endedAt, endedAt >= startedAt else { return nil }
        return max(0, min(endedAt, interval.end).timeIntervalSince(max(startedAt, interval.start)))
    }

    func tokens(in interval: DateInterval) -> HistoryTokens {
        guard !hasTokenGap else { return HistoryTokens() }
        return .sum(samples.filter { interval.start <= $0.date && $0.date < interval.end }.map(\.tokens))
    }
}

struct HistoryTask: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var title: String
    var project: String?
    var source: String
    var parentID: String?
    var archived: Bool = false
    var sourceAvailable = true
    var turns: [HistoryTurn] = []
}

struct HistorySnapshot: Sendable {
    var tasks: [HistoryTask] = []
    var updatedAt: Date?
    var unreadableFiles = 0
    var malformedEvents = 0
    var historyUnavailable = false
    var metadataUnavailable = false
    var scannedFiles = 0
    var totalFiles = 0
    var bytesRead = 0
    var indexedRange: DateInterval? {
        let dates = tasks.flatMap(\.turns).flatMap { [$0.startedAt, $0.endedAt, $0.observedAt].compactMap { $0 } }
        guard let first = dates.min(), let last = dates.max() else { return nil }
        return DateInterval(start: first, end: last)
    }
}

enum DashboardPeriod: String, CaseIterable, Sendable {
    case day, week, month, year, custom

    var label: String {
        switch self {
        case .day: L10n.text("Day")
        case .week: L10n.text("Week")
        case .month: L10n.text("Month")
        case .year: L10n.text("Year")
        case .custom: L10n.text("Custom range")
        }
    }

    var component: Calendar.Component {
        switch self {
        case .day, .custom: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
    }

    func interval(containing date: Date, calendar: Calendar) -> DateInterval {
        var calendar = calendar
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar.dateInterval(of: component, for: date)!
    }

    func buckets(in interval: DateInterval, calendar: Calendar) -> [DateInterval] {
        let unit: Calendar.Component = self == .day ? .hour : self == .year ? .month : .day
        var result: [DateInterval] = [], start = interval.start
        while start < interval.end {
            guard let next = calendar.dateInterval(of: unit, for: start)?.end, next > start else { break }
            let end = min(next, interval.end)
            result.append(DateInterval(start: start, end: end)); start = end
        }
        return result
    }

    func previousComparison(for interval: DateInterval, now: Date, calendar: Calendar) -> DateInterval? {
        guard self != .custom,
              let anchor = calendar.date(byAdding: component, value: -1, to: interval.start) else { return nil }
        let previous = self.interval(containing: anchor, calendar: calendar)
        let elapsed = min(interval.duration, max(0, now.timeIntervalSince(interval.start)))
        guard elapsed > 0, elapsed <= previous.duration else { return nil }
        return DateInterval(start: previous.start, duration: elapsed)
    }
}

struct DashboardFilter: Equatable, Sendable {
    var search = ""
    var project: String?
    var model: String?
    var source: String?
    var result: ExecutionResult?

    func matches(_ task: HistoryTask) -> Bool {
        (search.isEmpty || task.title.localizedCaseInsensitiveContains(search))
            && (project == nil || task.project == project)
            && (source == nil || task.source == source)
    }

    func matches(_ turn: HistoryTurn) -> Bool {
        (model == nil || turn.model == model) && (result == nil || turn.result == result)
    }
}

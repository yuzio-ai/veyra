import Foundation

/// One event is one complete bucket snapshot. Missing windows never inherit old values.
/// The session model is kept alongside: token_count events report the limit
/// governing the request under a generic limit_id, so the model is the only
/// local signal identifying the model family the bucket belongs to.
struct LocalQuotaBucket: Equatable, Sendable {
    let id: String
    let windows: [QuotaWindow]
    let recordedAt: Date
    let model: String?

    init(id: String, windows: [QuotaWindow], recordedAt: Date, model: String? = nil) {
        self.id = id
        self.windows = windows
        self.recordedAt = recordedAt
        self.model = model
    }

    static func parse(_ value: JSONValue, at date: Date, model: String? = nil) -> LocalQuotaBucket? {
        guard value.object != nil else { return nil }
        let id = value["limit_id"].string.flatMap { $0.isEmpty ? nil : $0 } ?? "codex"
        let name = value["limit_name"].string ?? (id == "codex" ? "Codex" : id)
        let windows = ["primary", "secondary"].compactMap { kind -> QuotaWindow? in
            let window = value[kind]
            guard window.object != nil else { return nil }
            return QuotaWindow(id: "\(id):\(kind)", bucketID: id, bucketName: name, isPrimary: kind == "primary",
                               usedPercent: window["used_percent"].double,
                               durationMinutes: window["window_minutes"].integer,
                               resetsAt: window["resets_at"].double.map(Date.init(timeIntervalSince1970:)))
        }
        return LocalQuotaBucket(id: id, windows: windows, recordedAt: date, model: model)
    }

    static func snapshot(_ buckets: [String: LocalQuotaBucket]) -> QuotaSnapshot? {
        guard let latest = buckets.values.map(\.recordedAt).max() else { return nil }
        let ordered = buckets.values.sorted {
            if ($0.id == "codex") != ($1.id == "codex") { return $0.id == "codex" }
            return $0.id < $1.id
        }
        return QuotaSnapshot(windows: ordered.flatMap(\.windows), fetchedAt: latest, accountID: nil,
                             source: .local, bucketDates: buckets.mapValues(\.recordedAt),
                             bucketModels: buckets.compactMapValues(\.model))
    }
}

/// Extract only bounded, structured transport metadata; never retain backend message/data.
struct QuotaFailureDetails: Error, Equatable, Sendable {
    let category: QuotaFailure
    let rpcCode: Int64?
    let httpStatus: Int?
    let retryAfter: TimeInterval?

    init(rpcError: JSONValue) {
        rpcCode = rpcError["code"].integer
        let rawStatus = rpcError["data"]["status"].integer ?? rpcError["data"]["statusCode"].integer
            ?? rpcError["data"]["httpStatus"].integer ?? rpcError["data"]["http_status"].integer
        httpStatus = rawStatus.flatMap { (100...599).contains($0) ? Int($0) : nil }
        let rawRetry = rpcError["data"]["retryAfterSeconds"].double ?? rpcError["data"]["retry_after_seconds"].double
        retryAfter = rawRetry.flatMap { $0.isFinite && $0 >= 0 ? min($0, 31_536_000) : nil }
        switch httpStatus {
        case 429: category = .rateLimited
        case 401, 403: category = .unauthorized
        case .some(let code) where code >= 500: category = .serviceUnavailable
        default: category = .rpcFailed
        }
    }
}

struct QuotaCalibrationPolicy: Sendable {
    private(set) var nextAllowedAt: Date?
    private(set) var failures = 0

    func allowsRequest(at now: Date) -> Bool { nextAllowedAt.map { now >= $0 } ?? true }
    mutating func began(at now: Date) { nextAllowedAt = now.addingTimeInterval(60) }
    mutating func finished(_ result: QuotaRefresh, startedAt: Date, now: Date) {
        guard result.didRequestQuota else { nextAllowedAt = nil; return }
        if result.error == nil {
            failures = 0
            nextAllowedAt = startedAt.addingTimeInterval(60)
        } else {
            failures += 1
            let delays: [TimeInterval] = [300, 900, 1800]
            let delay = max(delays[min(failures - 1, 2)], result.failureDetails?.retryAfter ?? 0)
            nextAllowedAt = now.addingTimeInterval(delay)
        }
    }
}

struct TaskReadMetrics: Equatable, Sendable {
    var metadataQueries = 0
    var historyQueries = 0
    var rolloutBytes = 0
    var rolloutOpens = 0
    var processCollections = 0
}

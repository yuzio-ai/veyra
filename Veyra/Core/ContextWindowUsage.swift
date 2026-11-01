import Foundation

/// A single reported snapshot, never cumulative session usage or a model-name estimate.
struct ContextWindowUsage: Equatable, Sendable {
    let used: Int64
    let window: Int64
    var recordedAt: Date?

    var percent: Double { Double(used) / Double(window) * 100 }

    init?(used: Int64, window: Int64, recordedAt: Date? = nil) {
        guard used >= 0, window > 0 else { return nil }
        self.used = used; self.window = window; self.recordedAt = recordedAt
    }

    init?(info: JSONValue, recordedAt: Date?) {
        guard let used = RecordedCount.value(info["last_token_usage"]["total_tokens"]),
              let window = RecordedCount.value(info["model_context_window"]) else { return nil }
        self.init(used: used, window: window, recordedAt: recordedAt)
    }
}

/// JSONValue.integer is intentionally permissive; measured counts/times must be integers.
enum RecordedCount {
    static func value(_ json: JSONValue) -> Int64? {
        guard let number = json.double, number >= 0,
              number.rounded(.towardZero) == number else { return nil }
        return json.integer
    }
}

/// Handles both reverse cold reads and chronological appended records. A missing/invalid
/// latest snapshot is authoritative; it must never resurrect an older usable value.
struct RolloutContext: Sendable {
    private var snapshot: ContextWindowUsage?
    private var model: String?
    private var sawSnapshotOrReset = false
    private var newerModels: Set<String> = []
    private var pendingModelMatch = false

    var usage: ContextWindowUsage? { pendingModelMatch ? nil : snapshot }
    var needsEarlierModel: Bool { pendingModelMatch }

    mutating func apply(_ event: JSONValue, newestFirst: Bool) {
        let payload = event["payload"]
        if event["type"].string == "turn_context", let nextModel = payload["model"].string {
            if newestFirst {
                if model == nil { model = nextModel }
                if !sawSnapshotOrReset { newerModels.insert(nextModel) }
                else if pendingModelMatch {
                    if newerModels.contains(where: { $0 != nextModel }) { snapshot = nil }
                    pendingModelMatch = false
                }
            } else {
                // If an old log had no model identity, the first explicit model is
                // also a boundary: its earlier snapshot cannot be attributed safely.
                if model != nextModel { snapshot = nil }
                model = nextModel
            }
            return
        }
        let kind = payload["type"].string
        let isReset = event["type"].string == "compacted"
            || (event["type"].string == "event_msg" && (kind == "context_compacted"
                || (kind == "item_completed" && payload["item"]["type"].string == "ContextCompaction")))
        if isReset {
            if !newestFirst || !sawSnapshotOrReset {
                snapshot = nil; sawSnapshotOrReset = true; pendingModelMatch = false
            }
            return
        }
        guard event["type"].string == "event_msg", kind == "token_count",
              payload["info"].object != nil else { return } // quota-only updates are not snapshots
        if !newestFirst || !sawSnapshotOrReset {
            snapshot = ContextWindowUsage(info: payload["info"],
                                          recordedAt: RolloutEvent.timestamp(event["timestamp"].string))
            sawSnapshotOrReset = true
            pendingModelMatch = newestFirst && snapshot != nil && !newerModels.isEmpty
        }
    }
}

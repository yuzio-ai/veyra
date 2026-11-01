import Foundation

struct TaskSessionStatistics: Equatable, Sendable {
    var toolMilliseconds: Double?
    var meanTTFTMilliseconds: Double?
    var ttftSampleCount: Int64 = 0
    var historyUnreadable = false
}

/// Stores only identifiers and timing. Tool intervals are unioned across the session;
/// nested wrappers and parallel calls therefore cannot count the same wait twice.
struct TaskSessionLedger: Sendable {
    private struct ItemKey: Hashable, Sendable {
        let turn: String
        let item: String
    }
    private struct Interval: Sendable {
        let start: Int64
        let end: Int64
    }
    private enum TurnOwner: Equatable, Sendable {
        case confirmed(String), conflicted
    }
    let threadID: String
    private var tools: [ItemKey: Interval] = [:]
    private var owners: [String: TurnOwner] = [:]
    private var ttft: [String: Int64] = [:]
    private var unreadable = false
    private static let eventKinds: Set<String> = ["item_started", "item_completed", "task_complete", "task_completed",
                                                "turn_complete", "turn_aborted", "task_failed", "turn_failed"]
    private static let markers = eventKinds.map { Data($0.utf8) }
    private static let toolTypes: Set<String> = [
        "CommandExecution", "McpToolCall", "DynamicToolCall", "FileChange", "CollabAgentToolCall",
        "WebSearch", "ImageView", "ImageGeneration", "Extension"
    ]

    mutating func apply(_ line: Data) {
        guard Self.markers.contains(where: { line.range(of: $0) != nil }) else { return }
        guard let event = try? JSONValue.decode(line) else { unreadable = true; return }
        guard event["type"].string == "event_msg" else { return }
        let payload = event["payload"]
        guard let turn = TaskText.nonempty(payload["turn_id"].string) else { return }
        guard let kind = payload["type"].string, Self.eventKinds.contains(kind) else { return }
        let recordedThread = TaskText.nonempty(payload["thread_id"].string)
        if let recordedThread {
            let owner = TurnOwner.confirmed(recordedThread)
            if let previous = owners[turn], previous != owner { owners[turn] = .conflicted }
            else { owners[turn] = owner }
        }
        if ["task_complete", "task_completed", "turn_complete"].contains(kind) {
            // Keep the latest terminal result even before ownership is known. A fork
            // can copy completions without thread_id, so membership is checked in result().
            ttft[turn] = payload["error"] == .null ? RecordedCount.value(payload["time_to_first_token_ms"]) : nil
        } else if ["turn_aborted", "task_failed", "turn_failed"].contains(kind) {
            ttft.removeValue(forKey: turn)
        } else if kind == "item_completed" {
            guard recordedThread == nil || recordedThread == threadID else { return }
            let item = payload["item"]
            guard let type = item["type"].string, Self.toolTypes.contains(type),
                  let id = TaskText.nonempty(item["id"].string) else { return }
            let key = ItemKey(turn: turn, item: id)
            tools.removeValue(forKey: key)
            guard item["status"].string != "in_progress", item["status"].string != "inProgress",
                  let start = RecordedCount.value(payload["started_at_ms"]), start > 0,
                  let end = RecordedCount.value(payload["completed_at_ms"]), end >= start else { return }
            tools[key] = Interval(start: start, end: end)
        }
    }

    func result() -> TaskSessionStatistics {
        let intervals = tools.values.sorted { $0.start < $1.start }
        var merged: Interval?
        var milliseconds = 0.0
        for interval in intervals {
            if let current = merged {
                if interval.start <= current.end {
                    merged = Interval(start: current.start, end: max(current.end, interval.end))
                } else {
                    milliseconds += Double(current.end - current.start)
                    merged = interval
                }
            } else { merged = interval }
        }
        if let merged { milliseconds += Double(merged.end - merged.start) }
        let samples = ttft.filter { owners[$0.key] == .confirmed(threadID) }.values
        return TaskSessionStatistics(toolMilliseconds: intervals.isEmpty ? nil : milliseconds,
            meanTTFTMilliseconds: samples.isEmpty ? nil : samples.reduce(0.0) { $0 + Double($1) } / Double(samples.count),
            ttftSampleCount: Int64(samples.count), historyUnreadable: unreadable)
    }
}

/// Independent from the polling tail reader. Called only from an expanded disclosure.
actor TaskSessionStatisticsReader {
    static let shared = TaskSessionStatisticsReader()

    private struct Key: Hashable { let url: URL; let threadID: String }
    private struct Cursor {
        let identity: String
        var offset: UInt64 = 0
        var modified: Date?
        var partial = Data()
        var ledger: TaskSessionLedger
        var statistics = TaskSessionStatistics()
        var access: UInt64 = 0
    }
    private var cursors: [Key: Cursor] = [:]
    private var access: UInt64 = 0
    private(set) var lastReadByteCount = 0
    private(set) var lastOpenCount = 0

    func read(url: URL, threadID: String) throws -> TaskSessionStatistics {
        lastReadByteCount = 0; lastOpenCount = 0
        try Task.checkCancellation()
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let identity = "\(attributes[.systemNumber] ?? 0):\(attributes[.systemFileNumber] ?? 0)"
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = attributes[.modificationDate] as? Date
        let key = Key(url: url, threadID: threadID)
        var cursor = cursors[key].flatMap {
            $0.identity == identity && size >= $0.offset && !(size == $0.offset && modified != $0.modified) ? $0 : nil
        } ?? Cursor(identity: identity, ledger: TaskSessionLedger(threadID: threadID))
        if size > cursor.offset {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            lastOpenCount = 1
            try file.seek(toOffset: cursor.offset)
            while cursor.offset < size {
                try Task.checkCancellation()
                let data = try file.read(upToCount: Int(min(256 * 1_024, size - cursor.offset))) ?? Data()
                guard !data.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                cursor.offset += UInt64(data.count); lastReadByteCount += data.count
                let retainedCount = cursor.partial.count
                cursor.partial.append(data)
                var start = cursor.partial.startIndex
                var searchStart = cursor.partial.index(start, offsetBy: retainedCount)
                while searchStart < cursor.partial.endIndex {
                    let newline = cursor.partial[searchStart...].firstIndex(of: 0x0a)
                    guard let newline else { break }
                    try Task.checkCancellation()
                    cursor.ledger.apply(Data(cursor.partial[start..<newline]))
                    start = cursor.partial.index(after: newline); searchStart = start
                }
                cursor.partial.removeSubrange(..<start)
            }
        }
        if lastReadByteCount > 0 { cursor.statistics = cursor.ledger.result() }
        try Task.checkCancellation()
        access &+= 1; cursor.access = access; cursor.modified = modified
        cursors[key] = cursor
        if cursors.count > 32, let oldest = cursors.min(by: { $0.value.access < $1.value.access })?.key {
            cursors.removeValue(forKey: oldest)
        }
        return cursor.statistics
    }
}

enum TaskSessionText {
    static func basedOn(_ turns: Int64) -> String { L10n.text("Based on \(turns) turns") }

    static func duration(_ milliseconds: Double?) -> String {
        guard let milliseconds, milliseconds.isFinite, milliseconds >= 0 else { return "—" }
        if milliseconds < 60_000 {
            let seconds = (milliseconds / 1_000).formatted(.number
                .locale(L10n.languageOverride.map(Locale.init(identifier:)) ?? .current).precision(.fractionLength(1)))
            return L10n.text("\(seconds) seconds")
        }
        return DisplayFormat.duration(since: Date(timeIntervalSince1970: 0),
                                      now: Date(timeIntervalSince1970: milliseconds / 1_000))
    }
}

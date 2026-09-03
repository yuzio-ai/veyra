import Foundation

struct TurnBoundary: Equatable, Sendable {
    let turnID: String?
    let isRunning: Bool
    let date: Date?
}

struct RolloutState: Sendable {
    var usage: TokenUsage?
    var usageDate: Date?
    var boundary: TurnBoundary?
    var model: String?
    var quotaBuckets: [String: LocalQuotaBucket] = [:]
    var display = RolloutDisplay()
}

/// Lifecycle/token data plus explicitly public progress; never reasoning or tool output.
enum RolloutEvent {
    static func apply(_ line: Data, to state: inout RolloutState, newestFirst: Bool = false) {
        guard let event = try? JSONValue.decode(line) else { return }
        state.display.apply(event, newestFirst: newestFirst)
        let payload = event["payload"]
        if event["type"].string == "turn_context" {
            if !newestFirst || state.model == nil { state.model = payload["model"].string ?? state.model }
            return
        }
        guard event["type"].string == "event_msg" else { return }
        let kind = payload["type"].string
        let tokenDate = kind == "token_count" ? timestamp(event["timestamp"].string) : nil
        if kind == "token_count", let date = tokenDate,
           let bucket = LocalQuotaBucket.parse(payload["rate_limits"], at: date),
           state.quotaBuckets[bucket.id].map({ $0.recordedAt < date }) ?? true {
            state.quotaBuckets[bucket.id] = bucket
        }
        if kind == "token_count", payload["info"]["total_token_usage"].object != nil {
            if !newestFirst || state.usage == nil {
                state.usage = TokenUsage(json: payload["info"]["total_token_usage"])
                state.usageDate = tokenDate
            }
        }
        if ["task_started", "task_complete", "task_completed", "turn_aborted", "task_failed", "turn_failed"].contains(kind) {
            if !newestFirst || state.boundary == nil {
                state.boundary = TurnBoundary(turnID: payload["turn_id"].string, isRunning: kind == "task_started",
                                              date: timestamp(event["timestamp"].string))
            }
        }
    }
    static func timestamp(_ value: String?) -> Date? {
        guard let value else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: value) { return date }
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: value)
    }
}

struct RolloutReader {
    private struct Cursor {
        var identity: String
        var offset: UInt64
        var modified: Date?
        var partial: Data
        var state: RolloutState
        var didReachStart: Bool
    }
    private var cursors: [String: Cursor] = [:]
    private let chunkSize = 256 * 1_024
    private(set) var lastReadByteCount = 0
    private(set) var lastOpenCount = 0

    mutating func read(_ url: URL, requireBoundary: Bool = true, quotaOnly: Bool = false) throws -> RolloutState {
        lastReadByteCount = 0
        lastOpenCount = 0
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let identity = "\(attributes[.systemNumber] ?? 0):\(attributes[.systemFileNumber] ?? 0)"
        let modified = attributes[.modificationDate] as? Date
        if var cursor = cursors[url.path], cursor.identity == identity, size >= cursor.offset,
           (quotaOnly || cursor.didReachStart || hasRequiredFields(cursor.state, requireBoundary: requireBoundary)),
           !(size == cursor.offset && modified != cursor.modified) {
            if size > cursor.offset {
                let file = try FileHandle(forReadingFrom: url)
                lastOpenCount = 1
                defer { try? file.close() }
                try file.seek(toOffset: cursor.offset)
                var remaining = size - cursor.offset
                while remaining > 0 {
                    let data = try file.read(upToCount: Int(min(UInt64(chunkSize), remaining))) ?? Data()
                    lastReadByteCount += data.count
                    if data.isEmpty { break }
                    remaining -= UInt64(data.count); cursor.offset += UInt64(data.count)
                    cursor.partial.append(data)
                    consumeLines(from: &cursor.partial, state: &cursor.state)
                }
            }
            cursor.modified = modified
            cursors[url.path] = cursor
            return cursor.state
        }
        let file = try FileHandle(forReadingFrom: url)
        lastOpenCount = 1
        defer { try? file.close() }
        var state = RolloutState(), carry = Data(), partial = Data()
        if let cursor = cursors[url.path], cursor.identity == identity, size >= cursor.offset,
           !(size == cursor.offset && modified != cursor.modified) {
            state.quotaBuckets = cursor.state.quotaBuckets
        }
        var position = size
        var firstChunk = true
        while position > 0 {
            let start = position > UInt64(chunkSize) ? position - UInt64(chunkSize) : 0
            try file.seek(toOffset: start)
            var data = try file.read(upToCount: Int(position - start)) ?? Data()
            lastReadByteCount += data.count
            data.append(carry)
            var parts: [Data] = data.split(separator: UInt8(0x0a), omittingEmptySubsequences: false).map { Data($0) }
            if firstChunk {
                partial = parts.removeLast()
                firstChunk = false
            }
            carry = parts.isEmpty ? Data() : parts.removeFirst()
            for line in parts.reversed() { RolloutEvent.apply(line, to: &state, newestFirst: true) }
            if start == 0 { RolloutEvent.apply(carry, to: &state, newestFirst: true) }
            position = start
            if quotaOnly || hasRequiredFields(state, requireBoundary: requireBoundary) { break }
        }
        cursors[url.path] = Cursor(identity: identity, offset: size, modified: modified, partial: partial,
                                   state: state, didReachStart: position == 0)
        return state
    }

    private func hasRequiredFields(_ state: RolloutState, requireBoundary: Bool) -> Bool {
        state.usage != nil && state.model != nil && (!requireBoundary || state.boundary != nil)
    }

    private func consumeLines(from data: inout Data, state: inout RolloutState) {
        while let newline = data.firstIndex(of: 0x0a) {
            RolloutEvent.apply(Data(data[..<newline]), to: &state)
            data.removeSubrange(...newline)
        }
    }
    mutating func keepOnly(paths: Set<String>) { cursors = cursors.filter { paths.contains($0.key) } }
}

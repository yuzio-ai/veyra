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
    var display = RolloutDisplay()
    var context = RolloutContext()
    var modifiedAt: Date?
}

/// Lifecycle/token data plus explicitly public progress; never reasoning or tool output.
enum RolloutEvent {
    static func apply(_ line: Data, to state: inout RolloutState, newestFirst: Bool = false) {
        guard let event = try? JSONValue.decode(line) else { return }
        state.display.apply(event, newestFirst: newestFirst)
        state.context.apply(event, newestFirst: newestFirst)
        let payload = event["payload"]
        if event["type"].string == "turn_context" {
            let model = payload["model"].string
            if !newestFirst || state.model == nil { state.model = model ?? state.model }
            return
        }
        guard event["type"].string == "event_msg" else { return }
        let kind = payload["type"].string
        if kind == "token_count", payload["info"]["total_token_usage"].object != nil {
            if !newestFirst || state.usage == nil {
                state.usage = TokenUsage(json: payload["info"]["total_token_usage"])
                state.usageDate = timestamp(event["timestamp"].string)
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

    mutating func read(_ url: URL, requireBoundary: Bool = true) throws -> RolloutState {
        lastReadByteCount = 0
        lastOpenCount = 0
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let identity = "\(attributes[.systemNumber] ?? 0):\(attributes[.systemFileNumber] ?? 0)"
        let modified = attributes[.modificationDate] as? Date
        let previous: Cursor? = cursors[url.path].flatMap { cursor in
            guard cursor.identity == identity, size >= cursor.offset,
                  !(size == cursor.offset && modified != cursor.modified) else { return nil }
            return cursor
        }
        if var cursor = previous,
           cursor.didReachStart || hasRequiredFields(cursor.state, requireBoundary: requireBoundary) {
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
            cursor.state.modifiedAt = modified
            cursors[url.path] = cursor
            return cursor.state
        }
        let file = try FileHandle(forReadingFrom: url)
        lastOpenCount = 1
        defer { try? file.close() }
        var state = RolloutState(), partial = Data(), fragments: [Data] = []
        var position = size
        var collectingPartial = true
        while position > 0 {
            let start = position > UInt64(chunkSize) ? position - UInt64(chunkSize) : 0
            try file.seek(toOffset: start)
            let data = try file.read(upToCount: Int(position - start)) ?? Data()
            lastReadByteCount += data.count
            let parts = data.split(separator: UInt8(0x0a), omittingEmptySubsequences: false)
            // A newline closes the line to its right in a reverse scan. Keep
            // fragments in scan order and assemble only when its start is known.
            for part in parts.dropFirst().reversed() {
                fragments.append(Data(part))
                let line = joinBackwardFragments(&fragments)
                if collectingPartial { partial = line; collectingPartial = false }
                else { RolloutEvent.apply(line, to: &state, newestFirst: true) }
            }
            if let first = parts.first { fragments.append(Data(first)) }
            if start == 0 {
                let line = joinBackwardFragments(&fragments)
                if collectingPartial { partial = line; collectingPartial = false }
                else { RolloutEvent.apply(line, to: &state, newestFirst: true) }
            }
            position = start
            if hasRequiredFields(state, requireBoundary: requireBoundary) { break }
        }
        state.modifiedAt = modified
        cursors[url.path] = Cursor(identity: identity, offset: size, modified: modified, partial: partial,
                                   state: state, didReachStart: position == 0)
        return state
    }

    private func hasRequiredFields(_ state: RolloutState, requireBoundary: Bool) -> Bool {
        state.usage != nil && state.model != nil && !state.context.needsEarlierModel
            && (!requireBoundary || state.boundary != nil)
    }

    private func joinBackwardFragments(_ fragments: inout [Data]) -> Data {
        if fragments.count == 1 { return fragments.removeLast() }
        var line = Data()
        line.reserveCapacity(fragments.reduce(0) { $0 + $1.count })
        for fragment in fragments.reversed() { line.append(fragment) }
        fragments.removeAll(keepingCapacity: true)
        return line
    }

    private func consumeLines(from data: inout Data, state: inout RolloutState) {
        while let newline = data.firstIndex(of: 0x0a) {
            RolloutEvent.apply(Data(data[..<newline]), to: &state)
            data.removeSubrange(...newline)
        }
    }
    mutating func keepOnly(paths: Set<String>) { cursors = cursors.filter { paths.contains($0.key) } }
}

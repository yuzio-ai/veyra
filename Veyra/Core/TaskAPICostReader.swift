import Foundation

/// Keeps only model identifiers and numeric usage. No messages, tools, or reasoning are retained.
struct TaskAPICostLedger: Sendable {
    private(set) var estimate = TaskAPICostEstimate()
    private(set) var latestUsage: TokenUsage?
    private var model: String?
    private var baseline: TaskCostTokens?
    private var sawUsage = false

    /// A rollout is mostly message and tool payloads, and JSON-decoding every
    /// one of them would dominate the first disclosure of a long session. Only
    /// these two record kinds can change the estimate; everything else is
    /// skipped before parsing, not after.
    private static let relevantMarkers = [Data("turn_context".utf8), Data(#"total_token_usage"#.utf8)]

    mutating func apply(_ line: Data) {
        guard !line.isEmpty else { return }
        guard Self.relevantMarkers.contains(where: { line.range(of: $0) != nil }) else { return }
        guard let event = try? JSONValue.decode(line) else {
            estimate.note(.historyUnreadable)
            model = nil; baseline = nil; sawUsage = true
            return
        }
        let payload = event["payload"]
        if event["type"].string == "turn_context" {
            model = TaskText.nonempty(payload["model"].string)
            return
        }
        guard event["type"].string == "event_msg", payload["type"].string == "token_count",
              let object = payload["info"]["total_token_usage"].object else { return }
        let usage = TokenUsage(json: .object(object))
        latestUsage = usage
        // JSONValue's general integer accessor tolerates fractional numbers;
        // money calculations require actual nonnegative integer counts.
        let countKeys = ["input_tokens", "cached_input_tokens", "output_tokens", "total_tokens", "reasoning_output_tokens"]
        let integers = countKeys.allSatisfy { key in
            guard let value = object[key] else { return true }
            guard let number = value.double else { return false }
            return number >= 0 && number.rounded(.towardZero) == number && value.integer != nil
        }
        guard integers, let current = TaskCostTokens(usage: usage) else {
            estimate.note(.invalidUsage); baseline = nil; sawUsage = true
            return
        }
        defer { baseline = current; sawUsage = true }
        let previous = baseline ?? (sawUsage ? nil : .zero)
        guard let previous else { estimate.note(.invalidUsage); return }
        // A genuine counter reset starts a new unknown baseline. Discard the old
        // estimate so it cannot exceed the currently displayed cumulative usage.
        if current.input < previous.input || current.output < previous.output || current.cached < previous.cached {
            estimate = TaskAPICostEstimate(issues: [.counterReset])
            return
        }
        guard let delta = current.difference(from: previous) else { estimate.note(.invalidUsage); return }
        if delta == .zero && sawUsage { return }
        estimate.add(delta, model: model)
    }

    func result(expected: TokenUsage?) -> TaskAPICostEstimate {
        if let expected, let latestUsage,
           expected.input != latestUsage.input || expected.cachedInput != latestUsage.cachedInput
            || expected.output != latestUsage.output || expected.total != latestUsage.total {
            return TaskAPICostEstimate(issues: [.outOfDate])
        }
        var result = estimate
        if !sawUsage { result.note(.missingUsage) }
        return result
    }
}

/// Separate from the monitoring tail reader: history is scanned only on disclosure.
actor TaskAPICostReader {
    static let shared = TaskAPICostReader()

    private struct Cursor {
        var identity: String
        var offset: UInt64 = 0
        var modified: Date?
        var partial = Data()
        var ledger = TaskAPICostLedger()
        var access: UInt64 = 0
    }
    private var cursors: [URL: Cursor] = [:]
    private var access: UInt64 = 0
    private(set) var lastReadByteCount = 0
    private(set) var lastScannedByteCount = 0
    private(set) var lastOpenCount = 0
    private let chunkSize = 256 * 1_024

    func estimate(url: URL, expected: TokenUsage? = nil) throws -> TaskAPICostEstimate {
        lastReadByteCount = 0; lastScannedByteCount = 0; lastOpenCount = 0
        try Task.checkCancellation()
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let identity = "\(attributes[.systemNumber] ?? 0):\(attributes[.systemFileNumber] ?? 0)"
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = attributes[.modificationDate] as? Date
        var cursor = cursors[url].flatMap {
            $0.identity == identity && size >= $0.offset && !(size == $0.offset && modified != $0.modified) ? $0 : nil
        } ?? Cursor(identity: identity)
        if size > cursor.offset {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            lastOpenCount = 1
            try file.seek(toOffset: cursor.offset)
            while cursor.offset < size {
                try Task.checkCancellation()
                let data = try file.read(upToCount: Int(min(UInt64(chunkSize), size - cursor.offset))) ?? Data()
                guard !data.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                cursor.offset += UInt64(data.count); lastReadByteCount += data.count
                // Retained bytes have already been searched for newlines,
                // including an unfinished line carried over from a prior read.
                let retainedCount = cursor.partial.count
                cursor.partial.append(data)
                var start = cursor.partial.startIndex
                var searchStart = cursor.partial.index(start, offsetBy: retainedCount)
                while searchStart < cursor.partial.endIndex {
                    let newline = cursor.partial[searchStart...].firstIndex(of: 0x0a)
                    let next = newline.map { cursor.partial.index(after: $0) } ?? cursor.partial.endIndex
                    lastScannedByteCount += cursor.partial.distance(from: searchStart, to: next)
                    guard let newline else { break }
                    cursor.ledger.apply(Data(cursor.partial[start..<newline]))
                    start = next
                    searchStart = next
                }
                cursor.partial.removeSubrange(..<start)
            }
        }
        try Task.checkCancellation()
        access &+= 1; cursor.access = access; cursor.modified = modified
        cursors[url] = cursor
        if cursors.count > 32, let oldest = cursors.min(by: { $0.value.access < $1.value.access })?.key {
            cursors.removeValue(forKey: oldest)
        }
        return cursor.ledger.result(expected: expected)
    }
}

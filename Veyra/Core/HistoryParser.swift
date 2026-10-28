import Foundation

/// Persists only structured execution evidence. No prompt, response, tool output or partial line is retained.
struct HistoryParser: Codable, Sendable {
    var task: HistoryTask
    var activeTurnID: String?
    var currentModel: String?
    var baseline: HistoryTokens?
    var seenSamples: Set<String> = []
    var malformedEvents = 0
    var internalTask = false
    var sessionID: String?
    var forkDate: Date?
    var inheritedTurnID: String?
    private let dates = HistoryDates()
    private enum CodingKeys: String, CodingKey {
        case task, activeTurnID, currentModel, baseline, seenSamples, malformedEvents, internalTask
        case sessionID, forkDate, inheritedTurnID
    }

    mutating func apply(_ line: Data, offset: UInt64, retainedSamples: [String: HistoryTokenSample] = [:]) {
        guard let record = try? JSONDecoder().decode(HistoryRecord.self, from: line) else { malformedEvents += 1; return }
        let event = record.value
        let payload = event["payload"]
        let date = dates.parse(event["timestamp"].string)
        switch event["type"].string {
        case "session_meta":
            // Fork logs contain copied parent metadata and lifecycle records. The first
            // metadata entry identifies this log's owner; copied entries must not rename it.
            guard sessionID == nil else { return }
            sessionID = payload["id"].string
            if payload["forked_from_id"].string != nil {
                forkDate = dates.parse(payload["timestamp"].string) ?? date
            }
            if let id = TaskText.nonempty(payload["id"].string), task.id != id {
                task = HistoryTask(id: id, title: task.title, project: task.project, source: task.source,
                                   parentID: task.parentID, archived: task.archived, turns: task.turns)
            }
            task.project = TaskText.nonempty(payload["cwd"].string) ?? task.project
            if let source = payload["source"].string { task.source = ["cli", "exec"].contains(source) ? "cli" : "desktop" }
            let spawn = payload["source"]["subagent"]["thread_spawn"]
            task.parentID = TaskText.nonempty(spawn["parent_thread_id"].string) ?? task.parentID
            if payload["source"]["subagent"]["other"].string != nil { internalTask = true }
        case "turn_context":
            currentModel = payload["model"].string ?? currentModel
            task.project = TaskText.nonempty(payload["cwd"].string) ?? task.project
            if currentModel?.hasPrefix("codex-auto-review") == true { internalTask = true }
            if let activeTurnID, let index = task.turns.firstIndex(where: { $0.id == activeTurnID }) {
                task.turns[index].model = currentModel
            }
        case "event_msg": applyEvent(payload, date: date, offset: offset, retainedSamples: retainedSamples)
        default: break
        }
    }

    private mutating func applyEvent(_ payload: JSONValue, date: Date?, offset: UInt64,
                                     retainedSamples: [String: HistoryTokenSample]) {
        let kind = payload["type"].string ?? ""
        if kind == "task_started" {
            let id = TaskText.nonempty(payload["turn_id"].string) ?? "unidentified-\(offset)"
            let start = lifecycleDate(payload["started_at"], fallback: date)
            if let forkDate, let start, start < forkDate {
                inheritedTurnID = id
                return
            }
            inheritedTurnID = nil
            if let activeTurnID, activeTurnID != id,
               let index = task.turns.firstIndex(where: { $0.id == activeTurnID }), task.turns[index].result == .running {
                task.turns[index].result = .unknown
            }
            activeTurnID = id
            let index = ensureTurn(id)
            task.turns[index].startedAt = task.turns[index].startedAt ?? start
            task.turns[index].observedAt = date ?? task.turns[index].observedAt
            if task.turns[index].endedAt == nil { task.turns[index].result = .running }
            task.turns[index].model = currentModel ?? task.turns[index].model
            return
        }
        let results: [String: ExecutionResult] = ["task_complete": .completed, "task_completed": .completed,
            "task_failed": .failed, "turn_failed": .failed, "turn_aborted": .interrupted]
        if let result = results[kind] {
            let id = TaskText.nonempty(payload["turn_id"].string) ?? activeTurnID ?? "unidentified-\(offset)"
            let start = lifecycleDate(payload["started_at"], fallback: nil)
            let end = lifecycleDate(payload["completed_at"], fallback: date)
            if id == inheritedTurnID { return }
            if !task.turns.contains(where: { $0.id == id }),
               let forkDate, let recorded = start ?? end, recorded < forkDate { return }
            let index = ensureTurn(id)
            task.turns[index].startedAt = task.turns[index].startedAt ?? start
            task.turns[index].endedAt = task.turns[index].endedAt ?? end
            task.turns[index].observedAt = date ?? task.turns[index].observedAt
            task.turns[index].result = result == .completed && payload["error"] != .null ? .failed : result
            if activeTurnID == id { activeTurnID = nil }
            return
        }
        guard kind == "token_count", payload["info"]["total_token_usage"].object != nil else { return }
        let next = HistoryTokens(TokenUsage(json: payload["info"]["total_token_usage"]))
        if inheritedTurnID != nil {
            // The inherited cumulative snapshot is useful as a baseline, never as new usage.
            baseline = next
            return
        }
        guard let date else {
            if let activeTurnID { task.turns[ensureTurn(activeTurnID)].hasTokenGap = true }
            baseline = next
            return
        }
        let signature = "\(date.timeIntervalSince1970)|\(next.input.map(String.init) ?? "?")|\(next.output.map(String.init) ?? "?")|\(next.cachedInput.map(String.init) ?? "?")|\(next.total.map(String.init) ?? "?")"
        guard seenSamples.insert(signature).inserted else { return }
        var delta: HistoryTokens
        if let baseline {
            delta = .difference(next, baseline)
        } else if payload["info"]["last_token_usage"].object != nil {
            delta = HistoryTokens(TokenUsage(json: payload["info"]["last_token_usage"]))
            // A cumulative snapshot larger than the first request proves earlier usage is missing.
            if next.total != delta.total { delta.total = nil }
        } else {
            // The first cumulative snapshot may include inherited or missing earlier usage.
            delta = HistoryTokens()
        }
        baseline = next
        guard let id = TaskText.nonempty(payload["turn_id"].string) ?? activeTurnID else {
            let index = ensureTurn("unattributed-\(offset)")
            task.turns[index].observedAt = date
            task.turns[index].hasTokenGap = true
            return
        }
        let index = ensureTurn(id)
        if let retained = retainedSamples[signature] {
            // A replayed suffix can lose its cumulative baseline. Keep the previously
            // observed delta for the same timestamp/counters instead of introducing a gap.
            let replayed = delta
            delta.input = retained.tokens.input ?? delta.input
            delta.output = retained.tokens.output ?? delta.output
            delta.cachedInput = retained.tokens.cachedInput ?? delta.cachedInput
            delta.total = retained.tokens.total ?? delta.total
            if delta != replayed { task.turns[index].sourceAvailable = false }
        }
        task.turns[index].model = task.turns[index].model ?? currentModel
        task.turns[index].observedAt = date
        task.turns[index].samples.append(HistoryTokenSample(id: signature, date: date, tokens: delta))
        if delta.total == nil { task.turns[index].hasTokenGap = true }
    }

    private func lifecycleDate(_ value: JSONValue, fallback: Date?) -> Date? {
        if let seconds = value.integer, seconds > 0 {
            // Preserve subsecond evidence when the outer timestamp describes the same instant.
            if let fallback, Int64(floor(fallback.timeIntervalSince1970)) == seconds { return fallback }
            return Date(timeIntervalSince1970: Double(seconds))
        }
        return dates.parse(value.string) ?? fallback
    }

    private mutating func ensureTurn(_ id: String) -> Int {
        if let index = task.turns.firstIndex(where: { $0.id == id }) { return index }
        task.turns.append(HistoryTurn(id: id, model: currentModel))
        return task.turns.count - 1
    }

    mutating func mergeStoredTurn(id: String, start: Date?, end: Date?, result: ExecutionResult) {
        if !task.turns.contains(where: { $0.id == id }),
           let forkDate, let recorded = start ?? end, recorded < forkDate { return }
        let existing = task.turns.firstIndex { $0.id == id }
        // Database times can be rounded to whole seconds. Require a unique compatible
        // legacy round; distinct known IDs and ambiguous same-second rounds stay separate.
        let legacy = task.turns.indices.filter { index in
            let turn = task.turns[index]
            guard turn.id.hasPrefix("unidentified-"), turn.id != id,
                  let start, let recorded = turn.startedAt, sameStoredTime(recorded, start) else { return false }
            if let end, let recordedEnd = turn.endedAt, !sameStoredTime(recordedEnd, end) { return false }
            if let existing {
                let known = task.turns[existing]
                if let knownStart = known.startedAt, !sameStoredTime(recorded, knownStart) { return false }
                if let knownEnd = known.endedAt, let recordedEnd = turn.endedAt,
                   !sameStoredTime(recordedEnd, knownEnd) { return false }
            }
            return true
        }
        let index: Int
        if legacy.count == 1, let match = legacy.first {
            var turn = task.turns[match]
            let oldID = turn.id
            turn.id = id
            if let existing {
                // Repair duplicates already persisted by older versions without discarding usage.
                let stored = task.turns[existing]
                turn.startedAt = preciseTime(turn.startedAt, stored.startedAt)
                turn.endedAt = preciseTime(turn.endedAt, stored.endedAt)
                turn.observedAt = [turn.observedAt, stored.observedAt].compactMap { $0 }.max()
                turn.model = turn.model ?? stored.model
                turn.samples = Dictionary((turn.samples + stored.samples).map { ($0.id, $0) },
                    uniquingKeysWith: { a, _ in a }).values.sorted { $0.date != $1.date ? $0.date < $1.date : $0.id < $1.id }
                turn.hasTokenGap = turn.hasTokenGap || stored.hasTokenGap
                turn.sourceAvailable = turn.sourceAvailable || stored.sourceAvailable
                if turn.result == .unknown || turn.result == .running { turn.result = stored.result }
            }
            task.turns[match] = turn
            if activeTurnID == oldID { activeTurnID = id }
            if let existing {
                task.turns.remove(at: existing)
                index = match - (existing < match ? 1 : 0)
            } else { index = match }
        } else if let existing {
            index = existing
        } else {
            task.turns.append(HistoryTurn(id: id))
            index = task.turns.count - 1
        }
        task.turns[index].startedAt = task.turns[index].startedAt ?? start
        task.turns[index].endedAt = task.turns[index].endedAt ?? end
        if task.turns[index].result == .unknown || task.turns[index].result == .running {
            task.turns[index].result = result
        }
    }

    private func sameStoredTime(_ recorded: Date, _ stored: Date) -> Bool {
        let a = recorded.timeIntervalSince1970, b = stored.timeIntervalSince1970
        return a == b || (floor(a) == floor(b) && (a == floor(a) || b == floor(b)))
    }

    private func preciseTime(_ current: Date?, _ stored: Date?) -> Date? {
        guard let current, let stored else { return current ?? stored }
        let a = current.timeIntervalSince1970, b = stored.timeIntervalSince1970
        return floor(a) == floor(b) && a == floor(a) && b != floor(b) ? stored : current
    }
}

/// Parser copies may share this cache. Both formatters are confined by the lock.
private final class HistoryDates: @unchecked Sendable {
    private let lock = NSLock()
    private let fractional = ISO8601DateFormatter()
    private let whole = ISO8601DateFormatter()
    init() {
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        whole.formatOptions = [.withInternetDateTime]
    }
    func parse(_ text: String?) -> Date? {
        guard let text else { return nil }
        lock.lock(); defer { lock.unlock() }
        return fractional.date(from: text) ?? whole.date(from: text)
    }
}

/// Decode only execution evidence. Large conversation bodies are skipped by the decoder,
/// rather than allocating their recursive JSON tree during a multi-gigabyte initial scan.
private struct HistoryRecord: Decodable {
    let value: JSONValue
    private enum Key: String, CodingKey {
        case type, timestamp, payload, id, cwd, source, forked_from_id, model
        case turn_id, started_at, completed_at, error, info
    }

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: Key.self)
        let type = try root.decodeIfPresent(String.self, forKey: .type) ?? ""
        guard ["session_meta", "turn_context", "event_msg"].contains(type) else {
            value = .object(["type": .string(type)])
            return
        }
        let payload = try root.nestedContainer(keyedBy: Key.self, forKey: .payload)
        var fields: [String: JSONValue] = [:]
        let keys: [Key]
        switch type {
        case "session_meta": keys = [.id, .timestamp, .cwd, .source, .forked_from_id]
        case "turn_context": keys = [.model, .cwd]
        default: keys = [.type, .turn_id, .started_at, .completed_at, .info]
        }
        for key in keys {
            if let item = try payload.decodeIfPresent(JSONValue.self, forKey: key) { fields[key.rawValue] = item }
        }
        if payload.contains(.error), try !payload.decodeNil(forKey: .error) { fields["error"] = .bool(true) }
        var event: [String: JSONValue] = ["type": .string(type), "payload": .object(fields)]
        if let timestamp = try root.decodeIfPresent(String.self, forKey: .timestamp) { event["timestamp"] = .string(timestamp) }
        value = .object(event)
    }
}

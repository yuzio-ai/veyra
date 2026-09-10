import Foundation

struct ThreadMetadata: Sendable {
    let id: String
    let title: String
    let rolloutPath: String
    let model: String?
    let source: String
    let updatedAt: Date
    let tokens: Int64?
    var archived = false
    var storedAgentPath: String?
    var storedAgentNickname: String?
    var storedAgentRole: String?
    private var spawn: JSONValue {
        guard let data = source.data(using: .utf8), let value = try? JSONValue.decode(data) else { return .null }
        return value["subagent"]["thread_spawn"]
    }
    var parentID: String? {
        TaskText.nonempty(spawn["parent_thread_id"].string)
    }
    var agentPath: String? { TaskText.nonempty(storedAgentPath) ?? TaskText.nonempty(spawn["agent_path"].string) }
    var agentNickname: String? { TaskText.nonempty(storedAgentNickname) ?? TaskText.nonempty(spawn["agent_nickname"].string) }
    var agentRole: String? { TaskText.nonempty(storedAgentRole) ?? TaskText.nonempty(spawn["agent_role"].string) }
    var displayTitle: String { TaskText.title(title, id: id, parentID: parentID, agentPath: agentPath, nickname: agentNickname) }
    var reference: TaskReference { TaskReference(id: id, title: displayTitle, parentID: parentID) }
    var isInternal: Bool {
        if model?.hasPrefix("codex-auto-review") == true { return true }
        guard let data = source.data(using: .utf8), let value = try? JSONValue.decode(data) else { return false }
        return value["subagent"]["other"].string != nil
    }
    var taskSource: TaskSource {
        if parentID != nil { return .subtask }
        return ["cli", "exec"].contains(source) ? .cli : .desktop
    }
}

enum TurnResolution: Equatable, Sendable {
    case known(TurnBoundary)
    case absent
    case ambiguous
}

enum TaskResolver {
    static let recentActivityWindow: TimeInterval = 86_400

    static func mergeBoundaries(rollout: TurnBoundary?, stored: TurnBoundary?) -> TurnResolution {
        guard let fileTurn = rollout else { return stored.map { .known($0) } ?? .absent }
        guard let dbTurn = stored else { return .known(fileTurn) }

        if let id = fileTurn.turnID, !id.isEmpty, id == dbTurn.turnID {
            // Completion of this exact turn is authoritative even when the database
            // rounded its timestamp down to before the fractional start timestamp.
            if fileTurn.isRunning != dbTurn.isRunning {
                return .known(fileTurn.isRunning ? dbTurn : fileTurn)
            }
            return .known(TurnBoundary(turnID: id, isRunning: fileTurn.isRunning,
                                       date: fileTurn.date ?? dbTurn.date))
        }
        if !fileTurn.isRunning && !dbTurn.isRunning { return .known(fileTurn) }
        if let fileDate = fileTurn.date?.timeIntervalSince1970,
           let dbDate = dbTurn.date?.timeIntervalSince1970, fileDate.isFinite, dbDate.isFinite {
            let fileSecond = floor(fileDate), dbSecond = floor(dbDate)
            if fileSecond != dbSecond { return .known(fileSecond > dbSecond ? fileTurn : dbTurn) }
        }
        // Different (or missing) IDs within the same second cannot establish turn order.
        return .ambiguous
    }

    static func resolve(metadata: ThreadMetadata, rollout: RolloutState, storedTurn: TurnBoundary?, evidence: ProcessEvidence, processMatch: Bool? = nil, now: Date = Date()) -> TaskSnapshot? {
        guard !metadata.isInternal else { return nil }
        let resolution = mergeBoundaries(rollout: rollout.boundary, stored: storedTurn)
        let boundary: TurnBoundary?
        if case .known(let value) = resolution { boundary = value } else { boundary = nil }
        guard boundary?.isRunning != false else { return nil }
        let hasProcess = processMatch ?? evidence.matches(threadID: metadata.id, path: metadata.rolloutPath)
        guard hasProcess || boundary?.isRunning == true || resolution == .ambiguous else { return nil }
        // Historical inProgress records can outlive their process indefinitely.
        // Use recorded activity, never file timestamps that a migration may refresh.
        if evidence.reliable && !hasProcess {
            let latestActivity = [metadata.updatedAt, rollout.usageDate, rollout.boundary?.date, storedTurn?.date]
                .compactMap { $0?.timeIntervalSince1970 }
                .filter { $0.isFinite && $0 > 0 }
                .max()
            if let latestActivity, now.timeIntervalSince1970 - latestActivity >= recentActivityWindow { return nil }
        }
        let activity: TaskActivity = boundary?.isRunning == true && hasProcess && evidence.reliable ? .running : .unknown
        let usage = rollout.usage ?? TokenUsage(total: metadata.tokens)
        return TaskSnapshot(id: metadata.id, title: metadata.displayTitle, model: rollout.model ?? metadata.model,
                            source: metadata.taskSource, parentID: metadata.parentID,
                            startedAt: boundary?.isRunning == true ? boundary?.date : nil,
                            updatedAt: rollout.usageDate ?? metadata.updatedAt, tokens: usage, activity: activity,
                            agentPath: metadata.agentPath, agentNickname: metadata.agentNickname, agentRole: metadata.agentRole,
                            progress: metadata.parentID == nil ? nil : rollout.display.progress(for: boundary))
    }
}

actor LocalTaskReader {
    private var rollouts = RolloutReader()
    private var lastHome: URL?
    private let metadataCache = SQLiteReadCache<[ThreadMetadata]>()
    private let historyCache = SQLiteReadCache<[String: TurnBoundary]>()
    private var quotaByPath: [String: [String: LocalQuotaBucket]] = [:]
    private let now: @Sendable () -> Date
    private let collectEvidence: @Sendable (URL) async -> ProcessEvidence

    init(collectEvidence: @escaping @Sendable (URL) async -> ProcessEvidence = ProcessEvidence.collect) {
        self.init(now: { Date() }, collectEvidence: collectEvidence)
    }

    init(now: @escaping @Sendable () -> Date,
         collectEvidence: @escaping @Sendable (URL) async -> ProcessEvidence = ProcessEvidence.collect) {
        self.now = now
        self.collectEvidence = collectEvidence
    }

    func fetch(home: URL) async throws -> TaskReadResult {
        let checkedAt = now()
        let modelConfig = CodexModelConfig.load(home: home)
        if lastHome != home {
            rollouts = RolloutReader(); lastHome = home
            metadataCache.reset(); historyCache.reset(); quotaByPath = [:]
        }
        var metrics = TaskReadMetrics()
        let evidence = await collectEvidence(home)
        metrics.processCollections = 1
        guard let stateURL = SQLiteReader.database(named: "state", in: home) else {
            metadataCache.reset()
            throw MonitorFailure(L10n.text("Codex task database not found. Run Codex first or choose its data directory in Settings."))
        }
        let loaded = try metadataCache.load(url: stateURL, query: Self.readMetadata)
        let metadata = loaded.value
        metrics.metadataQueries = loaded.queried ? 1 : 0
        var turns: [String: TurnBoundary] = [:]
        var historyUnavailable = false
        if let historyURL = SQLiteReader.database(named: "thread_history", in: home) {
            do {
                let loaded = try historyCache.load(url: historyURL, query: Self.readHistory)
                turns = loaded.value
                metrics.historyQueries = loaded.queried ? 1 : 0
            } catch { historyUnavailable = true }
        } else { historyCache.reset() }

        // Include archived sessions for quota discovery, with a strict cold-read budget.
        let quotaPaths = Set(metadata.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }.prefix(20).map(\.rolloutPath))
        var tasks: [TaskSnapshot] = [], unreadable = false, quotaUnreadable = false
        var readPaths: [String: RolloutState] = [:]
        let recent = checkedAt.addingTimeInterval(-TaskResolver.recentActivityWindow)
        // Task reads go first so a shared path is never tail-read and then reopened.
        for thread in metadata where !thread.archived {
            let hasProcess = evidence.matches(threadID: thread.id, path: thread.rolloutPath)
            let stored = turns[thread.id]
            guard hasProcess || stored?.isRunning == true || (stored == nil && thread.updatedAt > recent) else { continue }
            let rollout: RolloutState
            do {
                if let cached = readPaths[thread.rolloutPath] { rollout = cached }
                else {
                    rollout = try rollouts.read(URL(fileURLWithPath: thread.rolloutPath),
                                                requireBoundary: stored == nil, modelHint: thread.model)
                    metrics.rolloutBytes += rollouts.lastReadByteCount
                    metrics.rolloutOpens += rollouts.lastOpenCount
                    readPaths[thread.rolloutPath] = rollout
                }
                quotaByPath[thread.rolloutPath] = rollout.quotaBuckets
            } catch { rollout = RolloutState(); unreadable = true }
            if let snapshot = TaskResolver.resolve(metadata: thread, rollout: rollout, storedTurn: stored,
                                                   evidence: evidence, processMatch: hasProcess, now: checkedAt) {
                tasks.append(snapshot)
            }
        }
        let modelByPath = Dictionary(metadata.map { ($0.rolloutPath, $0.model) }, uniquingKeysWith: { first, _ in first })
        for path in quotaPaths where readPaths[path] == nil {
            do {
                let rollout = try rollouts.read(URL(fileURLWithPath: path), quotaOnly: true, modelHint: modelByPath[path] ?? nil)
                metrics.rolloutBytes += rollouts.lastReadByteCount
                metrics.rolloutOpens += rollouts.lastOpenCount
                quotaByPath[path] = rollout.quotaBuckets
            } catch { quotaUnreadable = true }
        }
        let retained = Set(metadata.map(\.rolloutPath))
        rollouts.keepOnly(paths: retained)
        quotaByPath = quotaByPath.filter { retained.contains($0.key) }
        var buckets: [String: LocalQuotaBucket] = [:]
        for path in quotaByPath.keys.sorted() {
            for (id, bucket) in quotaByPath[path] ?? [:] {
                if buckets[id].map({ $0.recordedAt < bucket.recordedAt }) ?? true { buckets[id] = bucket }
            }
        }
        tasks.sort {
            if $0.activity != $1.activity { return $0.activity == .running }
            if $0.startedAt != $1.startedAt { return ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
            return $0.id < $1.id
        }
        let byID = Dictionary(metadata.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let taskIDs = Set(tasks.map(\.id))
        var ancestors: [String: TaskReference] = [:]
        for task in tasks {
            var parentID = task.parentID, seen: Set<String> = [task.id]
            while let id = parentID, seen.insert(id).inserted, let parent = byID[id] {
                if !taskIDs.contains(id) { ancestors[id] = parent.reference }
                parentID = parent.parentID
            }
        }
        let warning: TaskReadWarning? = !evidence.reliable ? .processUnverified
            : historyUnavailable ? .historyUnavailable
            : unreadable ? .sessionUnreadable : nil
        return TaskReadResult(tasks: tasks, fetchedAt: checkedAt, warning: warning,
                              localQuota: LocalQuotaBucket.snapshot(buckets),
                              quotaWarning: quotaUnreadable ? L10n.text("Some local quota records are unreadable.") : nil, modelConfig: modelConfig, metrics: metrics,
                              ancestors: ancestors.values.sorted { $0.id < $1.id })
    }

    private static func readMetadata(_ db: SQLiteReader) throws -> [ThreadMetadata] {
        let columns = try db.columns(in: "threads")
        guard columns.contains("id"), columns.contains("rollout_path") else {
            throw MonitorFailure(L10n.text("This Codex database version is not supported."))
        }
        let optional = ["title", "name", "model", "source", "updated_at", "tokens_used", "archived", "agent_path", "agent_nickname", "agent_role"]
            .map { columns.contains($0) ? $0 : "NULL AS \($0)" }
        return try db.rows("SELECT id, rollout_path, \(optional.joined(separator: ", ")) FROM threads").compactMap { row in
            guard let id = row["id"], let path = row["rollout_path"] else { return nil }
            let name = TaskText.nonempty(row["name"]) ?? TaskText.nonempty(row["title"]) ?? ""
            let item = ThreadMetadata(id: id, title: name, rolloutPath: path, model: row["model"], source: row["source"] ?? "",
                                      updatedAt: Date(timeIntervalSince1970: Double(row["updated_at"] ?? "0") ?? 0),
                                      tokens: row["tokens_used"].flatMap(Int64.init), archived: row["archived"] == "1",
                                      storedAgentPath: row["agent_path"], storedAgentNickname: row["agent_nickname"], storedAgentRole: row["agent_role"])
            return item.isInternal ? nil : item
        }
    }

    private static func readHistory(_ history: SQLiteReader) throws -> [String: TurnBoundary] {
        let rows = try history.rows("""
            SELECT t.thread_id, t.turn_id, t.status, t.started_at, t.completed_at
            FROM thread_turns t JOIN
                (SELECT thread_id, MAX(rollout_ordinal) AS latest FROM thread_turns GROUP BY thread_id) latest
            ON t.thread_id = latest.thread_id AND t.rollout_ordinal = latest.latest
            """)
        var turns: [String: TurnBoundary] = [:]
        for row in rows {
            guard let id = row["thread_id"] else { continue }
            let running = row["status"] == "inProgress"
            let seconds = Double((running ? row["started_at"] : row["completed_at"]) ?? "")
            turns[id] = TurnBoundary(turnID: row["turn_id"], isRunning: running, date: seconds.map(Date.init(timeIntervalSince1970:)))
        }
        return turns
    }
}

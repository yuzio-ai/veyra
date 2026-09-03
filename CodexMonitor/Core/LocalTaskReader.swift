import Foundation

struct ThreadMetadata: Sendable {
    let id: String
    let title: String
    let rolloutPath: String
    let model: String?
    let source: String
    let updatedAt: Date
    let tokens: Int64?
    var parentID: String? {
        guard let data = source.data(using: .utf8), let value = try? JSONValue.decode(data) else { return nil }
        return value["subagent"]["thread_spawn"]["parent_thread_id"].string
    }
    var isInternal: Bool {
        if model?.hasPrefix("codex-auto-review") == true { return true }
        guard let data = source.data(using: .utf8), let value = try? JSONValue.decode(data) else { return false }
        return value["subagent"]["other"].string != nil
    }
    var sourceLabel: String {
        if parentID != nil { return "子任务" }
        return ["cli", "exec"].contains(source) ? "CLI" : "桌面端"
    }
}

enum TaskResolver {
    static func resolve(metadata: ThreadMetadata, rollout: RolloutState, storedTurn: TurnBoundary?, evidence: ProcessEvidence) -> TaskSnapshot? {
        guard !metadata.isInternal else { return nil }
        let boundary: TurnBoundary?
        if let fileTurn = rollout.boundary, let dbTurn = storedTurn {
            boundary = (fileTurn.date ?? .distantPast) >= (dbTurn.date ?? .distantPast) ? fileTurn : dbTurn
        } else { boundary = rollout.boundary ?? storedTurn }
        guard boundary?.isRunning != false else { return nil }
        let canonicalPath = URL(fileURLWithPath: metadata.rolloutPath).resolvingSymlinksInPath().path
        let hasProcess = evidence.threadIDs.contains(metadata.id) || evidence.rolloutPaths.contains(metadata.rolloutPath)
            || evidence.rolloutPaths.contains(canonicalPath)
        guard hasProcess || boundary?.isRunning == true else { return nil }
        let activity: TaskActivity = boundary?.isRunning == true && hasProcess && evidence.reliable ? .running : .unknown
        let usage = rollout.usage ?? TokenUsage(total: metadata.tokens)
        return TaskSnapshot(id: metadata.id, title: metadata.title, model: rollout.model ?? metadata.model,
                            sourceLabel: metadata.sourceLabel, parentID: metadata.parentID,
                            startedAt: boundary?.isRunning == true ? boundary?.date : nil,
                            updatedAt: rollout.usageDate ?? metadata.updatedAt, tokens: usage, activity: activity)
    }
}

actor LocalTaskReader {
    private var rollouts = RolloutReader()
    private var lastHome: URL?

    func fetch(home: URL) async throws -> TaskReadResult {
        if lastHome != home { rollouts = RolloutReader(); lastHome = home }
        let evidence = await ProcessEvidence.collect(home: home)
        guard let stateURL = SQLiteReader.database(named: "state", in: home) else {
            throw MonitorFailure("未找到 Codex 任务数据库。请先运行 Codex，或在设置中选择数据目录。")
        }
        let db = try SQLiteReader(url: stateURL)
        let columns = try db.columns(in: "threads")
        guard columns.contains("id"), columns.contains("rollout_path") else { throw MonitorFailure("Codex 数据库版本暂不兼容。") }
        let optional = ["title", "name", "model", "source", "updated_at", "tokens_used"].map { columns.contains($0) ? $0 : "NULL AS \($0)" }
        let filter = columns.contains("archived") ? " WHERE archived = 0" : ""
        let rows = try db.rows("SELECT id, rollout_path, \(optional.joined(separator: ", ")) FROM threads\(filter)")
        let metadata = rows.compactMap { row -> ThreadMetadata? in
            guard let id = row["id"], let path = row["rollout_path"] else { return nil }
            let name = row["name"].flatMap { $0.isEmpty ? nil : $0 } ?? row["title"].flatMap { $0.isEmpty ? nil : $0 } ?? "未命名任务"
            return ThreadMetadata(id: id, title: name, rolloutPath: path, model: row["model"], source: row["source"] ?? "",
                                  updatedAt: Date(timeIntervalSince1970: Double(row["updated_at"] ?? "0") ?? 0),
                                  tokens: row["tokens_used"].flatMap(Int64.init))
        }.filter { !$0.isInternal }
        var turns: [String: TurnBoundary] = [:]
        var historyUnavailable = false
        if let historyURL = SQLiteReader.database(named: "thread_history", in: home) {
            do {
                let history = try SQLiteReader(url: historyURL)
                let rows = try history.rows("""
                    SELECT t.thread_id, t.turn_id, t.status, t.started_at, t.completed_at
                    FROM thread_turns t WHERE t.rollout_ordinal =
                    (SELECT MAX(x.rollout_ordinal) FROM thread_turns x WHERE x.thread_id = t.thread_id)
                    """)
                for row in rows {
                    guard let id = row["thread_id"] else { continue }
                    let running = row["status"] == "inProgress"
                    let seconds = Double((running ? row["started_at"] : row["completed_at"]) ?? "")
                    turns[id] = TurnBoundary(turnID: row["turn_id"], isRunning: running, date: seconds.map(Date.init(timeIntervalSince1970:)))
                }
            } catch { historyUnavailable = true }
        }
        var tasks: [TaskSnapshot] = []
        var unreadable = false
        let recent = Date().addingTimeInterval(-86_400)
        for thread in metadata {
            let canonicalPath = URL(fileURLWithPath: thread.rolloutPath).resolvingSymlinksInPath().path
            let hasProcess = evidence.threadIDs.contains(thread.id) || evidence.rolloutPaths.contains(thread.rolloutPath)
                || evidence.rolloutPaths.contains(canonicalPath)
            let stored = turns[thread.id]
            // Old completed logs need no reads. Legacy active CLI sessions are discovered through open files.
            guard hasProcess || stored?.isRunning == true || (stored == nil && thread.updatedAt > recent) else { continue }
            let rollout: RolloutState
            do { rollout = try rollouts.read(URL(fileURLWithPath: thread.rolloutPath), requireBoundary: stored == nil) }
            catch { rollout = RolloutState(); unreadable = true }
            if let snapshot = TaskResolver.resolve(metadata: thread, rollout: rollout, storedTurn: stored, evidence: evidence) {
                tasks.append(snapshot)
            }
        }
        rollouts.keepOnly(paths: Set(metadata.map(\.rolloutPath)))
        tasks.sort {
            if $0.activity != $1.activity { return $0.activity == .running }
            return ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast)
        }
        let warning = !evidence.reliable ? "无法核对 Codex 进程，任务状态暂不确定。"
            : historyUnavailable ? "部分任务历史暂不可读，正在使用会话事件。"
            : unreadable ? "部分会话记录暂不可读，明细可能不完整。" : nil
        return TaskReadResult(tasks: tasks, fetchedAt: Date(), warning: warning)
    }
}

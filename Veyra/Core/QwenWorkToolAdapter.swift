import Foundation

/// Reads Qwen Work task records from its local SQLite database, read-only.
///
/// The `chats` table has no status and no model column, so every task is
/// reported with an unknown activity rather than a guessed one. Only
/// `chat_type = 'task'` rows are shown, and an unrecognised value simply drops
/// its row — the full set of values is not knowable from one machine's data.
actor QwenWorkToolAdapter: AgentToolAdapter {
    nonisolated let tool = AgentTool.qwenWork
    nonisolated let quotaCapability = QuotaCapability.unsupported

    private let databaseURL: URL
    private let cache = SQLiteReadCache<[AdapterTask]>()

    init(databaseURL: URL? = nil) {
        self.databaseURL = databaseURL ?? Self.defaultDatabaseURL()
    }

    static func defaultDatabaseURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/QwenWorkCN/data/agents.db")
    }

    func probe() async -> AgentToolAvailability {
        FileManager.default.fileExists(atPath: databaseURL.path) ? .ready : .notInstalled
    }

    func readTasks() async -> AdapterTaskResult {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return .unavailable(.notInstalled) }
        do {
            let loaded = try cache.load(url: databaseURL, sourceLabel: tool.displayName, query: Self.readTasks)
            return loaded.value.isEmpty ? .empty : .tasks(loaded.value)
        } catch let failure as SQLiteReadError {
            return .unavailable(.unreadable(failure.adapterFailure))
        } catch {
            return .unavailable(.unreadable(.openFailed))
        }
    }

    private static func readTasks(_ db: SQLiteReader) throws -> [AdapterTask] {
        let chats = try db.columns(in: "chats")
        guard chats.contains("id"), chats.contains("chat_type"),
              chats.contains("updated_at") || chats.contains("created_at") else {
            throw SQLiteReadError(kind: .schemaUnsupported,
                                  message: L10n.text("The data file format is not supported by this version."))
        }
        let projects = try db.columns(in: "projects")
        let hasProjects = projects.contains("id") && projects.contains("name")

        var selection = ["c.id"]
        selection.append(chats.contains("name") ? "c.name AS name" : "NULL AS name")
        if chats.contains("updated_at"), chats.contains("created_at") {
            selection.append("COALESCE(c.updated_at, c.created_at) AS activity_at")
        } else {
            selection.append(chats.contains("updated_at") ? "c.updated_at AS activity_at" : "c.created_at AS activity_at")
        }
        if hasProjects { selection.append("p.name AS project_name") }
        selection.append(chats.contains("branch") ? "c.branch AS branch" : "NULL AS branch")
        selection.append(chats.contains("pr_url") ? "c.pr_url AS pr_url" : "NULL AS pr_url")

        var predicates = ["c.chat_type = 'task'"]
        if chats.contains("deleted_at") { predicates.append("c.deleted_at IS NULL") }
        if chats.contains("archived_at") { predicates.append("c.archived_at IS NULL") }
        let join = hasProjects ? "LEFT JOIN projects p ON p.id = c.project_id" : ""
        let rows = try db.rows("""
            SELECT \(selection.joined(separator: ", "))
            FROM chats c
            \(join)
            WHERE \(predicates.joined(separator: " AND "))
            ORDER BY activity_at DESC
            """)
        return rows.compactMap { row in
            guard let id = TaskText.nonempty(row["id"]), let activity = row["activity_at"],
                  let seconds = Double(activity), seconds.isFinite else { return nil }
            let updated = Date(timeIntervalSince1970: seconds)
            return AdapterTask(snapshot: TaskSnapshot(id: id,
                                                      title: TaskText.nonempty(row["name"]) ?? L10n.text("Untitled task"),
                                                      model: nil,
                                                      source: .desktop,
                                                      parentID: nil,
                                                      startedAt: nil,
                                                      updatedAt: updated,
                                                      tokens: TokenUsage(),
                                                      activity: .unknown),
                               caption: AgentToolFormat.joined([
                                   L10n.text("Updated \(AgentToolFormat.timestamp(updated))"),
                                   row["project_name"], row["branch"], row["pr_url"]
                               ]))
        }
    }
}

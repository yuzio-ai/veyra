import Foundation

/// Reads WorkBuddy task records from its local SQLite database, read-only.
///
/// The database is an application-internal format with no published contract,
/// so every column beyond the two identity fields is optional and a schema the
/// adapter does not recognise degrades to `schemaUnsupported` instead of
/// guessing at column meanings.
actor WorkBuddyToolAdapter: AgentToolAdapter {
    nonisolated let tool = AgentTool.workBuddy
    nonisolated let quotaCapability = QuotaCapability.unsupported

    private let databaseURL: URL
    private let cache = SQLiteReadCache<[AdapterTask]>()

    init(databaseURL: URL? = nil) {
        self.databaseURL = databaseURL ?? Self.defaultDatabaseURL()
    }

    /// Honours `CODEBUDDY_CONFIG_DIR` the way `CodexLocation` honours
    /// `CODEX_HOME`, but only when a database actually sits there; the fixed
    /// location wins otherwise, so an unrelated environment variable cannot
    /// redirect the reader at a stale file.
    static func defaultDatabaseURL() -> URL {
        let fixed = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".workbuddy/workbuddy.db")
        guard let configured = ProcessInfo.processInfo.environment["CODEBUDDY_CONFIG_DIR"],
              !configured.isEmpty else { return fixed }
        let candidate = URL(fileURLWithPath: (configured as NSString).expandingTildeInPath)
            .appendingPathComponent("workbuddy.db")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : fixed
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
        let columns = try db.columns(in: "sessions")
        // Stop rather than guess when the internal schema moves.
        guard columns.contains("id"), columns.contains("updated_at") else {
            throw SQLiteReadError(kind: .schemaUnsupported,
                                  message: L10n.text("The data file format is not supported by this version."))
        }
        var selection = ["id"]
        selection.append(columns.contains("custom_title") && columns.contains("title")
            ? "COALESCE(NULLIF(custom_title, ''), title) AS title"
            : columns.contains("title") ? "title" : "NULL AS title")
        selection.append(columns.contains("model") ? "model" : "NULL AS model")
        selection.append(columns.contains("status") ? "status" : "NULL AS status")
        selection.append(columns.contains("last_activity_at")
            ? "COALESCE(last_activity_at, updated_at) AS activity_at" : "updated_at AS activity_at")
        // Soft-deleted rows and playground scratch sessions are not tasks.
        let live = columns.contains("deleted_at") ? "deleted_at IS NULL" : "1"
        let playground = columns.contains("is_playground") ? "AND is_playground = 0" : ""
        let rows = try db.rows("""
            SELECT \(selection.joined(separator: ", "))
            FROM sessions
            WHERE \(live) \(playground)
            ORDER BY activity_at DESC
            """)
        return rows.compactMap { row in
            guard let id = TaskText.nonempty(row["id"]), let activity = row["activity_at"] else { return nil }
            let updated = Self.date(milliseconds: activity)
            // Only the two observed status values are mapped; anything else is
            // reported as unknown rather than inferred.
            return AdapterTask(snapshot: TaskSnapshot(id: id,
                                                      title: TaskText.nonempty(row["title"]) ?? L10n.text("Untitled task"),
                                                      model: TaskText.nonempty(row["model"]),
                                                      source: .desktop,
                                                      parentID: nil,
                                                      startedAt: nil,
                                                      updatedAt: updated,
                                                      tokens: TokenUsage(),
                                                      activity: row["status"] == "working" ? .running : .unknown),
                               caption: L10n.text("Updated \(AgentToolFormat.timestamp(updated))"))
        }
    }

    /// `updated_at` is stored in milliseconds. Reading it as seconds would not
    /// fail, it would silently date every task to 1970.
    private static func date(milliseconds value: String) -> Date {
        guard let raw = Double(value), raw > 0, raw.isFinite else { return .distantPast }
        return Date(timeIntervalSince1970: raw / 1000)
    }
}

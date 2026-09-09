import XCTest
import Foundation
import SQLite3

final class SQLiteFixture {
    let home: URL
    private var handles: [String: OpaquePointer] = [:]
    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    deinit {
        handles.values.forEach { sqlite3_close($0) }
        try? FileManager.default.removeItem(at: home)
    }
    func execute(_ sql: String, database: String = "state_5") throws {
        if handles[database] == nil {
            var pointer: OpaquePointer?
            guard sqlite3_open(home.appendingPathComponent(database + ".sqlite").path, &pointer) == SQLITE_OK,
                  let pointer else { throw MonitorFailure("fixture open") }
            handles[database] = pointer
        }
        guard sqlite3_exec(handles[database], sql, nil, nil, nil) == SQLITE_OK else { throw MonitorFailure("fixture SQL: \(sql)") }
    }
    func threads() throws {
        try execute("PRAGMA journal_mode=WAL; CREATE TABLE threads(id TEXT PRIMARY KEY, rollout_path TEXT, title TEXT, source TEXT, model TEXT, updated_at INTEGER, archived INTEGER)")
    }
    func insert(_ id: String, path: URL, updated: Int = 1788400000, archived: Bool = false, model: String = "test") throws {
        try execute("INSERT INTO threads VALUES ('\(id)', '\(path.path)', 'Fixture', 'cli', '\(model)', \(updated), \(archived ? 1 : 0))")
    }
    func log(_ name: String, used: Int = 20) throws -> URL {
        let path = home.appendingPathComponent(name + ".jsonl")
        let text = #"{"type":"event_msg","timestamp":"2026-09-03T01:00:00Z","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":\#(used),"window_minutes":300}}}}"# + "\n"
        try text.write(to: path, atomically: false, encoding: .utf8)
        return path
    }
}

final class LocalTaskCacheTests: XCTestCase {
    func testUnnamedChildUsesOptionalMetadataAndRetainsArchivedParentWithoutCountingIt() async throws {
        let fixture = try SQLiteFixture(); try fixture.threads()
        let parentPath = try fixture.log("parent"), childPath = try fixture.log("child")
        try fixture.insert("parent", path: parentPath, archived: true)
        try fixture.insert("child", path: childPath)
        try fixture.execute("ALTER TABLE threads ADD COLUMN name TEXT; ALTER TABLE threads ADD COLUMN agent_path TEXT; ALTER TABLE threads ADD COLUMN agent_nickname TEXT; ALTER TABLE threads ADD COLUMN agent_role TEXT")
        try fixture.execute("""
            UPDATE threads SET name='归档父任务' WHERE id='parent';
            UPDATE threads SET title='', name='  ', agent_path='/root/ios_phone_auth_r2_review',
                agent_nickname='Lorentz', agent_role='reviewer',
                source='{"subagent":{"thread_spawn":{"parent_thread_id":"parent"}}}' WHERE id='child';
            """)
        try Data((#"{"type":"event_msg","payload":{"type":"task_started","turn_id":"child-turn"}}"# + "\n" +
                  #"{"type":"turn_context","payload":{"model":"test"}}"# + "\n" +
                  #"{"type":"response_item","payload":{"type":"message","role":"assistant","phase":"commentary","content":[{"type":"output_text","text":"正在检查认证边界"}],"internal_chat_message_metadata_passthrough":{"turn_id":"child-turn"}}}"# + "\n").utf8).appendTo(childPath)
        let reader = LocalTaskReader { _ in ProcessEvidence(threadIDs: ["child"]) }
        let first = try await reader.fetch(home: fixture.home)
        XCTAssertEqual(first.tasks.count, 1)
        XCTAssertEqual(first.tasks[0].title, "ios phone auth r2 review")
        XCTAssertEqual(first.tasks[0].agentRole, "reviewer")
        XCTAssertEqual(first.tasks[0].progress?.text, "正在检查认证边界")
        XCTAssertEqual(first.ancestors, [TaskReference(id: "parent", title: "归档父任务", parentID: nil)])
        let cached = try await reader.fetch(home: fixture.home)
        XCTAssertEqual(cached.metrics.metadataQueries, 0)
        XCTAssertEqual(cached.metrics.rolloutBytes, 0)
        XCTAssertEqual(cached.metrics.rolloutOpens, 0)
        try fixture.execute("UPDATE threads SET name='新的父任务标题' WHERE id='parent'")
        let renamed = try await reader.fetch(home: fixture.home)
        XCTAssertEqual(renamed.ancestors.first?.title, "新的父任务标题")
        XCTAssertEqual(renamed.metrics.rolloutBytes, 0)
    }

    func testCacheHitWALCommitAndQueryRaceCannotMarkOldResultCurrent() throws {
        let fixture = try SQLiteFixture()
        try fixture.execute("PRAGMA journal_mode=WAL; CREATE TABLE sample(value INTEGER); INSERT INTO sample VALUES(1)")
        let url = fixture.home.appendingPathComponent("state_5.sqlite")
        let cache = SQLiteReadCache<String>()
        func query(_ reader: SQLiteReader) throws -> String { try reader.rows("SELECT value FROM sample").first!["value"]! }
        XCTAssertTrue(try cache.load(url: url, query: query).queried)
        XCTAssertFalse(try cache.load(url: url, query: query).queried)
        try fixture.execute("UPDATE sample SET value=2")
        let raced = try cache.load(url: url) { reader in
            let old = try query(reader)
            try fixture.execute("UPDATE sample SET value=3")
            return old
        }
        XCTAssertEqual(raced.value, "2")
        let next = try cache.load(url: url, query: query)
        XCTAssertTrue(next.queried)
        XCTAssertEqual(next.value, "3")
        try fixture.execute("UPDATE sample SET value=4")
        XCTAssertThrowsError(try cache.load(url: url) { _ -> String in throw MonitorFailure("temporary failure") })
        XCTAssertEqual(try cache.load(url: url, query: query).value, "4")
        try fixture.execute("ALTER TABLE sample ADD COLUMN extra TEXT")
        XCTAssertTrue(try cache.load(url: url, query: query).queried)
    }
    func testAtomicDatabaseReplacementReconnects() throws {
        let first = try SQLiteFixture(), second = try SQLiteFixture()
        try first.execute("CREATE TABLE sample(value INTEGER); INSERT INTO sample VALUES(1)")
        try second.execute("CREATE TABLE sample(value INTEGER); INSERT INTO sample VALUES(2)")
        let url = first.home.appendingPathComponent("state_5.sqlite")
        let cache = SQLiteReadCache<String>()
        func query(_ db: SQLiteReader) throws -> String { try db.rows("SELECT value FROM sample").first!["value"]! }
        XCTAssertEqual(try cache.load(url: url, query: query).value, "1")
        let replacement = try Data(contentsOf: second.home.appendingPathComponent("state_5.sqlite"))
        try replacement.write(to: url, options: .atomic)
        XCTAssertEqual(try cache.load(url: url, query: query).value, "2")
    }
    func testMetadataHistoryAndLogCacheStillDetectProcessExitAndLogCompletion() async throws {
        let fixture = try SQLiteFixture()
        try fixture.threads()
        let path = try fixture.log("running")
        let started = #"{"type":"event_msg","timestamp":"2026-09-03T01:00:00Z","payload":{"type":"task_started","turn_id":"one"}}"# + "\n"
        let model = #"{"type":"turn_context","payload":{"model":"test"}}"# + "\n"
        try (started + model).data(using: .utf8)!.appendTo(path)
        try fixture.insert("task", path: path)
        try fixture.execute("PRAGMA journal_mode=WAL; CREATE TABLE thread_turns(thread_id TEXT, turn_id TEXT, rollout_ordinal INTEGER, status TEXT, started_at INTEGER, completed_at INTEGER); CREATE UNIQUE INDEX idx_thread_turns_page ON thread_turns(thread_id, rollout_ordinal); INSERT INTO thread_turns VALUES('task','one',1,'inProgress',1788397200,NULL)", database: "thread_history_1")
        let evidence = EvidenceFixture(ProcessEvidence(threadIDs: ["task"]))
        let reader = LocalTaskReader(now: { Date(timeIntervalSince1970: 1788400001) }) { _ in await evidence.get() }
        let first = try await reader.fetch(home: fixture.home)
        XCTAssertEqual(first.tasks.first?.activity, .running)
        XCTAssertEqual(first.metrics.metadataQueries, 1)
        let cached = try await reader.fetch(home: fixture.home)
        XCTAssertEqual(cached.metrics.metadataQueries, 0)
        XCTAssertEqual(cached.metrics.historyQueries, 0)
        XCTAssertEqual(cached.metrics.rolloutBytes, 0)
        XCTAssertEqual(cached.metrics.rolloutOpens, 0)
        await evidence.set(ProcessEvidence())
        let exited = try await reader.fetch(home: fixture.home)
        XCTAssertEqual(exited.tasks.first?.activity, .unknown)
        await evidence.set(ProcessEvidence(threadIDs: ["task"]))
        try Data((#"{"type":"event_msg","timestamp":"2026-09-03T01:00:01Z","payload":{"type":"task_complete","turn_id":"one"}}"# + "\n").utf8).appendTo(path)
        let completed = try await reader.fetch(home: fixture.home)
        XCTAssertTrue(completed.tasks.isEmpty)
        XCTAssertEqual(completed.metrics.metadataQueries, 0)
        XCTAssertGreaterThan(completed.metrics.rolloutBytes, 0)
        try fixture.execute("UPDATE threads SET archived=1")
        let archived = try await reader.fetch(home: fixture.home)
        XCTAssertTrue(archived.tasks.isEmpty)
        XCTAssertNotNil(archived.localQuota)
        try fixture.execute("DELETE FROM threads")
        let deleted = try await reader.fetch(home: fixture.home)
        XCTAssertNil(deleted.localQuota)
    }
    func testQuotaDiscoveryIncludesArchivedExcludesInternalAndIsBounded() async throws {
        let fixture = try SQLiteFixture(); try fixture.threads()
        for i in 0..<24 {
            let path = try fixture.log("log-\(i)")
            let filler = Data(String(repeating: "{}\n", count: 100_000).utf8)
            try filler.appendTo(path)
            try fixture.insert("id-\(i)", path: path, updated: i, archived: true)
        }
        let internalPath = try fixture.log("internal", used: 99)
        try fixture.insert("internal", path: internalPath, updated: 1000, archived: true, model: "codex-auto-review-test")
        let reader = LocalTaskReader { _ in ProcessEvidence() }
        let first = try await reader.fetch(home: fixture.home)
        XCTAssertTrue(first.tasks.isEmpty)
        XCTAssertNil(first.localQuota)
        XCTAssertEqual(first.metrics.rolloutBytes, 20 * 256 * 1024)
        let next = try await reader.fetch(home: fixture.home)
        XCTAssertEqual(next.metrics.rolloutBytes, 0)
        XCTAssertEqual(next.metrics.rolloutOpens, 0)
        let fresh = try fixture.log("fresh")
        try fixture.insert("fresh", path: fresh, updated: 2000, archived: true)
        let refreshed = try await reader.fetch(home: fixture.home)
        XCTAssertEqual(refreshed.localQuota?.menuWindow?.remainingPercent, 80)
    }
    func testLegacyProcessPathsResolveSymlinksAndUnreliableEvidenceStaysUnknown() throws {
        let fixture = try SQLiteFixture(), path = try fixture.log("real")
        let link = fixture.home.appendingPathComponent("alias.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: path)
        let evidence = ProcessEvidence(rolloutPaths: [path.resolvingSymlinksInPath().path], reliable: false)
        XCTAssertTrue(evidence.matches(threadID: "task", path: link.path))
        let metadata = ThreadMetadata(id: "task", title: "Fixture", rolloutPath: link.path, model: nil, source: "cli", updatedAt: .now, tokens: nil)
        let task = TaskResolver.resolve(metadata: metadata, rollout: RolloutState(boundary: TurnBoundary(turnID: "one", isRunning: true, date: .now)), storedTurn: nil, evidence: evidence)
        XCTAssertEqual(task?.activity, .unknown)
    }
    func testProcessEvidenceAcceptsAlternateHomeSpellingOnlyForMatchingDirectory() throws {
        let fixture = try SQLiteFixture()
        let real = fixture.home.appendingPathComponent("real")
        let locks = real.appendingPathComponent("thread-writer-locks")
        try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)
        let id = UUID().uuidString
        try Data().write(to: locks.appendingPathComponent(id + ".lock"))
        let alias = fixture.home.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        let text = "p1\nccodex\nn\(alias.path)/thread-writer-locks/\(id).lock\n"
        XCTAssertEqual(ProcessEvidence.parse(text, home: real).threadIDs, [id])
        XCTAssertTrue(ProcessEvidence.parse(text, home: fixture.home.appendingPathComponent("other")).threadIDs.isEmpty)
    }

    private func unfinishedHistory(_ fixture: SQLiteFixture) throws {
        try fixture.execute("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE thread_turns(thread_id TEXT, turn_id TEXT, rollout_ordinal INTEGER,
                status TEXT, started_at INTEGER, completed_at INTEGER);
            """, database: "thread_history_1")
    }

    private func unfinishedTask(_ id: String, fixture: SQLiteFixture, resumed: Bool = false) throws -> URL {
        let path = try fixture.log(id)
        try fixture.insert(id, path: path, updated: 1788397200)
        if resumed {
            try Data((#"{"type":"event_msg","timestamp":"2026-09-02T01:00:00Z","payload":{"type":"task_started","turn_id":"previous"}}"# + "\n" +
                #"{"type":"event_msg","timestamp":"2026-09-02T01:01:00Z","payload":{"type":"turn_aborted","turn_id":"previous"}}"# + "\n").utf8).appendTo(path)
            try fixture.execute("INSERT INTO thread_turns VALUES('\(id)','previous',1,'interrupted',NULL,NULL)", database: "thread_history_1")
        }
        try Data((#"{"type":"event_msg","timestamp":"2026-09-03T01:00:00Z","payload":{"type":"task_started","turn_id":"last"}}"# + "\n" +
            #"{"type":"turn_context","payload":{"model":"test"}}"# + "\n").utf8).appendTo(path)
        try fixture.execute("INSERT INTO thread_turns VALUES('\(id)','last',9,'inProgress',NULL,NULL)", database: "thread_history_1")
        return path
    }

    func testHistoricalUnfinishedTasksExpireOnCacheHitsAndKeepQuotaDiscovery() async throws {
        let fixture = try SQLiteFixture(); try fixture.threads(); try unfinishedHistory(fixture)
        _ = try unfinishedTask("started-only", fixture: fixture)
        _ = try unfinishedTask("resumed", fixture: fixture, resumed: true)
        let lastActivity = Date(timeIntervalSince1970: 1788397200)
        let clock = TaskReaderClock(lastActivity.addingTimeInterval(86_399.999))
        let reader = LocalTaskReader(now: { clock.get() }) { _ in ProcessEvidence() }
        let recent = try await reader.fetch(home: fixture.home)
        XCTAssertEqual(Set(recent.tasks.map(\.id)), ["started-only", "resumed"])
        XCTAssertTrue(recent.tasks.allSatisfy { $0.activity == .unknown })
        XCTAssertEqual(recent.fetchedAt, clock.get())

        for age in [86_400.0, 180.0 * 86_400] {
            clock.set(lastActivity.addingTimeInterval(age))
            let expired = try await reader.fetch(home: fixture.home)
            XCTAssertTrue(expired.tasks.isEmpty)
            XCTAssertNil(expired.warning)
            XCTAssertEqual(expired.fetchedAt, clock.get())
            XCTAssertEqual(expired.metrics.metadataQueries, 0)
            XCTAssertEqual(expired.metrics.historyQueries, 0)
            XCTAssertEqual(expired.metrics.rolloutBytes, 0)
            XCTAssertEqual(expired.metrics.rolloutOpens, 0)
            XCTAssertEqual(expired.localQuota?.menuWindow?.remainingPercent, 80)
        }
    }

    func testRecentLogActivitySurvivesOldMetadataAndMigrationDoesNotReviveStaleTasks() async throws {
        let fixture = try SQLiteFixture(); try fixture.threads(); try unfinishedHistory(fixture)
        let stale = try unfinishedTask("stale", fixture: fixture)
        let started = try unfinishedTask("fresh-start", fixture: fixture)
        let usage = try unfinishedTask("fresh-usage", fixture: fixture)
        try Data((#"{"type":"event_msg","timestamp":"2026-09-05T01:00:00Z","payload":{"type":"task_started","turn_id":"new"}}"# + "\n").utf8).appendTo(started)
        try Data((#"{"type":"event_msg","timestamp":"2026-09-05T01:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":123}}}}"# + "\n").utf8).appendTo(usage)
        let reader = LocalTaskReader(now: { Date(timeIntervalSince1970: 1788570001) }) { _ in ProcessEvidence() }
        let first = try await reader.fetch(home: fixture.home)
        XCTAssertEqual(Set(first.tasks.map(\.id)), ["fresh-start", "fresh-usage"])
        // A migration may rewrite the file and project identical turn rows with new file metadata.
        let original = try Data(contentsOf: stale)
        try original.write(to: stale, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1788570001)], ofItemAtPath: stale.path)
        try fixture.execute("DELETE FROM thread_turns WHERE thread_id='stale'; INSERT INTO thread_turns VALUES('stale','last',9,'inProgress',NULL,NULL)", database: "thread_history_1")
        let migrated = try await reader.fetch(home: fixture.home)
        XCTAssertEqual(Set(migrated.tasks.map(\.id)), ["fresh-start", "fresh-usage"])
        XCTAssertEqual(migrated.metrics.historyQueries, 1)
        XCTAssertGreaterThan(migrated.metrics.rolloutBytes, 0)
        XCTAssertNotNil(migrated.localQuota)
    }

    func testUnreadableRolloutUsesStoredActivityAndProcessFailuresKeepWarning() async throws {
        let fixture = try SQLiteFixture(); try fixture.threads(); try unfinishedHistory(fixture)
        let path = try unfinishedTask("task", fixture: fixture)
        try FileManager.default.removeItem(at: path)
        let evidence = EvidenceFixture(ProcessEvidence())
        let reader = LocalTaskReader(now: { Date(timeIntervalSince1970: 1788570001) }) { _ in await evidence.get() }
        let stale = try await reader.fetch(home: fixture.home)
        XCTAssertTrue(stale.tasks.isEmpty)
        XCTAssertEqual(stale.warning, .sessionUnreadable)

        await evidence.set(ProcessEvidence(reliable: false))
        let unavailable = try await reader.fetch(home: fixture.home)
        XCTAssertEqual(unavailable.tasks.first?.activity, .unknown)
        XCTAssertEqual(unavailable.warning, .processUnverified)

        await evidence.set(ProcessEvidence(threadIDs: ["task"]))
        let live = try await reader.fetch(home: fixture.home)
        XCTAssertEqual(live.tasks.first?.activity, .running)

        await evidence.set(ProcessEvidence())
        try fixture.execute("UPDATE thread_turns SET started_at=1788570000", database: "thread_history_1")
        let recent = try await reader.fetch(home: fixture.home)
        XCTAssertEqual(recent.tasks.first?.activity, .unknown)
        XCTAssertEqual(recent.warning, .sessionUnreadable)
    }

    func testFetchCapturesOneTimeBeforeAwaitingProcessCollection() async throws {
        let fixture = try SQLiteFixture(); try fixture.threads()
        let path = try fixture.log("recent-without-history")
        try fixture.insert("task", path: path, updated: 1788397200)
        try Data((#"{"type":"event_msg","timestamp":"2026-09-03T01:00:00Z","payload":{"type":"task_started","turn_id":"one"}}"# + "\n").utf8).appendTo(path)
        let beforeExpiry = Date(timeIntervalSince1970: 1788397200 + 86_399)
        let clock = TaskReaderClock(beforeExpiry)
        let reader = LocalTaskReader(now: { clock.get() }) { _ in
            clock.set(beforeExpiry.addingTimeInterval(2))
            return ProcessEvidence()
        }
        let result = try await reader.fetch(home: fixture.home)
        XCTAssertEqual(result.fetchedAt, beforeExpiry)
        XCTAssertEqual(result.tasks.first?.activity, .unknown)
        let next = try await reader.fetch(home: fixture.home)
        XCTAssertTrue(next.tasks.isEmpty)
    }
}

// Synchronous Sendable clock closure; every access to its mutable date is locked.
private final class TaskReaderClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    func get() -> Date { lock.withLock { date } }
    func set(_ date: Date) { lock.withLock { self.date = date } }
}

private actor EvidenceFixture {
    var evidence: ProcessEvidence
    init(_ evidence: ProcessEvidence) { self.evidence = evidence }
    func get() -> ProcessEvidence { evidence }
    func set(_ value: ProcessEvidence) { evidence = value }
}

private extension Data {
    func appendTo(_ url: URL) throws {
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.seekToEnd(); try file.write(contentsOf: self)
    }
}

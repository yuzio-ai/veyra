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
        let reader = LocalTaskReader { _ in await evidence.get() }
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

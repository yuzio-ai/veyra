import Foundation
import XCTest

final class HistoryIndexTests: XCTestCase {
    private func line(_ kind: String, _ seconds: Int, _ fields: String = "") -> String {
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-10-13T01:00:\(String(format: "%02d", seconds))Z\",\"payload\":{\"type\":\"\(kind)\"\(fields)}}\n"
    }
    private func usage(_ total: Int, _ last: Int? = nil) -> String {
        ",\"info\":{\"total_token_usage\":{\"input_tokens\":\(total),\"output_tokens\":0,\"cached_input_tokens\":0,\"total_tokens\":\(total)}"
            + (last.map { ",\"last_token_usage\":{\"input_tokens\":\($0),\"output_tokens\":0,\"cached_input_tokens\":0,\"total_tokens\":\($0)}" } ?? "") + "}"
    }
    private func parser() -> HistoryParser {
        HistoryParser(task: HistoryTask(id: "thread", title: "Fixture", source: "cli", parentID: nil))
    }
    private func apply(_ text: String, to parser: inout HistoryParser) {
        for (index, line) in text.split(separator: "\n").enumerated() { parser.apply(Data(line.utf8), offset: UInt64(index * 100)) }
    }

    func testMultipleRoundsPreserveDistinctOutcomesAndUsageDeltas() {
        var p = parser()
        let text = line("task_started", 0, ",\"turn_id\":\"a\"")
            + line("token_count", 1, usage(100, 100)) + line("task_complete", 2, ",\"turn_id\":\"a\"")
            + line("task_started", 3, ",\"turn_id\":\"b\"") + line("token_count", 4, usage(150))
            + line("turn_aborted", 5, ",\"turn_id\":\"b\"")
            + line("task_started", 6, ",\"turn_id\":\"c\"") + line("task_failed", 7, ",\"turn_id\":\"c\"")
        apply(text, to: &p)
        XCTAssertEqual(p.task.turns.map(\.result), [.completed, .interrupted, .failed])
        XCTAssertEqual(p.task.turns[0].samples[0].tokens.total, 100)
        XCTAssertEqual(p.task.turns[1].samples[0].tokens.total, 50)
    }

    func testDuplicateEventsCannotDoubleCountTokensOrTurns() {
        var p = parser()
        let events = line("task_started", 0, ",\"turn_id\":\"a\"") + line("token_count", 1, usage(10, 10))
            + line("task_complete", 2, ",\"turn_id\":\"a\"")
        apply(events + events, to: &p)
        XCTAssertEqual(p.task.turns.count, 1); XCTAssertEqual(p.task.turns[0].samples.count, 1)
        XCTAssertEqual(p.task.turns[0].result, .completed)
    }

    func testMissingBaselineAndCounterResetAreGapsNotNegativeOrInventedUsage() {
        var p = parser()
        apply(line("task_started", 0, ",\"turn_id\":\"a\"") + line("token_count", 1, usage(100))
              + line("token_count", 2, usage(110)) + line("token_count", 3, usage(5)) + line("token_count", 4, usage(8)), to: &p)
        XCTAssertTrue(p.task.turns[0].hasTokenGap)
        XCTAssertNil(p.task.turns[0].samples[0].tokens.total)
        XCTAssertEqual(p.task.turns[0].samples[1].tokens.total, 10)
        XCTAssertNil(p.task.turns[0].samples[2].tokens.total)
        XCTAssertEqual(p.task.turns[0].samples[3].tokens.total, 3)
    }

    func testFirstRequestCannotRepresentLargerInheritedCumulativeSnapshot() {
        var p = parser()
        apply(line("task_started", 0, ",\"turn_id\":\"a\"") + line("token_count", 1, usage(100, 10)), to: &p)
        XCTAssertTrue(p.task.turns[0].hasTokenGap)
        XCTAssertNil(p.task.turns[0].samples[0].tokens.total)
    }

    func testNewStartWithoutTerminalDoesNotInventPreviousEndTime() {
        var p = parser()
        apply(line("task_started", 0, ",\"turn_id\":\"a\"") + line("task_started", 1, ",\"turn_id\":\"b\""), to: &p)
        XCTAssertEqual(p.task.turns[0].result, .unknown); XCTAssertNil(p.task.turns[0].endedAt)
        XCTAssertEqual(p.task.turns[1].result, .running)
    }

    func testStoredRunningStateDoesNotUndoAuthoritativeTerminalEvent() {
        var p = parser()
        apply(line("task_started", 0, ",\"turn_id\":\"a\"") + line("task_complete", 2, ",\"turn_id\":\"a\""), to: &p)
        p.mergeStoredTurn(id: "a", start: nil, end: nil, result: .running)
        XCTAssertEqual(p.task.turns.count, 1); XCTAssertEqual(p.task.turns[0].result, .completed)
    }

    func testCompletionEnvelopeWithErrorIsFailure() {
        var p = parser()
        apply(line("task_started", 0, ",\"turn_id\":\"a\"")
              + line("task_complete", 2, ",\"turn_id\":\"a\",\"error\":{\"message\":\"fixture error\"}"), to: &p)
        p.mergeStoredTurn(id: "a", start: nil, end: nil, result: .failed)
        XCTAssertEqual(p.task.turns[0].result, .failed)
    }

    func testPayloadLifecycleTimesRecoverRewrittenTimestampsAndMissingStart() {
        var p = parser()
        apply(line("task_complete", 2, ",\"turn_id\":\"a\",\"started_at\":1791853100,\"completed_at\":1791853160"), to: &p)
        XCTAssertEqual(p.task.turns[0].startedAt?.timeIntervalSince1970, 1791853100)
        XCTAssertEqual(p.task.turns[0].endedAt?.timeIntervalSince1970, 1791853160)
        XCTAssertEqual(p.task.turns[0].duration, 60)
    }

    func testForkKeepsOwnIdentityAndExcludesInheritedRoundsAndUsage() {
        var p = parser()
        apply("{\"type\":\"session_meta\",\"timestamp\":\"2026-10-13T01:00:00Z\",\"payload\":{\"id\":\"child\",\"timestamp\":\"2026-10-13T01:00:00Z\",\"forked_from_id\":\"parent\",\"source\":\"cli\"}}\n"
              + "{\"type\":\"session_meta\",\"payload\":{\"id\":\"parent\",\"source\":{\"subagent\":{\"other\":\"auto-review\"}}}}\n"
              + line("task_started", 0, ",\"turn_id\":\"old\",\"started_at\":1791853100")
              + line("token_count", 0, usage(100, 100))
              + line("task_complete", 0, ",\"turn_id\":\"old\",\"started_at\":1791853100,\"completed_at\":1791853160")
              + line("task_started", 1, ",\"turn_id\":\"new\",\"started_at\":1791853201")
              + line("token_count", 2, usage(120)) + line("task_complete", 3, ",\"turn_id\":\"new\""), to: &p)
        XCTAssertEqual(p.task.id, "child"); XCTAssertFalse(p.internalTask)
        XCTAssertEqual(p.task.turns.map(\.id), ["new"])
        XCTAssertEqual(p.task.turns[0].samples[0].tokens.total, 20)
        p.mergeStoredTurn(id: "old-db", start: nil, end: Date(timeIntervalSince1970: 1791853160), result: .completed)
        XCTAssertEqual(p.task.turns.map(\.id), ["new"], "Copied database turns also predate the fork")
    }

    func testForkFirstRoundCompletionWithRoundedStartIsNotInherited() {
        var p = parser()
        apply("{\"type\":\"session_meta\",\"timestamp\":\"2026-10-13T01:00:00.792Z\",\"payload\":{\"id\":\"child\",\"timestamp\":\"2026-10-13T01:00:00.792Z\",\"forked_from_id\":\"parent\"}}\n"
              + "{\"type\":\"event_msg\",\"timestamp\":\"2026-10-13T01:00:00.834Z\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"own\",\"started_at\":1791853200}}\n"
              + "{\"type\":\"event_msg\",\"timestamp\":\"2026-10-13T01:00:02.123Z\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"own\",\"started_at\":1791853200,\"completed_at\":1791853202}}\n", to: &p)
        XCTAssertEqual(p.task.turns.count, 1)
        XCTAssertEqual(p.task.turns[0].result, .completed)
        XCTAssertEqual(p.task.turns[0].duration ?? 0, 1.289, accuracy: 0.001)
    }

    func testInternalAgentsAndPublicTextDoNotEnterPersistentIndex() throws {
        var p = parser()
        apply("{\"type\":\"session_meta\",\"payload\":{\"id\":\"thread\",\"source\":{\"subagent\":{\"other\":\"auto-review\"}}}}\n"
              + "{\"type\":\"response_item\",\"payload\":{\"content\":\"PRIVATE_RESPONSE_SECRET\"}}\n", to: &p)
        XCTAssertTrue(p.internalTask)
        let stored = String(decoding: try JSONEncoder().encode(p), as: UTF8.self)
        XCTAssertFalse(stored.contains("PRIVATE_RESPONSE_SECRET")); XCTAssertFalse(stored.contains("auto-review"))
    }

    private func fixture() throws -> (URL, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let home = root.appendingPathComponent("codex"), index = root.appendingPathComponent("veyra/index.json")
        let log = home.appendingPathComponent("archived_sessions/session.jsonl")
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (home, index, log)
    }
    private func initial() -> String {
        "{\"type\":\"session_meta\",\"payload\":{\"id\":\"thread\",\"cwd\":\"/fixture/project\",\"source\":\"cli\"}}\n"
            + line("task_started", 0, ",\"turn_id\":\"a\"") + line("token_count", 1, usage(10, 10))
            + line("task_complete", 2, ",\"turn_id\":\"a\"")
    }
    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: Data(text.utf8))
    }

    func testArchivedLogsIncrementalScanPersistenceAndDeletedSourceRetention() async throws {
        let (home, file, log) = try fixture()
        try initial().write(to: log, atomically: true, encoding: .utf8)
        let index = HistoryIndex(indexURL: file)
        let first = try await index.scan(home: home)
        XCTAssertEqual(first.tasks.count, 1); XCTAssertEqual(first.tasks[0].turns.count, 1)
        let savedAt = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        let cached = try await index.scan(home: home); XCTAssertEqual(cached.bytesRead, 0)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date, savedAt,
                       "Unchanged history must not be re-encoded and written on every dashboard tick")
        let secondRound = line("task_started", 3, ",\"turn_id\":\"b\"") + line("token_count", 4, usage(30))
            + line("task_complete", 5, ",\"turn_id\":\"b\"")
        try append(secondRound, to: log)
        let incremental = try await index.scan(home: home)
        XCTAssertEqual(incremental.tasks[0].turns.count, 2)
        XCTAssertEqual(incremental.tasks[0].turns[1].samples[0].tokens.total, 20)
        let relaunched = HistoryIndex(indexURL: file)
        let persisted = try await relaunched.scan(home: home)
        XCTAssertEqual(persisted.bytesRead, 0); XCTAssertEqual(persisted.tasks, incremental.tasks)
        try FileManager.default.removeItem(at: log)
        let retained = try await relaunched.scan(home: home)
        XCTAssertEqual(retained.tasks[0].turns.count, 2); XCTAssertFalse(retained.tasks[0].sourceAvailable)
        try await relaunched.clear()
        let cleared = try await relaunched.scan(home: home); XCTAssertTrue(cleared.tasks.isEmpty)
    }

    func testPartialLastLineIsNotPersistedAndIsRecoveredOnAppend() async throws {
        let (home, file, log) = try fixture()
        let event = line("task_started", 3, ",\"turn_id\":\"b\"")
        let prefix = String(event.prefix(event.count / 2)), suffix = String(event.dropFirst(event.count / 2))
        try (initial() + prefix).write(to: log, atomically: true, encoding: .utf8)
        let index = HistoryIndex(indexURL: file)
        let partial = try await index.scan(home: home); XCTAssertEqual(partial.tasks[0].turns.count, 1)
        let persisted = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(persisted.contains("event_msg"))
        try append(suffix, to: log)
        let complete = try await index.scan(home: home); XCTAssertEqual(complete.tasks[0].turns.count, 2)
    }

    func testTruncationRetainsFinishedEvidenceWithoutMultiplyingRecords() async throws {
        let (home, file, log) = try fixture()
        try initial().write(to: log, atomically: true, encoding: .utf8)
        let index = HistoryIndex(indexURL: file)
        _ = try await index.scan(home: home)
        let replacement = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"thread\"}}\n"
            + line("task_started", 4, ",\"turn_id\":\"b\"") + line("task_complete", 5, ",\"turn_id\":\"b\"")
        try replacement.write(to: log, atomically: false, encoding: .utf8)
        let next = try await index.scan(home: home)
        XCTAssertEqual(Set(next.tasks[0].turns.map(\.id)), ["a", "b"])
        XCTAssertFalse(next.tasks[0].turns.first { $0.id == "a" }!.sourceAvailable)
    }

    func testTruncatedSameTurnCompletionRetainsTimingAndUsageAcrossRelaunch() async throws {
        let (home, file, log) = try fixture()
        try initial().write(to: log, atomically: true, encoding: .utf8)
        let index = HistoryIndex(indexURL: file)
        let before = try await index.scan(home: home)
        let original = try XCTUnwrap(before.tasks.first?.turns.first)
        let suffix = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"thread\"}}\n"
            + line("task_complete", 2, ",\"turn_id\":\"a\"")
        try suffix.write(to: log, atomically: false, encoding: .utf8)
        let after = try await index.scan(home: home)
        let retained = try XCTUnwrap(after.tasks.first?.turns.first)
        XCTAssertEqual(after.tasks.first?.turns.count, 1)
        XCTAssertEqual(retained.startedAt, original.startedAt)
        XCTAssertEqual(retained.endedAt, original.endedAt)
        XCTAssertEqual(retained.samples, original.samples)
        XCTAssertEqual(retained.result, .completed)
        XCTAssertFalse(retained.sourceAvailable)
        let relaunched = try await HistoryIndex(indexURL: file).scan(home: home)
        XCTAssertEqual(relaunched.tasks, after.tasks)
        XCTAssertEqual(relaunched.bytesRead, 0)
    }

    func testOverlappingSuffixUsesRetainedDeltaAndNewAppendsUseReplayedBaseline() async throws {
        let (home, file, log) = try fixture()
        let header = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"thread\"}}\n"
        let text = header + line("task_started", 0, ",\"turn_id\":\"a\"")
            + line("token_count", 1, usage(10, 10)) + line("token_count", 2, ",\"turn_id\":\"a\"" + usage(20))
            + line("task_complete", 3, ",\"turn_id\":\"a\"")
        try text.write(to: log, atomically: true, encoding: .utf8)
        let index = HistoryIndex(indexURL: file)
        let before = try await index.scan(home: home)
        let original = try XCTUnwrap(before.tasks.first?.turns.first)
        let suffix = header + line("token_count", 2, ",\"turn_id\":\"a\"" + usage(20))
            + line("task_complete", 3, ",\"turn_id\":\"a\"")
        try suffix.write(to: log, atomically: true, encoding: .utf8)
        let after = try await index.scan(home: home)
        let merged = try XCTUnwrap(after.tasks.first?.turns.first)
        XCTAssertEqual(merged.samples, original.samples)
        XCTAssertEqual(HistoryTokens.sum(merged.samples.map(\.tokens)).total, 20)
        XCTAssertFalse(merged.hasTokenGap)
        XCTAssertFalse(merged.sourceAvailable)
        try append(line("task_started", 4, ",\"turn_id\":\"b\"") + line("token_count", 5, usage(30))
            + line("task_complete", 6, ",\"turn_id\":\"b\""), to: log)
        let appended = try await index.scan(home: home)
        XCTAssertEqual(appended.tasks[0].turns.first { $0.id == "b" }?.samples.first?.tokens.total, 10)
        XCTAssertEqual(appended.tasks[0].turns.first { $0.id == "a" }?.samples.count, 2)
        try text.write(to: log, atomically: true, encoding: .utf8)
        let restored = try await index.scan(home: home)
        XCTAssertTrue(restored.tasks[0].turns.first { $0.id == "a" }!.sourceAvailable)
        XCTAssertEqual(restored.tasks[0].turns.first { $0.id == "a" }?.samples, original.samples)
    }

    func testReplacementThreadDoesNotBorrowOldThreadTokenBaselineEvidence() async throws {
        let (home, file, log) = try fixture()
        try initial().write(to: log, atomically: true, encoding: .utf8)
        let index = HistoryIndex(indexURL: file)
        _ = try await index.scan(home: home)
        let replacement = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"other-thread\"}}\n"
            + line("task_started", 0, ",\"turn_id\":\"a\"")
            + line("token_count", 1, usage(10)) + line("task_complete", 2, ",\"turn_id\":\"a\"")
        try replacement.write(to: log, atomically: true, encoding: .utf8)
        let next = try await index.scan(home: home)
        let other = try XCTUnwrap(next.tasks.first { $0.id == "other-thread" }?.turns.first)
        XCTAssertTrue(other.hasTokenGap)
        XCTAssertNil(other.samples.first?.tokens.total)
        XCTAssertEqual(next.tasks.first { $0.id == "thread" }?.turns.first?.samples.first?.tokens.total, 10)
    }

    func testRepeatedStartInReplacementCannotEraseEarlierStartOrCompletedResult() async throws {
        let (home, file, log) = try fixture()
        try initial().write(to: log, atomically: true, encoding: .utf8)
        let index = HistoryIndex(indexURL: file)
        let before = try await index.scan(home: home)
        let replacement = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"thread\"}}\n"
            + line("task_started", 1, ",\"turn_id\":\"a\"")
        try replacement.write(to: log, atomically: true, encoding: .utf8)
        let next = try await index.scan(home: home)
        let merged = try XCTUnwrap(next.tasks.first?.turns.first)
        XCTAssertEqual(merged.startedAt, before.tasks[0].turns[0].startedAt)
        XCTAssertEqual(merged.endedAt, before.tasks[0].turns[0].endedAt)
        XCTAssertEqual(merged.result, .completed)
        XCTAssertEqual(merged.samples, before.tasks[0].turns[0].samples)
        XCTAssertFalse(merged.sourceAvailable)
    }

    func testConfiguredRootsNeverMixAndClearRebuildsExistingSources() async throws {
        let (home, file, log) = try fixture()
        try initial().write(to: log, atomically: true, encoding: .utf8)
        let other = home.appendingPathComponent("other"); try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let index = HistoryIndex(indexURL: file)
        _ = try await index.scan(home: home)
        let empty = try await index.scan(home: other); XCTAssertTrue(empty.tasks.isEmpty)
        try await index.clear()
        let rebuilt = try await index.scan(home: home); XCTAssertEqual(rebuilt.tasks.count, 1); XCTAssertGreaterThan(rebuilt.bytesRead, 0)
    }

    func testFileReusedForDifferentThreadPreservesOldTaskWithoutMixingRounds() async throws {
        let (home, file, log) = try fixture()
        try initial().write(to: log, atomically: true, encoding: .utf8)
        let index = HistoryIndex(indexURL: file)
        _ = try await index.scan(home: home)
        let replacement = initial().replacingOccurrences(of: "thread", with: "different-thread")
        try replacement.write(to: log, atomically: true, encoding: .utf8)
        let next = try await index.scan(home: home)
        XCTAssertEqual(Set(next.tasks.map(\.id)), ["thread", "different-thread"])
        XCTAssertFalse(next.tasks.first { $0.id == "thread" }!.sourceAvailable)
        XCTAssertTrue(next.tasks.first { $0.id == "different-thread" }!.sourceAvailable)
        XCTAssertTrue(next.tasks.allSatisfy { $0.turns.count == 1 })
    }

    func testPrivateBodyIsAbsentFromDiskAndIndexUsesOwnerOnlyPermissions() async throws {
        let (home, file, log) = try fixture()
        try (initial() + "{\"type\":\"response_item\",\"payload\":{\"text\":\"SECRET_CREDENTIAL_PROMPT\"}}\n").write(to: log, atomically: true, encoding: .utf8)
        _ = try await HistoryIndex(indexURL: file).scan(home: home)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains("SECRET_CREDENTIAL_PROMPT"))
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testSQLiteMetadataRenamesArchiveAndAllStoredRoundsAreReadWithoutWritingSources() async throws {
        let fixture = try SQLiteFixture(); try fixture.threads()
        let log = fixture.home.appendingPathComponent("record.jsonl")
        try initial().write(to: log, atomically: true, encoding: .utf8)
        try fixture.insert("thread", path: log, archived: true)
        try fixture.execute("CREATE TABLE thread_turns(thread_id TEXT, turn_id TEXT, status TEXT, started_at REAL, completed_at REAL)", database: "thread_history_1")
        try fixture.execute("INSERT INTO thread_turns VALUES('thread','a','inProgress',1791853200,NULL),('thread','db-only','failed',1791853203,1791853204)", database: "thread_history_1")
        let index = HistoryIndex(indexURL: fixture.home.appendingPathComponent("own/index.json"))
        let original = try Data(contentsOf: log)
        let first = try await index.scan(home: fixture.home)
        XCTAssertEqual(first.tasks[0].title, "Fixture"); XCTAssertTrue(first.tasks[0].archived)
        XCTAssertEqual(first.tasks[0].turns.count, 2)
        XCTAssertEqual(first.tasks[0].turns.first { $0.id == "a" }?.result, .completed)
        XCTAssertEqual(first.tasks[0].turns.first { $0.id == "db-only" }?.result, .failed)
        try fixture.execute("UPDATE threads SET title='Renamed'")
        let renamed = try await index.scan(home: fixture.home)
        XCTAssertEqual(renamed.tasks[0].title, "Renamed"); XCTAssertEqual(renamed.bytesRead, 0)
        XCTAssertEqual(try Data(contentsOf: log), original)
    }

    func testInternalDatabaseEntriesStayExcludedEvenWhenLogHasNoModel() async throws {
        let fixture = try SQLiteFixture(); try fixture.threads()
        let log = fixture.home.appendingPathComponent("sessions/auto.jsonl")
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try initial().write(to: log, atomically: true, encoding: .utf8)
        try fixture.insert("thread", path: log, model: "codex-auto-review")
        let next = try await HistoryIndex(indexURL: fixture.home.appendingPathComponent("own/index.json")).scan(home: fixture.home)
        XCTAssertTrue(next.tasks.isEmpty)
    }

    func testCorruptIndexFailsClearlyAndExplicitClearRecovers() async throws {
        let (home, file, log) = try fixture()
        try initial().write(to: log, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not an index".utf8).write(to: file)
        let index = HistoryIndex(indexURL: file)
        do { _ = try await index.scan(home: home); XCTFail("Corrupt index must not silently replace retained evidence") }
        catch { XCTAssertTrue(error is MonitorFailure) }
        try await index.clear()
        let rebuilt = try await index.scan(home: home); XCTAssertEqual(rebuilt.tasks.count, 1)
    }

    func testCopiedPathsUseLatestUnfinishedEvidenceDeterministically() async throws {
        let (home, file, log) = try fixture()
        let other = log.deletingLastPathComponent().appendingPathComponent("copy.jsonl")
        let open = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"thread\"}}\n"
            + line("task_started", 0, ",\"turn_id\":\"a\"")
        try open.write(to: other, atomically: true, encoding: .utf8)
        try (open + line("task_started", 3, ",\"turn_id\":\"b\"")).write(to: log, atomically: true, encoding: .utf8)
        for _ in 0..<3 {
            let snapshot = try await HistoryIndex(indexURL: file).scan(home: home)
            XCTAssertEqual(snapshot.tasks.count, 1)
            XCTAssertEqual(snapshot.tasks[0].turns.first { $0.id == "a" }?.result, .unknown)
        }
    }

    func testDatabaseOnlyRoundsDoNotBorrowLatestModel() {
        var p = parser(); p.currentModel = "current-model"
        p.mergeStoredTurn(id: "historic", start: Date(timeIntervalSince1970: 1), end: Date(timeIntervalSince1970: 2), result: .completed)
        XCTAssertNil(p.task.turns[0].model)
    }

    private func legacyRound() -> String {
        "{\"type\":\"session_meta\",\"payload\":{\"id\":\"thread\"}}\n"
            + "{\"type\":\"turn_context\",\"payload\":{\"model\":\"historic\"}}\n"
            + "{\"type\":\"event_msg\",\"timestamp\":\"2026-10-13T01:00:00.250Z\",\"payload\":{\"type\":\"task_started\",\"started_at\":1791853200}}\n"
            + line("token_count", 1, usage(10, 10))
            + "{\"type\":\"event_msg\",\"timestamp\":\"2026-10-13T01:00:01.750Z\",\"payload\":{\"type\":\"task_complete\"}}\n"
    }

    func testLegacyMissingIDUsesDatabaseIdentityAndPreservesPreciseUsage() {
        var p = parser(); apply(legacyRound(), to: &p)
        p.mergeStoredTurn(id: "canonical", start: Date(timeIntervalSince1970: 1791853200),
            end: Date(timeIntervalSince1970: 1791853201), result: .completed)
        XCTAssertEqual(p.task.turns.count, 1)
        XCTAssertEqual(p.task.turns[0].id, "canonical")
        XCTAssertEqual(p.task.turns[0].duration, 1.5)
        XCTAssertEqual(p.task.turns[0].model, "historic")
        XCTAssertEqual(p.task.turns[0].samples.count, 1)
        XCTAssertEqual(p.task.turns[0].samples[0].tokens.total, 10)
        p.mergeStoredTurn(id: "canonical", start: Date(timeIntervalSince1970: 1791853200),
            end: Date(timeIntervalSince1970: 1791853201), result: .completed)
        XCTAssertEqual(p.task.turns.count, 1)
    }

    func testMergedOpenLegacyRoundKeepsLaterEventsOnCanonicalIdentity() {
        var p = parser()
        apply("{\"type\":\"event_msg\",\"timestamp\":\"2026-10-13T01:00:00.250Z\",\"payload\":{\"type\":\"task_started\"}}\n", to: &p)
        p.mergeStoredTurn(id: "canonical", start: Date(timeIntervalSince1970: 1791853200), end: nil, result: .running)
        XCTAssertEqual(p.activeTurnID, "canonical")
        apply(line("token_count", 1, usage(10, 10)) + line("task_complete", 2), to: &p)
        XCTAssertEqual(p.task.turns.count, 1)
        XCTAssertEqual(p.task.turns[0].id, "canonical")
        XCTAssertEqual(p.task.turns[0].result, .completed)
        XCTAssertEqual(p.task.turns[0].samples[0].tokens.total, 10)
    }

    func testLegacyMergeDoesNotCombineKnownIDsOrAmbiguousSameSecondRounds() {
        let start = Date(timeIntervalSince1970: 1791853200)
        let end = start.addingTimeInterval(1)
        for ids in [["known-a", "known-b"], ["unidentified-0", "unidentified-100"]] {
            var p = parser()
            p.task.turns = ids.enumerated().map { index, id in
                HistoryTurn(id: id, startedAt: start.addingTimeInterval(index == 0 ? 0.25 : 0.5),
                    endedAt: end.addingTimeInterval(index == 0 ? 0.25 : 0.5), result: .completed)
            }
            p.mergeStoredTurn(id: "different", start: start, end: end, result: .completed)
            XCTAssertEqual(p.task.turns.count, 3)
        }
        var p = parser()
        p.task.turns = [HistoryTurn(id: "unidentified-0", startedAt: start.addingTimeInterval(0.25), endedAt: end, result: .completed)]
        p.mergeStoredTurn(id: "different", start: start.addingTimeInterval(0.5), end: end, result: .completed)
        XCTAssertEqual(p.task.turns.count, 2, "Two distinct precise times must not match solely by second")
        p.mergeStoredTurn(id: "different", start: start, end: end, result: .completed)
        XCTAssertEqual(p.task.turns.count, 2, "Rounded database times must not erase conflicting precise log evidence")
    }

    func testCachedLegacyDuplicateIsRepairedWithoutLosingSamples() throws {
        var p = parser(); apply(legacyRound(), to: &p)
        var duplicate = p.task.turns[0]
        duplicate.id = "canonical"
        duplicate.startedAt = Date(timeIntervalSince1970: 1791853200)
        duplicate.endedAt = Date(timeIntervalSince1970: 1791853201)
        duplicate.model = nil
        p.task.turns.insert(duplicate, at: 0)
        p = try JSONDecoder().decode(HistoryParser.self, from: JSONEncoder().encode(p))
        p.mergeStoredTurn(id: "canonical", start: duplicate.startedAt, end: duplicate.endedAt, result: .completed)
        XCTAssertEqual(p.task.turns.count, 1)
        XCTAssertEqual(p.task.turns[0].id, "canonical")
        XCTAssertEqual(p.task.turns[0].duration, 1.5)
        XCTAssertEqual(p.task.turns[0].samples.count, 1)
        XCTAssertEqual(p.task.turns[0].samples[0].tokens.total, 10)
    }

    func testCopiedLegacyLogsAndDatabaseAreOneRoundAcrossIncrementalAndColdScans() async throws {
        let fixture = try SQLiteFixture(); try fixture.threads()
        let canonical = fixture.home.appendingPathComponent("canonical.jsonl")
        let archive = fixture.home.appendingPathComponent("archived_sessions/copy.jsonl")
        try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
        try legacyRound().write(to: canonical, atomically: true, encoding: .utf8)
        try ("{\"type\":\"response_item\"}\n" + legacyRound()).write(to: archive, atomically: true, encoding: .utf8)
        try fixture.insert("thread", path: canonical)
        try fixture.execute("CREATE TABLE thread_turns(thread_id TEXT, turn_id TEXT, status TEXT, started_at REAL, completed_at REAL)", database: "thread_history_1")
        try fixture.execute("INSERT INTO thread_turns VALUES('thread','canonical','completed',1791853200,1791853201)", database: "thread_history_1")
        let file = fixture.home.appendingPathComponent("own/index.json")
        let index = HistoryIndex(indexURL: file)
        let first = try await index.scan(home: fixture.home)
        let incremental = try await index.scan(home: fixture.home)
        let cold = try await HistoryIndex(indexURL: file).scan(home: fixture.home)
        for snapshot in [first, incremental, cold] {
            XCTAssertEqual(snapshot.tasks.count, 1)
            XCTAssertEqual(snapshot.tasks[0].turns.count, 1)
            let turn = snapshot.tasks[0].turns[0]
            XCTAssertEqual(turn.id, "canonical"); XCTAssertEqual(turn.duration, 1.5)
            XCTAssertEqual(turn.samples.count, 1); XCTAssertEqual(turn.samples[0].tokens.total, 10)
            let interval = DateInterval(start: Date(timeIntervalSince1970: 1791853200), duration: 60)
            let report = DashboardStatistics.report(snapshot: snapshot, interval: interval, period: .day)
            XCTAssertEqual(report.metrics.normal, 1); XCTAssertEqual(report.metrics.elapsed, 1.5)
            XCTAssertEqual(report.metrics.tokens.total, 10)
        }
        XCTAssertEqual(incremental.bytesRead, 0); XCTAssertEqual(cold.bytesRead, 0)
        XCTAssertEqual(try String(contentsOf: canonical, encoding: .utf8), legacyRound())
        XCTAssertEqual(try String(contentsOf: archive, encoding: .utf8), "{\"type\":\"response_item\"}\n" + legacyRound())
    }

    func testCopiedDatabasePathCannotErasePreciseLogTimeOrModel() async throws {
        let fixture = try SQLiteFixture(); try fixture.threads()
        let canonical = fixture.home.appendingPathComponent("canonical.jsonl")
        let archive = fixture.home.appendingPathComponent("archived_sessions/copy.jsonl")
        try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
        let meta = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"thread\"}}\n"
        try (meta + "{\"type\":\"turn_context\",\"payload\":{\"model\":\"current\"}}\n").write(to: canonical, atomically: true, encoding: .utf8)
        let precise = meta + "{\"type\":\"turn_context\",\"payload\":{\"model\":\"historic\"}}\n"
            + "{\"type\":\"event_msg\",\"timestamp\":\"2026-10-13T01:00:00.250Z\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"a\"}}\n"
            + "{\"type\":\"event_msg\",\"timestamp\":\"2026-10-13T01:00:01.750Z\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"a\"}}\n"
        try precise.write(to: archive, atomically: true, encoding: .utf8)
        try fixture.insert("thread", path: canonical)
        try fixture.execute("CREATE TABLE thread_turns(thread_id TEXT, turn_id TEXT, status TEXT, started_at REAL, completed_at REAL)", database: "thread_history_1")
        try fixture.execute("INSERT INTO thread_turns VALUES('thread','a','completed',1791853200,1791853201)", database: "thread_history_1")
        for _ in 0..<3 {
            let snapshot = try await HistoryIndex(indexURL: fixture.home.appendingPathComponent("own/index.json")).scan(home: fixture.home)
            XCTAssertEqual(snapshot.tasks[0].turns.count, 1)
            XCTAssertEqual(snapshot.tasks[0].turns[0].duration, 1.5)
            XCTAssertEqual(snapshot.tasks[0].turns[0].model, "historic")
        }
    }

    func testLegacyPromptTitleIsStoredOnlyAsBoundedSingleLineLabel() async throws {
        let fixture = try SQLiteFixture(); try fixture.threads()
        let log = fixture.home.appendingPathComponent("record.jsonl")
        try initial().write(to: log, atomically: true, encoding: .utf8)
        try fixture.insert("thread", path: log)
        try fixture.execute("UPDATE threads SET title='Short title\nPRIVATE_PROMPT_BODY'")
        let file = fixture.home.appendingPathComponent("own/index.json")
        let snapshot = try await HistoryIndex(indexURL: file).scan(home: fixture.home)
        XCTAssertEqual(snapshot.tasks[0].title, "Short title…")
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("PRIVATE_PROMPT_BODY"))
        XCTAssertEqual(TaskText.historyTitle(name: String(repeating: "x", count: 300), title: nil).count, 241)
    }
}

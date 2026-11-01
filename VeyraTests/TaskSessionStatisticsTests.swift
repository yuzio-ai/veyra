import XCTest
import Foundation

final class TaskSessionStatisticsTests: XCTestCase {
    private func tool(_ id: String, _ start: String, _ end: String, type: String = "CommandExecution",
                      thread: String = "root", turn: String = "t", status: String = "completed") -> String {
        #"{"type":"event_msg","payload":{"type":"item_completed","thread_id":"\#(thread)","turn_id":"\#(turn)","started_at_ms":\#(start),"completed_at_ms":\#(end),"item":{"type":"\#(type)","id":"\#(id)","status":"\#(status)"}}}"# + "\n"
    }
    private func completed(_ turn: String, _ ttft: String, kind: String = "task_complete", error: String = "null") -> String {
        #"{"type":"event_msg","payload":{"type":"\#(kind)","turn_id":"\#(turn)","time_to_first_token_ms":\#(ttft),"error":\#(error)}}"# + "\n"
    }
    private func owner(_ turn: String, thread: String = "root", kind: String = "item_started") -> String {
        #"{"type":"event_msg","payload":{"type":"\#(kind)","thread_id":"\#(thread)","turn_id":"\#(turn)","item":{"type":"AgentMessage","id":"message-\#(turn)"}}}"# + "\n"
    }
    private func ledger(_ text: String) -> TaskSessionStatistics {
        var ledger = TaskSessionLedger(threadID: "root")
        for line in text.split(separator: "\n") { ledger.apply(Data(line.utf8)) }
        return ledger.result()
    }
    private func file(_ text: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("rollout.jsonl")
        try Data(text.utf8).write(to: url)
        return url
    }
    private func append(_ text: String, to url: URL) throws {
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.seekToEnd(); try file.write(contentsOf: Data(text.utf8))
    }

    func testParallelNestedDuplicateAndFailedToolsCountTheirUnion() {
        let text = tool("a", "1000", "5000") + tool("b", "2000", "3000", type: "McpToolCall")
            + tool("a", "1000", "5000") + tool("c", "4000", "8000", status: "failed")
            + tool("a", "9000", "10000", turn: "next")
        XCTAssertEqual(ledger(text).toolMilliseconds, 8_000)
    }

    func testMeanUsesOnlySuccessfulReportedCompletedTurnsAndDeduplicates() {
        let ownership = ["a", "b", "cancel", "failed", "missing", "fractional", "negative"].map { owner($0) }.joined()
        let text = ownership + completed("a", "1000") + completed("a", "1000") + completed("b", "3000")
            + completed("cancel", "9999", kind: "turn_aborted")
            + completed("failed", "9999", error: #"{"message":"fixture"}"#)
            + completed("missing", "null") + completed("fractional", "1.5") + completed("negative", "-1")
        XCTAssertEqual(ledger(text).meanTTFTMilliseconds, 2_000)
        XCTAssertEqual(ledger(text).ttftSampleCount, 2)
        XCTAssertEqual(ledger(owner("zero") + completed("zero", "0")).meanTTFTMilliseconds, 0)
        XCTAssertEqual(ledger(owner("a") + completed("a", "1000") + completed("a", "0", kind: "turn_failed")).ttftSampleCount, 0)
    }

    func testCopiedForkHistoryAndUnknownTurnsDoNotContributeSamples() {
        let headers = #"{"type":"session_meta","payload":{"id":"root","forked_from_id":"parent"}}"# + "\n"
            + #"{"type":"session_meta","payload":{"id":"parent"}}"# + "\n"
        let result = ledger(headers + owner("parent-turn", thread: "parent", kind: "item_completed")
            + completed("parent-turn", "10000") + owner("current-turn", kind: "item_completed")
            + completed("current-turn", "1000") + completed("unknown", "99999"))
        XCTAssertEqual(result.ttftSampleCount, 1)
        XCTAssertEqual(result.meanTTFTMilliseconds, 1_000)
        XCTAssertNil(result.toolMilliseconds) // Agent messages establish ownership without becoming tools.
        XCTAssertEqual(ledger(headers + completed("unknown", "1000")).ttftSampleCount, 0)
        XCTAssertNil(ledger(completed("unknown", "1000")).meanTTFTMilliseconds)
    }

    func testConflictingOwnershipIsExcludedRegardlessOfEventOrder() {
        for evidence in [owner("t") + owner("t", thread: "other"),
                         owner("t", thread: "other") + owner("t")] {
            // More evidence from the requested task must not undo a conflict.
            let result = ledger(evidence + owner("t") + completed("t", "1000"))
            XCTAssertEqual(result.ttftSampleCount, 0)
            XCTAssertNil(result.meanTTFTMilliseconds)
        }
    }

    func testTerminalEventsCanSupplyOwnershipAndLatestResultWins() {
        for kind in ["task_complete", "task_completed", "turn_complete"] {
            let direct = #"{"type":"event_msg","payload":{"type":"\#(kind)","thread_id":"root","turn_id":"t","time_to_first_token_ms":1000}}"# + "\n"
            XCTAssertEqual(ledger(direct).ttftSampleCount, 1)
            XCTAssertEqual(ledger(direct + completed("t", "3000")).meanTTFTMilliseconds, 3_000)
            for end in [completed("t", "1000", kind: "turn_aborted"),
                        completed("t", "1000", kind: "task_failed"),
                        completed("t", "1000", error: #"{"message":"fixture"}"#), completed("t", "null")] {
                XCTAssertEqual(ledger(direct + end + owner("t")).ttftSampleCount, 0)
            }
        }
    }

    func testInvalidTimesNonToolItemsAndOtherThreadsAreExcluded() {
        var text = ""
        for type in ["UserMessage", "AgentMessage", "Reasoning", "Plan", "SubAgentActivity", "ContextCompaction", "Unknown"] {
            text += tool(type, "1000", "5000", type: type)
        }
        text += tool("child", "1000", "5000", thread: "child")
        text += tool("running", "1000", "5000", status: "in_progress")
        for (start, end) in [("null", "5000"), ("1000", "0"), ("-1", "5000"), ("1.5", "5000"), ("0", "5000")] {
            text += tool("bad", start, end)
        }
        XCTAssertNil(ledger(text).toolMilliseconds)
        XCTAssertNil(ledger(text).meanTTFTMilliseconds)
        XCTAssertEqual(ledger(tool("zero", "1000", "1000")).toolMilliseconds, 0)
        XCTAssertTrue(ledger("broken item_completed\n").historyUnreadable)
    }

    func testReadIsIncrementalAndBuffersPartialLineWithoutRecounting() async throws {
        let initial = tool("a", "1000", "5000", turn: "a") + completed("a", "1000")
        let url = try file(initial)
        let reader = TaskSessionStatisticsReader()
        let first = try await reader.read(url: url, threadID: "root")
        let bytes = await reader.lastReadByteCount
        XCTAssertEqual(bytes, initial.utf8.count)
        XCTAssertEqual(first.toolMilliseconds, 4_000)
        _ = try await reader.read(url: url, threadID: "root")
        let unchanged = await reader.lastReadByteCount
        let opens = await reader.lastOpenCount
        XCTAssertEqual(unchanged, 0); XCTAssertEqual(opens, 0)
        let next = tool("b", "4000", "8000", turn: "b") + completed("b", "3000")
        try append(String(next.dropLast()), to: url)
        let partial = try await reader.read(url: url, threadID: "root")
        XCTAssertEqual(partial.ttftSampleCount, 1)
        XCTAssertEqual(partial.toolMilliseconds, 7_000)
        try append("\n", to: url)
        let updated = try await reader.read(url: url, threadID: "root")
        let added = await reader.lastReadByteCount
        XCTAssertEqual(added, 1)
        XCTAssertEqual(updated.meanTTFTMilliseconds, 2_000)
        let cold = try await TaskSessionStatisticsReader().read(url: url, threadID: "root")
        XCTAssertEqual(updated, cold)
        let child = try await reader.read(url: url, threadID: "child")
        XCTAssertNil(child.toolMilliseconds)
        XCTAssertNil(child.meanTTFTMilliseconds)
        XCTAssertEqual(child.ttftSampleCount, 0)
    }

    func testLateOwnershipAcrossChunksAndPartialAppendsMatchesColdRead() async throws {
        let padding = String(repeating: #"{"type":"response_item","payload":{}}"# + "\n", count: 8_000)
        let url = try file(completed("t", "1000") + padding)
        let reader = TaskSessionStatisticsReader()
        let unknown = try await reader.read(url: url, threadID: "root")
        XCTAssertEqual(unknown.ttftSampleCount, 0)
        let evidence = owner("t")
        try append(String(evidence.dropLast()), to: url)
        let partial = try await reader.read(url: url, threadID: "root")
        XCTAssertEqual(partial.ttftSampleCount, 0)
        try append("\n", to: url)
        let confirmed = try await reader.read(url: url, threadID: "root")
        XCTAssertEqual(confirmed.meanTTFTMilliseconds, 1_000)
        let bytes = await reader.lastReadByteCount
        XCTAssertEqual(bytes, 1)
        let cold = try await TaskSessionStatisticsReader().read(url: url, threadID: "root")
        XCTAssertEqual(confirmed, cold)
        try append(owner("t", thread: "parent"), to: url)
        let conflicted = try await reader.read(url: url, threadID: "root")
        XCTAssertEqual(conflicted.ttftSampleCount, 0)
    }

    func testReplacementAndTruncationResetStatistics() async throws {
        let url = try file(owner("old") + completed("old", "1000"))
        let reader = TaskSessionStatisticsReader()
        _ = try await reader.read(url: url, threadID: "root")
        // Reusing the turn ID without new evidence must not reuse its former owner.
        try Data(completed("old", "3000").utf8).write(to: url, options: .atomic)
        let replaced = try await reader.read(url: url, threadID: "root")
        XCTAssertNil(replaced.toolMilliseconds)
        XCTAssertNil(replaced.meanTTFTMilliseconds)
        try append(owner("old"), to: url)
        let reowned = try await reader.read(url: url, threadID: "root")
        XCTAssertEqual(reowned.meanTTFTMilliseconds, 3_000)
        try Data().write(to: url)
        let truncated = try await reader.read(url: url, threadID: "root")
        XCTAssertEqual(truncated.ttftSampleCount, 0)
        XCTAssertNil(truncated.meanTTFTMilliseconds)
        try append(completed("old", "1000"), to: url)
        let afterTruncation = try await reader.read(url: url, threadID: "root")
        XCTAssertEqual(afterTruncation.ttftSampleCount, 0)
    }

    func testCancelledRequestDoesNotPublishCursor() async throws {
        let initial = owner("a") + completed("a", "1000")
        let url = try file(initial)
        let reader = TaskSessionStatisticsReader()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await reader.read(url: url, threadID: "root")
        }
        do { _ = try await cancelled.value; XCTFail("expected cancellation") }
        catch is CancellationError { }
        let result = try await reader.read(url: url, threadID: "root")
        let bytes = await reader.lastReadByteCount
        XCTAssertEqual(bytes, initial.utf8.count)
        XCTAssertEqual(result.ttftSampleCount, 1)
    }
}

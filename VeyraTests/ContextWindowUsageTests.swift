import XCTest
import Foundation

final class ContextWindowUsageTests: XCTestCase {
    private func model(_ name: String) -> String {
        #"{"type":"turn_context","payload":{"model":"\#(name)"}}"#
    }
    private func token(_ used: String = "230000", window: String = "1000000") -> String {
        #"{"type":"event_msg","timestamp":"2026-11-01T01:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":9000000},"last_token_usage":{"total_tokens":\#(used)},"model_context_window":\#(window)}}}"#
    }
    private func state(_ lines: [String], reverse: Bool) -> RolloutState {
        var state = RolloutState()
        for line in reverse ? Array(lines.reversed()) : lines {
            RolloutEvent.apply(Data(line.utf8), to: &state, newestFirst: reverse)
        }
        return state
    }

    func testLatestSnapshotIsIndependentFromCumulativeTokensAndMatchesBothScanDirections() {
        for reverse in [false, true] {
            let result = state([model("a"), token(), token("120000", window: "475000")], reverse: reverse)
            XCTAssertEqual(result.usage?.total, 9_000_000)
            XCTAssertEqual(result.context.usage?.used, 120_000)
            XCTAssertEqual(result.context.usage?.window, 475_000)
            XCTAssertEqual(result.context.usage?.recordedAt, RolloutEvent.timestamp("2026-11-01T01:00:00Z"))
        }
        XCTAssertEqual(ContextWindowUsage(used: 230_000, window: 1_000_000)?.percent, 23)
        XCTAssertEqual(ContextWindowUsage(used: 200, window: 100)?.percent, 200)
        XCTAssertEqual(ContextWindowUsage(used: 0, window: 100)?.percent, 0)
    }

    func testInvalidLatestSnapshotDoesNotResurrectOlderValidData() {
        for reverse in [false, true] {
            for bad in [token("null"), token("-1"), token("1.5"), token("1", window: "0"),
                        token("1", window: "null"), token("1", window: "1.5"), token("9223372036854775808")] {
                XCTAssertNil(state([model("a"), token(), bad], reverse: reverse).context.usage)
            }
            let quotaOnly = #"{"type":"event_msg","payload":{"type":"token_count","info":null}}"#
            XCTAssertEqual(state([model("a"), token(), quotaOnly], reverse: reverse).context.usage?.used, 230_000)
            let legacy = #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":100}}}}"#
            XCTAssertNil(state([model("a"), token(), legacy], reverse: reverse).context.usage)
        }
    }

    func testModelSwitchAndCompactionInvalidateUntilNewSnapshot() {
        let compacted = #"{"type":"compacted","payload":{}}"#
        let completed = #"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"ContextCompaction"}}}"#
        for reverse in [false, true] {
            for reset in [[model("b")], [model("b"), model("a")], [compacted], [completed]] {
                let lines = [model("a"), token()] + reset
                XCTAssertNil(state(lines, reverse: reverse).context.usage)
                XCTAssertEqual(state(lines + [token("12000")], reverse: reverse).context.usage?.used, 12_000)
            }
            XCTAssertEqual(state([model("a"), token(), model("a")], reverse: reverse).context.usage?.used, 230_000)
            XCTAssertNil(state([token(), model("a")], reverse: reverse).context.usage)
        }
    }

    func testColdAndIncrementalReadsAgreeAcrossModelBoundaryAndPartialLine() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("rollout.jsonl")
        let started = #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn"}}"#
        let filler = String(repeating: #"{"type":"response_item","payload":{}}"# + "\n", count: 10_000)
        try Data(([started, model("a"), token()].joined(separator: "\n") + "\n" + filler + model("b") + "\n").utf8).write(to: url)
        var reader = RolloutReader()
        XCTAssertNil(try reader.read(url).context.usage)
        XCTAssertGreaterThan(reader.lastReadByteCount, 256 * 1_024)
        let next = token("1000", window: "2000")
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: Data(next.utf8))
        XCTAssertNil(try reader.read(url).context.usage)
        try handle.write(contentsOf: Data("\n".utf8))
        let updated = try reader.read(url)
        XCTAssertEqual(updated.context.usage?.percent, 50)
        XCTAssertEqual(reader.lastReadByteCount, 1)
        var cold = RolloutReader()
        XCTAssertEqual(updated.context.usage, try cold.read(url).context.usage)
        _ = try reader.read(url)
        XCTAssertEqual(reader.lastReadByteCount, 0)
        let snapshot = TaskResolver.resolve(metadata: ThreadMetadata(id: "root", title: "fixture", rolloutPath: url.path,
            model: nil, source: "cli", updatedAt: .now, tokens: 0), rollout: updated,
            storedTurn: nil, evidence: ProcessEvidence(threadIDs: ["root"]))
        XCTAssertEqual(snapshot?.contextUsage, updated.context.usage)
        XCTAssertEqual(snapshot?.rolloutModifiedAt, updated.modifiedAt)
    }
}

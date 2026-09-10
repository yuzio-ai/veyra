import XCTest
import Foundation

final class RolloutReaderTests: XCTestCase {
    private let start = #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn"}}"# + "\n"
    private let model = #"{"type":"turn_context","payload":{"model":"log-model"}}"# + "\n"
    private let token = #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":123}}}}"# + "\n"
    private var filler: String {
        String(repeating: #"{"type":"response_item","payload":{"text":"ignored fixture"}}"# + "\n", count: 12_000)
    }

    private func file(_ text: String) throws -> URL {
        try file(Data(text.utf8))
    }

    private func file(_ data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("rollout.jsonl")
        try data.write(to: url)
        return url
    }

    private func append(_ text: String, to url: URL) throws {
        try append(Data(text.utf8), to: url)
    }

    private func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func context(byteCount: Int) -> Data {
        let prefix = #"{"type":"turn_context","payload":{"model":"new-model","developer_instructions":""#
        let suffix = "\"}}"
        return Data((prefix + String(repeating: "x", count: byteCount - prefix.utf8.count - suffix.utf8.count) + suffix).utf8)
    }

    func testInitialPartialLineAcrossChunkBoundariesRecoversWithOnlyAppendedBytes() throws {
        let chunk = 256 * 1_024
        for size in [chunk - 1, chunk, chunk + 1, chunk * 2 + 37] {
            for atFileStart in [false, true] {
                let prefix = atFileStart ? Data() : Data((start + model + token).utf8)
                let url = try file(prefix + context(byteCount: size))
                var reader = RolloutReader()
                XCTAssertEqual(try reader.read(url).model, atFileStart ? nil : "log-model")
                _ = try reader.read(url)
                XCTAssertEqual(reader.lastReadByteCount, 0)
                XCTAssertEqual(reader.lastOpenCount, 0)
                try append("\n", to: url)
                let completed = try reader.read(url)
                XCTAssertEqual(completed.model, "new-model", "partial bytes: \(size), at start: \(atFileStart)")
                XCTAssertEqual(reader.lastReadByteCount, 1)
                var fresh = RolloutReader()
                XCTAssertEqual(completed.model, try fresh.read(url).model)
                _ = try reader.read(url)
                XCTAssertEqual(reader.lastReadByteCount, 0)
                XCTAssertEqual(reader.lastOpenCount, 0)
            }
        }
    }

    func testUTF8PartialLineSpanningSeveralChunksAndAppendsRemainsIntact() throws {
        let prefix = #"{"type":"turn_context","payload":{"developer_instructions":""# + String(repeating: "中", count: 200_000)
        let line = Data((prefix + "\",\"model\":\"新模型🧪\"}}\n").utf8)
        let emoji = try XCTUnwrap(line.range(of: Data("🧪".utf8)))
        let cut = emoji.lowerBound + 2
        let initial = Data(line.prefix(cut))
        let url = try file(Data((start + model + token).utf8) + initial)
        var reader = RolloutReader()
        XCTAssertEqual(try reader.read(url).model, "log-model")
        try append(Data(line[cut..<(cut + 1)]), to: url)
        XCTAssertEqual(try reader.read(url).model, "log-model")
        XCTAssertEqual(reader.lastReadByteCount, 1)
        let remainder = Data(line[(cut + 1)...])
        try append(remainder, to: url)
        XCTAssertEqual(try reader.read(url).model, "新模型🧪")
        XCTAssertEqual(reader.lastReadByteCount, remainder.count)
    }

    func testQuotaTailSkipsMissingPrefixThenTaskUpgradeRestoresTheOmittedRecord() throws {
        // Whitespace makes the suffix independently valid JSON, but it is still an
        // unattributed fragment of a line whose beginning lies outside the budget.
        let quota = #"{"type":"event_msg","timestamp":"2026-09-03T01:00:00Z","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":70}}}}"#
        let url = try file(String(repeating: " ", count: 300_000) + quota)
        var reader = RolloutReader()
        XCTAssertTrue(try reader.read(url, quotaOnly: true).quotaBuckets.isEmpty)
        XCTAssertEqual(reader.lastReadByteCount, 256 * 1_024)
        _ = try reader.read(url, quotaOnly: true)
        XCTAssertEqual(reader.lastReadByteCount, 0)
        XCTAssertEqual(reader.lastOpenCount, 0)
        try append(" ", to: url)
        XCTAssertTrue(try reader.read(url, quotaOnly: true).quotaBuckets.isEmpty)
        XCTAssertEqual(reader.lastReadByteCount, 1)
        let next = quota.replacingOccurrences(of: "codex", with: "spark")
        let added = "\n" + start + model + token + next + "\n"
        try append(added, to: url)
        let tail = try reader.read(url, quotaOnly: true)
        XCTAssertNil(tail.quotaBuckets["codex"])
        XCTAssertNotNil(tail.quotaBuckets["spark"])
        XCTAssertEqual(tail.model, "log-model")
        XCTAssertNotNil(tail.usage)
        XCTAssertNotNil(tail.boundary)
        XCTAssertEqual(reader.lastReadByteCount, added.utf8.count)
        _ = try reader.read(url, quotaOnly: true)
        XCTAssertEqual(reader.lastReadByteCount, 0)
        XCTAssertEqual(reader.lastOpenCount, 0)
        // Complete lifecycle fields must not hide the earlier skipped record.
        let restored = try reader.read(url)
        XCTAssertEqual(restored.quotaBuckets["codex"]?.windows.first?.remainingPercent, 30)
        XCTAssertEqual(restored.quotaBuckets["spark"], tail.quotaBuckets["spark"])
        XCTAssertGreaterThan(reader.lastReadByteCount, 256 * 1_024)
        _ = try reader.read(url)
        XCTAssertEqual(reader.lastReadByteCount, 0)
        XCTAssertEqual(reader.lastOpenCount, 0)
    }

    private func quotaLine(_ limitID: String, used: Int, date: String) -> String {
        #"{"type":"event_msg","timestamp":""# + date + #"","payload":{"type":"token_count","rate_limits":{"limit_id":""# +
            limitID + #"","primary":{"used_percent":\#(used),"window_minutes":300}}}}"#
    }

    func testReverseQuotaScanAttributesEventsToTheirTurnModel() throws {
        // Reverse scans meet the quota event before the turn_context it belongs to.
        let context = #"{"type":"turn_context","payload":{"model":"gpt-5.3-codex-spark"}}"#
        let url = try file(context + "\n" + quotaLine("codex", used: 7, date: "2026-09-03T01:00:00Z") + "\n")
        var reader = RolloutReader()
        let state = try reader.read(url, quotaOnly: true)
        XCTAssertEqual(state.quotaBuckets["codex"]?.model, "gpt-5.3-codex-spark")
        XCTAssertEqual(state.quotaBuckets["codex"]?.windows.first?.remainingPercent, 93)
    }

    func testReverseQuotaScanSeparatesModelsAcrossTurns() throws {
        let url = try file(#"{"type":"turn_context","payload":{"model":"model-a"}}"# + "\n" +
                           quotaLine("codex", used: 20, date: "2026-09-03T01:00:00Z") + "\n" +
                           #"{"type":"turn_context","payload":{"model":"model-b"}}"# + "\n" +
                           quotaLine("premium", used: 7, date: "2026-09-03T01:05:00Z") + "\n")
        var reader = RolloutReader()
        let state = try reader.read(url, quotaOnly: true)
        XCTAssertEqual(state.quotaBuckets["codex"]?.model, "model-a")
        XCTAssertEqual(state.quotaBuckets["premium"]?.model, "model-b")
    }

    func testQuotaTailWithoutTurnContextFallsBackToModelHint() throws {
        let url = try file(quotaLine("codex", used: 7, date: "2026-09-03T01:00:00Z") + "\n")
        var hinted = RolloutReader()
        let state = try hinted.read(url, quotaOnly: true, modelHint: "gpt-5.3-codex-spark")
        XCTAssertEqual(state.quotaBuckets["codex"]?.model, "gpt-5.3-codex-spark")
        var plain = RolloutReader()
        XCTAssertNil(try plain.read(url, quotaOnly: true).quotaBuckets["codex"]?.model)
    }

    func testIncrementalReadsAttributeQuotaToTheLatestTurnModel() throws {
        let url = try file(#"{"type":"turn_context","payload":{"model":"model-a"}}"# + "\n")
        var reader = RolloutReader()
        _ = try reader.read(url, quotaOnly: true)
        try append(quotaLine("codex", used: 7, date: "2026-09-03T01:00:00Z") + "\n", to: url)
        XCTAssertEqual(try reader.read(url, quotaOnly: true).quotaBuckets["codex"]?.model, "model-a")
        try append(#"{"type":"turn_context","payload":{"model":"model-b"}}"# + "\n" +
                   quotaLine("codex", used: 9, date: "2026-09-03T01:05:00Z") + "\n", to: url)
        let state = try reader.read(url, quotaOnly: true)
        XCTAssertEqual(state.quotaBuckets["codex"]?.model, "model-b")
        XCTAssertEqual(state.quotaBuckets["codex"]?.windows.first?.remainingPercent, 91)
    }

    func testTaskUpgradeRescanKeepsCachedModelAttributionOnTie() throws {
        // The upgraded task read rescans from the tail; the quota record it
        // buffers before reaching any turn_context flushes with no model and
        // must not replace the identical cached record's attribution.
        let chunk = 256 * 1_024
        let contextA = #"{"type":"turn_context","payload":{"model":"model-a"}}"# + "\n"
        let quota = #"{"type":"event_msg","timestamp":"2026-09-03T01:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":5}},"rate_limits":{"limit_id":"codex","primary":{"used_percent":7,"window_minutes":300}}}}"# + "\n"
        let contextB = #"{"type":"turn_context","payload":{"model":"model-b"}}"# + "\n"
        let started = #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-b"}}"# + "\n"
        let url = try file(String(repeating: " ", count: chunk) + "\n" + contextA + quota)
        var reader = RolloutReader()
        XCTAssertEqual(try reader.read(url, requireBoundary: false).quotaBuckets["codex"]?.model, "model-a")

        // Leave quota fully inside the next tail chunk while contextA straddles
        // its boundary, so the rescan buffers the record without a context.
        let tail = chunk - 20
        let gap = tail - quota.utf8.count - contextB.utf8.count - started.utf8.count
        try append(String(repeating: " ", count: gap - 1) + "\n" + contextB + started, to: url)
        let state = try reader.read(url, requireBoundary: true)
        XCTAssertEqual(state.quotaBuckets["codex"]?.model, "model-a")
        XCTAssertEqual(state.quotaBuckets["codex"]?.windows.first?.remainingPercent, 93)
        XCTAssertEqual(state.model, "model-b")
        XCTAssertEqual(state.boundary?.turnID, "turn-b")
        XCTAssertEqual(state.usage?.total, 5)
    }

    func testTaskUpgradeRestoresMissingPrefixBeforeTheLineIsComplete() throws {
        let url = try file(Data((start + model + token).utf8) + context(byteCount: 300_000))
        var reader = RolloutReader()
        _ = try reader.read(url, quotaOnly: true)
        XCTAssertEqual(reader.lastReadByteCount, 256 * 1_024)
        XCTAssertEqual(try reader.read(url, requireBoundary: false).model, "log-model")
        try append("\n", to: url)
        XCTAssertEqual(try reader.read(url, requireBoundary: false).model, "new-model")
        XCTAssertEqual(reader.lastReadByteCount, 1)
    }

    func testReplacementAndTruncationClearBothKindsOfPartialState() throws {
        for quotaOnly in [false, true] {
            for replace in [false, true] {
                let url = try file(Data((start + model + token).utf8) + context(byteCount: 300_000))
                var reader = RolloutReader()
                _ = try reader.read(url, quotaOnly: quotaOnly)
                if replace {
                    try Data((start + model + token).utf8).write(to: url, options: .atomic)
                } else {
                    try Data().write(to: url)
                    XCTAssertNil(try reader.read(url, quotaOnly: quotaOnly).model)
                    try append(start + model + token, to: url)
                }
                XCTAssertEqual(try reader.read(url, quotaOnly: quotaOnly).model, "log-model")
                try append(#"{"type":"turn_context","payload":{"model":"replacement-model"}}"# + "\n", to: url)
                XCTAssertEqual(try reader.read(url, quotaOnly: quotaOnly).model, "replacement-model")
                _ = try reader.read(url)
                XCTAssertEqual(reader.lastReadByteCount, 0)
                XCTAssertEqual(reader.lastOpenCount, 0)
            }
        }
    }

    func testModelBeforeLastChunkIsReadEvenWithStoredBoundary() throws {
        let url = try file(start + model + filler + token)
        var reader = RolloutReader()
        let state = try reader.read(url, requireBoundary: false)
        XCTAssertEqual(state.model, "log-model")
        XCTAssertGreaterThan(reader.lastReadByteCount, 256 * 1_024)
        let metadata = ThreadMetadata(id: "root", title: "Fixture", rolloutPath: url.path, model: nil,
                                      source: "cli", updatedAt: .now, tokens: 500)
        let snapshot = TaskResolver.resolve(metadata: metadata, rollout: state,
            storedTurn: TurnBoundary(turnID: "turn", isRunning: true, date: nil),
            evidence: ProcessEvidence(threadIDs: ["root"]))
        XCTAssertEqual(snapshot?.model, "log-model")
        XCTAssertEqual(try reader.read(url, requireBoundary: false).model, "log-model")
        XCTAssertEqual(reader.lastReadByteCount, 0)
    }

    func testAbsentBoundaryOrModelIsCachedAfterCompleteScan() throws {
        for text in [model + filler + token, start + filler + token, filler] {
            let url = try file(text)
            var reader = RolloutReader()
            _ = try reader.read(url)
            XCTAssertEqual(reader.lastReadByteCount, text.utf8.count)
            _ = try reader.read(url)
            XCTAssertEqual(reader.lastReadByteCount, 0)
            let added = model + start + token
            try append(added, to: url)
            let state = try reader.read(url)
            XCTAssertEqual(reader.lastReadByteCount, added.utf8.count)
            XCTAssertEqual(state.model, "log-model")
            XCTAssertEqual(state.boundary?.isRunning, true)
            XCTAssertEqual(state.usage?.total, 123)
        }
    }

    func testStrongerBoundaryRequirementCompletesPreviouslyPartialScanOnce() throws {
        let url = try file(start + filler + model + token)
        var reader = RolloutReader()
        XCTAssertNil(try reader.read(url, requireBoundary: false).boundary)
        XCTAssertEqual(reader.lastReadByteCount, 256 * 1_024)
        XCTAssertEqual(try reader.read(url, requireBoundary: true).boundary?.turnID, "turn")
        XCTAssertGreaterThan(reader.lastReadByteCount, 256 * 1_024)
        _ = try reader.read(url, requireBoundary: true)
        XCTAssertEqual(reader.lastReadByteCount, 0)

        let absent = try file(filler + model + token)
        XCTAssertNil(try reader.read(absent, requireBoundary: false).boundary)
        XCTAssertNil(try reader.read(absent, requireBoundary: true).boundary)
        XCTAssertGreaterThan(reader.lastReadByteCount, 256 * 1_024)
        _ = try reader.read(absent, requireBoundary: true)
        XCTAssertEqual(reader.lastReadByteCount, 0)
    }

    func testCachedAbsenceStillBuffersAnAppendedPartialLine() throws {
        let prefix = String(model.dropLast(8)), suffix = String(model.suffix(8))
        let url = try file(token + prefix)
        var reader = RolloutReader()
        XCTAssertNil(try reader.read(url).model)
        _ = try reader.read(url)
        XCTAssertEqual(reader.lastReadByteCount, 0)
        try append(suffix, to: url)
        XCTAssertEqual(try reader.read(url).model, "log-model")
        XCTAssertEqual(reader.lastReadByteCount, suffix.utf8.count)
        _ = try reader.read(url)
        XCTAssertEqual(reader.lastReadByteCount, 0)
    }

    func testReplacementAndTruncationClearCompleteScanState() throws {
        let url = try file(filler)
        var reader = RolloutReader()
        _ = try reader.read(url)
        let replacement = start + filler + model + token
        try replacement.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(try reader.read(url, requireBoundary: false).boundary)
        XCTAssertEqual(reader.lastReadByteCount, 256 * 1_024)
        XCTAssertEqual(try reader.read(url).boundary?.isRunning, true)
        XCTAssertGreaterThan(reader.lastReadByteCount, 256 * 1_024)

        try "".write(to: url, atomically: false, encoding: .utf8)
        let empty = try reader.read(url)
        XCTAssertNil(empty.model)
        XCTAssertNil(empty.boundary)
        XCTAssertNil(empty.usage)
        try append(model + token, to: url)
        XCTAssertEqual(try reader.read(url).model, "log-model")
        XCTAssertEqual(reader.lastReadByteCount, (model + token).utf8.count)
        _ = try reader.read(url)
        XCTAssertEqual(reader.lastReadByteCount, 0)
    }
}

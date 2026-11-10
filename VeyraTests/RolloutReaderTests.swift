import XCTest
import Foundation

final class RolloutReaderTests: XCTestCase {
    func testOriginatorReadsLongHeadersAndCachesResults() throws {
        let prefix = #"{"type":"session_meta","payload":{"originator":"codex_vscode","instructions":""#
        let suffix = "\"}}"
        for length in [65_535, 65_536, 65_537, 300_000] {
            let header = prefix + String(repeating: "x", count: length - prefix.utf8.count - suffix.utf8.count) + suffix
            let url = try file(header + "\n" + start + model + token)
            var reader = RolloutReader()
            XCTAssertEqual(try reader.read(url, readOriginator: true).originator, "codex_vscode")
            XCTAssertEqual(try reader.read(url, readOriginator: true).originator, "codex_vscode")
            XCTAssertEqual(reader.lastReadByteCount, 0)
            XCTAssertEqual(reader.lastOpenCount, 0)
        }
    }

    func testIncompleteOriginHeaderContinuesAndReplacementResetsIt() throws {
        let prefix = #"{"type":"session_meta","payload":{"instructions":""# + String(repeating: "x", count: 70_000)
        let url = try file(prefix)
        var reader = RolloutReader()
        XCTAssertNil(try reader.read(url, readOriginator: true).originator)
        XCTAssertNil(try reader.read(url, readOriginator: true).originator)
        XCTAssertEqual(reader.lastReadByteCount, 0)
        XCTAssertEqual(reader.lastOpenCount, 0)
        try append("\",\"originator\":\"codex_vscode\"}}\n", to: url)
        XCTAssertEqual(try reader.read(url, readOriginator: true).originator, "codex_vscode")
        try #"{"type":"session_meta","payload":{"originator":"T3 Code"}}"#.appending("\n").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(try reader.read(url, readOriginator: true).originator, "T3 Code")
    }

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

    func testReplacementAndTruncationClearPartialState() throws {
        for replace in [false, true] {
            let url = try file(Data((start + model + token).utf8) + context(byteCount: 300_000))
            var reader = RolloutReader()
            _ = try reader.read(url)
            if replace {
                try Data((start + model + token).utf8).write(to: url, options: .atomic)
            } else {
                try Data().write(to: url)
                XCTAssertNil(try reader.read(url).model)
                try append(start + model + token, to: url)
            }
            XCTAssertEqual(try reader.read(url).model, "log-model")
            try append(#"{"type":"turn_context","payload":{"model":"replacement-model"}}"# + "\n", to: url)
            XCTAssertEqual(try reader.read(url).model, "replacement-model")
            _ = try reader.read(url)
            XCTAssertEqual(reader.lastReadByteCount, 0)
            XCTAssertEqual(reader.lastOpenCount, 0)
        }
    }

    func testHistoricalModelAndQuotaFieldsDoNotPreventTaskParsing() throws {
        // Retired names remain valid historical data, never a selectable default.
        let historicalModel = #"{"type":"turn_context","payload":{"model":"gpt-5.3-codex-spark"}}"# + "\n"
        let legacyToken = #"{"type":"event_msg","timestamp":"2026-09-03T01:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":123}},"rate_limits":{"limit_id":"codex","primary":{"used_percent":99}}}}"# + "\n"
        let quotaOnlyEvent = #"{"type":"event_msg","timestamp":"2026-09-03T01:01:00Z","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":0}}}}"# + "\n"
        let url = try file(start + historicalModel + legacyToken + quotaOnlyEvent)
        var reader = RolloutReader()
        let initial = try reader.read(url)
        XCTAssertEqual(initial.model, "gpt-5.3-codex-spark")
        XCTAssertEqual(initial.usage?.total, 123)
        XCTAssertEqual(initial.usageDate, RolloutEvent.timestamp("2026-09-03T01:00:00Z"))
        XCTAssertEqual(initial.boundary?.turnID, "turn")
        try append(quotaOnlyEvent + model + token, to: url)
        let updated = try reader.read(url)
        XCTAssertEqual(updated.model, "log-model")
        XCTAssertEqual(updated.usage?.total, 123)
        XCTAssertEqual(reader.lastReadByteCount, (quotaOnlyEvent + model + token).utf8.count)
        var fresh = RolloutReader()
        let cold = try fresh.read(url)
        XCTAssertEqual(updated.model, cold.model)
        XCTAssertEqual(updated.usage, cold.usage)
        XCTAssertEqual(updated.boundary, cold.boundary)
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

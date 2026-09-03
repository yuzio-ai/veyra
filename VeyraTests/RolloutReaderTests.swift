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
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("rollout.jsonl")
        try text.write(to: url, atomically: false, encoding: .utf8)
        return url
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
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

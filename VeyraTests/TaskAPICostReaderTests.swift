import Foundation
import XCTest

final class TaskAPICostReaderTests: XCTestCase {
    private func model(_ name: String) -> String {
        #"{"type":"turn_context","payload":{"model":"\#(name)"}}"# + "\n"
    }

    private func usage(_ input: Int, _ cached: Int, _ output: Int) -> String {
        #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output)}}}}"# + "\n"
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

    private func ledger(_ text: String) -> TaskAPICostEstimate {
        var ledger = TaskAPICostLedger()
        for line in text.split(separator: "\n") { ledger.apply(Data(line.utf8)) }
        return ledger.result(expected: nil)
    }

    func testHistorySwitchesModelsAndRepeatedCountsAreNotAddedAgain() {
        let text = model("gpt-6.1-sol") + usage(1_000_000, 0, 0) + usage(1_000_000, 0, 0)
            + model("gpt-6.1-terra") + usage(2_000_000, 0, 0)
            + model("gpt-6.1-sol") + usage(3_000_000, 0, 0)
        let result = ledger(text)
        XCTAssertEqual(result.lines.map(\.model), ["gpt-6.1-sol", "gpt-6.1-terra"])
        XCTAssertEqual(result.lines.map(\.lowerUSD), [4, 1])
        XCTAssertEqual(result.total?.lowerUSD, 5)
        XCTAssertFalse(result.isPartial)
    }

    func testUnknownHistoricalModelAndMissingContextAreNotPricedAsCurrentModel() {
        let result = ledger(usage(1_000_000, 0, 0) + model("unknown") + usage(2_000_000, 0, 0)
            + model("gpt-6.1-sol") + usage(3_000_000, 0, 0))
        XCTAssertEqual(result.total?.lowerUSD, 2)
        XCTAssertEqual(result.issues, [.missingModel, .unknownModel("unknown")])
        XCTAssertTrue(result.isPartial)
    }

    func testMalformedUsageBreaksBaselineWithoutChargingGapToNextModel() {
        let broken = #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":123}}}}"# + "\n"
        let text = model("gpt-6.1-sol") + usage(1_000_000, 0, 0) + broken
            + model("gpt-6.1-terra") + usage(3_000_000, 0, 0) + usage(4_000_000, 0, 0)
        let result = ledger(text)
        XCTAssertEqual(result.total?.lowerUSD, 3)
        XCTAssertTrue(result.isPartial)
        XCTAssertEqual(result.issues, [.invalidUsage])
    }

    func testLinesWithoutCostMarkersAreSkippedBeforeParsing() {
        // Message and tool lines dominate a rollout by bytes. They must not be
        // JSON-decoded, and a malformed one among them must not be reported as
        // unreadable session history.
        let noise = #"{"type":"response_item","payload":{"type":"message","text":"hello"}}"# + "\n"
            + "not json at all\n"
        let result = ledger(noise + model("gpt-6.1-sol") + usage(1_000_000, 0, 0))
        XCTAssertEqual(result.total?.lowerUSD, 2)
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testMalformedLineThatCouldCarryUsageStillReportsUnreadableHistory() {
        let result = ledger("not json total_token_usage\n")
        XCTAssertNil(result.total)
        XCTAssertEqual(result.issues, [.historyUnreadable])
    }

    func testFractionalNegativeAndNullCountsCannotBeBilled() {
        for value in ["1.5", "-1", "null"] {
            let line = #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(value),"cached_input_tokens":0,"output_tokens":0}}}}"#
            let result = ledger(model("gpt-6.1-sol") + line)
            XCTAssertNil(result.total)
            XCTAssertEqual(result.issues, [.invalidUsage])
        }
    }

    func testCounterResetDiscardsEarlierCostsAndKeepsOnlyConfirmedNewDeltas() {
        let result = ledger(model("gpt-6.1-sol") + usage(2_000_000, 0, 0)
            + usage(100, 0, 0) + usage(1_000_100, 0, 0))
        XCTAssertEqual(result.total?.lowerUSD, 2)
        XCTAssertEqual(result.issues, [.counterReset])
        XCTAssertTrue(result.isPartial)
    }

    func testCacheDeltaCannotExceedInputDelta() {
        let result = ledger(model("gpt-6.1-sol") + usage(1_000, 0, 0) + usage(1_001, 1_000, 0))
        XCTAssertEqual(result.total?.lowerUSD, Decimal(string: "0.002"))
        XCTAssertEqual(result.issues, [.invalidUsage])
    }

    func testUnchangedFilesNeedNoOpenAndIncrementalResultsMatchColdScan() async throws {
        let initial = model("gpt-6.1-sol") + usage(1_000_000, 0, 0)
        let url = try file(initial), reader = TaskAPICostReader()
        let first = try await reader.estimate(url: url)
        XCTAssertEqual(first.total?.lowerUSD, 2)
        _ = try await reader.estimate(url: url)
        let bytes = await reader.lastReadByteCount, opens = await reader.lastOpenCount
        XCTAssertEqual(bytes, 0); XCTAssertEqual(opens, 0)
        let extra = model("gpt-6.1-terra") + usage(2_000_000, 0, 0)
        try append(extra, to: url)
        let updated = try await reader.estimate(url: url)
        let addedBytes = await reader.lastReadByteCount
        XCTAssertEqual(addedBytes, extra.utf8.count)
        let cold = try await TaskAPICostReader().estimate(url: url)
        XCTAssertEqual(updated, cold)
        XCTAssertEqual(updated.total?.lowerUSD, 3)
    }

    func testPartialLineAcrossChunksIsBilledOnlyAfterNewline() async throws {
        let filler = #"{"type":"response_item","payload":{"text":""# + String(repeating: "中", count: 100_000) + #""}}"# + "\n"
        let partial = usage(2_000_000, 0, 0)
        let url = try file(model("gpt-6.1-sol") + filler + usage(1_000_000, 0, 0) + partial.dropLast())
        let reader = TaskAPICostReader()
        let first = try await reader.estimate(url: url)
        XCTAssertEqual(first.total?.lowerUSD, 2)
        try append("\n", to: url)
        let updated = try await reader.estimate(url: url)
        let added = await reader.lastReadByteCount
        XCTAssertEqual(updated.total?.lowerUSD, 4)
        XCTAssertEqual(added, 1)
    }

    func testLongUnfinishedLineScansOnlyNewBytesAcrossChunksAndReads() async throws {
        let initial = model("gpt-6.1-sol") + usage(1_000_000, 0, 0)
            + #"{"type":"response_item","payload":{"text":""# + String(repeating: "中", count: 1_000_000)
        let url = try file(initial), reader = TaskAPICostReader()
        let first = try await reader.estimate(url: url)
        let initialScanned = await reader.lastScannedByteCount
        XCTAssertEqual(first.total?.lowerUSD, 2)
        XCTAssertEqual(initialScanned, initial.utf8.count)

        let continuation = String(repeating: "a", count: 1_000_000)
        try append(continuation, to: url)
        let pending = try await reader.estimate(url: url)
        let continuedScanned = await reader.lastScannedByteCount
        XCTAssertEqual(pending, first)
        XCTAssertEqual(continuedScanned, continuation.utf8.count)

        let completion = #""}}"# + "\n\n" + model("gpt-6.1-terra") + usage(2_000_000, 0, 0)
        try append(completion, to: url)
        let completed = try await reader.estimate(url: url)
        let completionScanned = await reader.lastScannedByteCount
        XCTAssertEqual(completed.total?.lowerUSD, 3)
        XCTAssertTrue(completed.issues.isEmpty)
        XCTAssertEqual(completionScanned, completion.utf8.count)
        let cold = try await TaskAPICostReader().estimate(url: url)
        XCTAssertEqual(completed, cold)

        _ = try await reader.estimate(url: url)
        let unchangedScanned = await reader.lastScannedByteCount
        XCTAssertEqual(unchangedScanned, 0)
    }

    func testLongModelRecordEndingAtChunkBoundaryIsParsedExactlyOnce() async throws {
        let chunkSize = 256 * 1_024
        let prefix = #"{"type":"turn_context","payload":{"model":"gpt-6.1-sol","padding":""#
        let suffix = #""}}"# + "\n"
        let context = prefix + String(repeating: "x", count: chunkSize * 4 - prefix.utf8.count - suffix.utf8.count) + suffix
        let text = context + usage(1_000_000, 0, 0) + usage(1_000_000, 0, 0)
        let url = try file(text), reader = TaskAPICostReader()
        let result = try await reader.estimate(url: url)
        let scanned = await reader.lastScannedByteCount
        XCTAssertEqual(result.total?.lowerUSD, 2)
        XCTAssertEqual(result.lines.count, 1)
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertEqual(scanned, text.utf8.count)
    }

    func testAtomicReplacementSameSizeRewriteAndTruncationClearCachedHistory() async throws {
        let initial = model("gpt-6.1-sol") + usage(1_000_000, 0, 0)
        let replacement = model("gpt-6.1-sol") + usage(2_000_000, 0, 0)
        let url = try file(initial), reader = TaskAPICostReader()
        _ = try await reader.estimate(url: url)
        try Data(replacement.utf8).write(to: url, options: .atomic)
        let replaced = try await reader.estimate(url: url)
        XCTAssertEqual(replaced.total?.lowerUSD, 4)
        try Data(initial.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: url.path)
        let rewritten = try await reader.estimate(url: url)
        XCTAssertEqual(rewritten.total?.lowerUSD, 2)
        try Data().write(to: url)
        let empty = try await reader.estimate(url: url)
        XCTAssertNil(empty.total)
        XCTAssertEqual(empty.issues, [.missingUsage])
    }

    func testOldSnapshotCannotReceiveCostsFromNewUsage() async throws {
        let url = try file(model("gpt-6.1-sol") + usage(2_000_000, 0, 0))
        let reader = TaskAPICostReader()
        let stale = try await reader.estimate(url: url, expected: TokenUsage(input: 1_000_000, output: 0, cachedInput: 0, total: 1_000_000))
        XCTAssertNil(stale.total)
        XCTAssertEqual(stale.issues, [.outOfDate])
        let current = try await reader.estimate(url: url, expected: TokenUsage(input: 2_000_000, output: 0, cachedInput: 0, total: 2_000_000))
        XCTAssertEqual(current.total?.lowerUSD, 4)
    }

    func testFilesAndParentChildHistoriesStayIndependent() async throws {
        let parent = try file(model("gpt-6.1-sol") + usage(1_000_000, 0, 0))
        let child = try file(model("gpt-6.1-terra") + usage(1_000_000, 0, 0))
        let reader = TaskAPICostReader()
        async let parentResult = reader.estimate(url: parent)
        async let childResult = reader.estimate(url: child)
        let results = try await (parentResult, childResult)
        XCTAssertEqual(results.0.total?.lowerUSD, 2)
        XCTAssertEqual(results.1.total?.lowerUSD, 1)
    }

    func testCancelledReadDoesNotPublishOrCachePartialCosts() async throws {
        let url = try file(model("gpt-6.1-sol") + usage(1_000_000, 0, 0))
        let reader = TaskAPICostReader()
        let request = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await reader.estimate(url: url)
        }
        do { _ = try await request.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        let result = try await reader.estimate(url: url)
        XCTAssertEqual(result.total?.lowerUSD, 2)
        let bytes = await reader.lastReadByteCount
        XCTAssertEqual(bytes, try Data(contentsOf: url).count)
    }
}

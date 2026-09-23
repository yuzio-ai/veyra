import XCTest
import Foundation

private final class DshFixture {
    let home: URL
    private let sessions: URL
    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        sessions = home.appendingPathComponent("storages/session_projcache/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: home) }

    /// `openTurn`: true → openTurnStartSeq number, false → null, nil → row removed.
    @discardableResult
    func write(_ id: String, title: String? = nil, openTurn: Bool? = true, lastPromptAt: Double? = nil,
               createdAt: Double? = 1_799_996_400_000, uncached: Int = 100, output: Int = 10,
               cacheRead: Int = 40, cacheWrite: Int = 5, model: String? = "kimi-k3") throws -> URL {
        var rows: [String] = []
        rows.append(#""title":{"ver":1,"seq":1,"val":\#(title.map { #""\#($0)""# } ?? "null")}"#)
        if let openTurn {
            rows.append(#""turnBoundary":{"ver":2,"seq":1,"val":{"openTurnStartSeq":\#(openTurn ? "12" : "null")}}"#)
        }
        rows.append(#""tokenUsage":{"ver":2,"seq":1,"val":{"totals":{"uncachedInputTokens":\#(uncached),"outputTokens":\#(output),"cacheReadTokens":\#(cacheRead),"cacheWriteTokens":\#(cacheWrite)}}}"#)
        rows.append(#""modelSelection":{"ver":2,"seq":1,"val":{"lastUsed":\#(model.map { #"{"provider":"p","model":"\#($0)"}"# } ?? "null")}}"#)
        if let lastPromptAt {
            rows.append(#""sessionListMetadata":{"ver":1,"seq":1,"val":{"lastPromptAt":\#(Int(lastPromptAt))}}"#)
        }
        let identity = createdAt.map { #"{"formatVersion":3,"createdAt":\#(Int($0)),"cwd":"/tmp/work"}"# } ?? #"{"formatVersion":3}"#
        let json = #"{"version":7,"record":{"identity":\#(identity),"rows":{\#(rows.joined(separator: ","))}}}"#
        let url = sessions.appendingPathComponent(id + ".json")
        try Data(json.utf8).write(to: url)
        return url
    }
}

final class DshTaskReaderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var recentMs: Double { (now.timeIntervalSince1970 - 3_600) * 1000 }
    private var staleMs: Double { (now.timeIntervalSince1970 - 90_000) * 1000 }

    private func reader(_ evidence: DshProcessEvidence) -> DshTaskReader {
        let now = now
        return DshTaskReader(now: { now }, collectEvidence: { _ in evidence })
    }

    func testOpenTurnWithLiveProcessIsRunning() async throws {
        let fixture = try DshFixture()
        try fixture.write("s1", title: "Live task", openTurn: true, lastPromptAt: recentMs)
        let read = await reader(DshProcessEvidence(sessionIDs: ["s1"])).fetch(home: fixture.home)
        XCTAssertEqual(read.tasks.count, 1)
        let task = try XCTUnwrap(read.tasks.first)
        XCTAssertEqual(task.id, "dsh:s1")
        XCTAssertEqual(task.title, "Live task")
        XCTAssertEqual(task.activity, .running)
        XCTAssertEqual(task.backend, .dsh)
        XCTAssertEqual(task.sourceLabel, "dsh")
        XCTAssertEqual(task.model, "kimi-k3")
        XCTAssertEqual(task.startedAt, Date(timeIntervalSince1970: recentMs / 1000))
        XCTAssertEqual(task.updatedAt, Date(timeIntervalSince1970: recentMs / 1000))
        XCTAssertEqual(task.tokens.input, 145)
        XCTAssertEqual(task.tokens.cachedInput, 40)
        XCTAssertEqual(task.tokens.total, 155)
        XCTAssertNil(read.warning)
        XCTAssertEqual(read.parsedFiles, 1)
    }

    func testOpenTurnWithoutProcessStaysUnknownUntilStale() async throws {
        let fixture = try DshFixture()
        try fixture.write("recent", openTurn: true, lastPromptAt: recentMs)
        try fixture.write("stale", openTurn: true, lastPromptAt: staleMs, createdAt: staleMs)
        let read = await reader(DshProcessEvidence()).fetch(home: fixture.home)
        XCTAssertEqual(read.tasks.map(\.id), ["dsh:recent"])
        XCTAssertEqual(read.tasks.first?.activity, .unknown)
    }

    func testFinishedTurnIsHiddenEvenWithLiveProcess() async throws {
        let fixture = try DshFixture()
        try fixture.write("s1", openTurn: false, lastPromptAt: recentMs)
        let read = await reader(DshProcessEvidence(sessionIDs: ["s1"])).fetch(home: fixture.home)
        XCTAssertTrue(read.tasks.isEmpty)
    }

    func testMissingBoundaryFallsBackToProcessAndRecency() async throws {
        let fixture = try DshFixture()
        try fixture.write("locked", openTurn: nil, lastPromptAt: staleMs, createdAt: staleMs)
        try fixture.write("recent", openTurn: nil, lastPromptAt: recentMs)
        try fixture.write("old", openTurn: nil, lastPromptAt: staleMs, createdAt: staleMs)
        let read = await reader(DshProcessEvidence(sessionIDs: ["locked"])).fetch(home: fixture.home)
        XCTAssertEqual(Set(read.tasks.map(\.id)), ["dsh:locked", "dsh:recent"])
        XCTAssertTrue(read.tasks.allSatisfy { $0.activity == .unknown })
    }

    func testUnreliableEvidenceDowngradesActivityAndWarns() async throws {
        let fixture = try DshFixture()
        try fixture.write("s1", openTurn: true, lastPromptAt: recentMs)
        let read = await reader(DshProcessEvidence(sessionIDs: ["s1"], reliable: false)).fetch(home: fixture.home)
        XCTAssertEqual(read.tasks.first?.activity, .unknown)
        XCTAssertEqual(read.warning, L10n.text("Unable to verify dsh processes. Task status is uncertain."))
    }

    func testCorruptFilesAreSkippedWithWarningAndGoodFilesKept() async throws {
        let fixture = try DshFixture()
        try fixture.write("good", title: "OK", openTurn: true, lastPromptAt: recentMs)
        let bad = fixture.home.appendingPathComponent("storages/session_projcache/sessions/bad.json")
        try Data("not json".utf8).write(to: bad)
        let read = await reader(DshProcessEvidence(sessionIDs: ["good"])).fetch(home: fixture.home)
        XCTAssertEqual(read.tasks.map(\.id), ["dsh:good"])
        XCTAssertEqual(read.skippedFiles, 1)
        XCTAssertEqual(read.warning, L10n.text("Some dsh session records are unreadable."))
    }

    func testMissingDirectoryIsSilentAndRecordWithoutTimestampsIsSkipped() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let empty = await reader(DshProcessEvidence()).fetch(home: missing)
        XCTAssertTrue(empty.tasks.isEmpty)
        XCTAssertNil(empty.warning)
        let fixture = try DshFixture()
        try fixture.write("no-times", openTurn: true, lastPromptAt: nil, createdAt: nil)
        let read = await reader(DshProcessEvidence(sessionIDs: ["no-times"])).fetch(home: fixture.home)
        XCTAssertTrue(read.tasks.isEmpty)
        XCTAssertNil(read.warning)
    }

    func testMissingDirectoryNeverCollectsEvidence() async throws {
        // F1: non-dsh users must not pay for an lsof spawn on every poll.
        let probe = Probe(), now = now
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = DshTaskReader(now: { now }, collectEvidence: { _ in
            await probe.mark()
            return DshProcessEvidence()
        })
        let read = await reader.fetch(home: missing)
        XCTAssertTrue(read.tasks.isEmpty)
        let calls = await probe.calls
        XCTAssertEqual(calls, 0)
    }

    func testUnreliableEvidenceKeepsStaleOpenTurnAndHidesStaleUnknown() async throws {
        let fixture = try DshFixture()
        // F4(b): like Codex historical inProgress records, an open turn is
        // kept when process liveness cannot be verified at all.
        try fixture.write("open", openTurn: true, lastPromptAt: staleMs, createdAt: staleMs)
        // F4(a): the boundary-unknown recency rule applies regardless of reliability.
        try fixture.write("unknown", openTurn: nil, lastPromptAt: staleMs, createdAt: staleMs)
        let read = await reader(DshProcessEvidence(reliable: false)).fetch(home: fixture.home)
        XCTAssertEqual(read.tasks.map(\.id), ["dsh:open"])
        XCTAssertEqual(read.tasks.first?.activity, .unknown)
    }

    func testProcessWarningOutranksUnreadableFiles() async throws {
        // F4(c): unreliable evidence and corrupt files together still report the process warning.
        let fixture = try DshFixture()
        try fixture.write("good", openTurn: true, lastPromptAt: recentMs)
        try Data("not json".utf8).write(to: fixture.home.appendingPathComponent(
            "storages/session_projcache/sessions/bad.json"))
        let read = await reader(DshProcessEvidence(reliable: false)).fetch(home: fixture.home)
        XCTAssertEqual(read.skippedFiles, 1)
        XCTAssertEqual(read.warning, L10n.text("Unable to verify dsh processes. Task status is uncertain."))
    }

    func testRunningTasksSortBeforeUnknownThenByStartTime() async throws {
        let fixture = try DshFixture()
        try fixture.write("a", openTurn: true, lastPromptAt: recentMs - 60_000)
        try fixture.write("b", openTurn: true, lastPromptAt: recentMs)
        try fixture.write("c", openTurn: true, lastPromptAt: recentMs - 30_000)
        let read = await reader(DshProcessEvidence(sessionIDs: ["c"])).fetch(home: fixture.home)
        XCTAssertEqual(read.tasks.map(\.id), ["dsh:c", "dsh:b", "dsh:a"])
    }
}

private actor Probe {
    private(set) var calls = 0
    func mark() { calls += 1 }
}

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
    /// `children` mirrors the `subagentCatalog` head window a parent keeps for
    /// the subagent sessions it spawned.
    @discardableResult
    func write(_ id: String, title: String? = nil, openTurn: Bool? = true, lastPromptAt: Double? = nil,
               createdAt: Double? = 1_799_996_400_000, uncached: Int = 100, output: Int = 10,
               cacheRead: Int = 40, cacheWrite: Int = 5, model: String? = "kimi-k3",
               provider: String = "p", effort: String? = nil, subagentLabel: String? = nil,
               children: [(String, String?)] = []) throws -> URL {
        var rows: [String] = []
        rows.append(#""title":{"ver":1,"seq":1,"val":\#(title.map { #""\#($0)""# } ?? "null")}"#)
        if let subagentLabel {
            rows.append(#""subagent":{"ver":2,"seq":1,"val":{"identity":{"mode":"continuable","label":"\#(subagentLabel)","seq":0}}}"#)
        }
        if !children.isEmpty {
            let values = children.map { child, label in
                var fields = [#""childId":"\#(child)""#]
                if let label { fields.append(#""label":"\#(label)""#) }
                return "{" + fields.joined(separator: ",") + "}"
            }
            rows.append(#""subagentCatalog":{"ver":2,"seq":1,"val":{"inheritedEventCount":0,"head":{"values":[\#(values.joined(separator: ","))]}}}"#)
        }
        if let openTurn {
            rows.append(#""turnBoundary":{"ver":2,"seq":1,"val":{"openTurnStartSeq":\#(openTurn ? "12" : "null")}}"#)
        }
        rows.append(#""tokenUsage":{"ver":2,"seq":1,"val":{"totals":{"uncachedInputTokens":\#(uncached),"outputTokens":\#(output),"cacheReadTokens":\#(cacheRead),"cacheWriteTokens":\#(cacheWrite)}}}"#)
        let lastUsed = model.map { model in
            var fields = [#""provider":"\#(provider)""#, #""model":"\#(model)""#]
            if let effort { fields.append(#""reasoningEffort":"\#(effort)""#) }
            return "{" + fields.joined(separator: ",") + "}"
        } ?? "null"
        rows.append(#""modelSelection":{"ver":2,"seq":1,"val":{"lastUsed":\#(lastUsed)}}"#)
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
        try fixture.write("s1", title: "Live task", openTurn: true, lastPromptAt: recentMs,
                          provider: "deepseek-account", effort: "high")
        let read = await reader(DshProcessEvidence(sessionIDs: ["s1"])).fetch(home: fixture.home)
        XCTAssertEqual(read.tasks.count, 1)
        let task = try XCTUnwrap(read.tasks.first)
        XCTAssertEqual(task.id, "dsh:s1")
        XCTAssertEqual(task.title, "Live task")
        XCTAssertEqual(task.activity, .running)
        XCTAssertEqual(task.backend, .dsh)
        XCTAssertEqual(task.workingDirectory, "/tmp/work")
        XCTAssertEqual(task.sourceLabel, "DSH")
        XCTAssertEqual(task.sourceDetail, "DeepSeek Harness")
        XCTAssertEqual(task.model, "kimi-k3")
        XCTAssertEqual(task.modelProvider, "deepseek-account")
        XCTAssertEqual(task.reasoningEffort, "high")
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

    // MARK: - Subagent families

    func testCataloguedSubagentNestsUnderItsRunningParent() async throws {
        let fixture = try DshFixture()
        try fixture.write("parent", title: "审查所有文档", openTurn: true,
                          lastPromptAt: recentMs - 60_000, children: [("child", "Audit docs")])
        try fixture.write("child", title: "You are auditing", openTurn: true, lastPromptAt: recentMs,
                          subagentLabel: "Audit docs")
        let read = await reader(DshProcessEvidence(sessionIDs: ["parent", "child"])).fetch(home: fixture.home)
        XCTAssertEqual(Set(read.tasks.map(\.id)), ["dsh:parent", "dsh:child"])
        XCTAssertTrue(read.ancestors.isEmpty)
        let child = try XCTUnwrap(read.tasks.first { $0.id == "dsh:child" })
        XCTAssertEqual(child.parentID, "dsh:parent")
        guard case .subtask = child.source else { return XCTFail("A catalogued child is a subtask") }
        XCTAssertEqual(child.agentNickname, "Audit docs")
        guard case .desktop = try XCTUnwrap(read.tasks.first { $0.id == "dsh:parent" }).source else {
            return XCTFail("A session no catalog lists stays a main task")
        }
        let groups = TaskGroup.make(tasks: read.tasks, ancestors: read.ancestors)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].rows.map(\.id), ["dsh:parent", "dsh:child"])
        XCTAssertEqual(groups[0].rows.map(\.depth), [0, 1])
        XCTAssertFalse(groups[0].rows[0].isSubagent)
        XCTAssertTrue(groups[0].rows[1].isSubagent)
        XCTAssertEqual(groups[0].rows[1].parentTitle, "审查所有文档")
        XCTAssertEqual(TaskProjectGroup(project: nil, groups: groups).counts(for: .running),
                       TaskProjectCounts(main: 1, subtasks: 1))
    }

    func testFinishedParentStaysAsContextForItsRunningSubagent() async throws {
        let fixture = try DshFixture()
        try fixture.write("parent", title: "父任务", openTurn: false, lastPromptAt: recentMs - 600_000,
                          children: [("child", "Audit docs")])
        try fixture.write("child", title: "You are auditing", openTurn: true, lastPromptAt: recentMs,
                          subagentLabel: "Audit docs")
        let read = await reader(DshProcessEvidence(sessionIDs: ["child"])).fetch(home: fixture.home)
        XCTAssertEqual(read.tasks.map(\.id), ["dsh:child"])
        XCTAssertEqual(read.ancestors.map(\.id), ["dsh:parent"])
        XCTAssertEqual(read.ancestors.first?.title, "父任务")
        XCTAssertEqual(read.ancestors.first?.backend, .dsh)
        XCTAssertNil(read.ancestors.first?.parentID, "The finished parent is the family root")
        let groups = TaskGroup.make(tasks: read.tasks, ancestors: read.ancestors)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].rows.map(\.id), ["dsh:parent", "dsh:child"])
        XCTAssertNil(groups[0].rows.first?.task)
        XCTAssertEqual(TaskProjectGroup(project: nil, groups: groups).counts(for: .running),
                       TaskProjectCounts(main: 0, subtasks: 1))
    }

    func testChildWithoutItsParentRecordStillCountsAsSubtask() async throws {
        let fixture = try DshFixture()
        // The parent catalogued this child but its own record is gone.
        try fixture.write("child", title: "You are auditing", openTurn: true, lastPromptAt: recentMs,
                          subagentLabel: "Audit docs")
        let read = await reader(DshProcessEvidence(sessionIDs: ["child"])).fetch(home: fixture.home)
        let child = try XCTUnwrap(read.tasks.first)
        XCTAssertNil(child.parentID, "A deleted parent must not leave a dangling link")
        XCTAssertTrue(read.ancestors.isEmpty)
        XCTAssertTrue(TaskGroup.make(tasks: read.tasks, ancestors: read.ancestors)[0].rows[0].isSubagent)
    }

    func testUnlabelledCataloguedChildIsStillASubtask() async throws {
        let fixture = try DshFixture()
        try fixture.write("parent", title: "父任务", openTurn: true, lastPromptAt: recentMs - 60_000,
                          children: [("child", nil)])
        try fixture.write("child", title: "Worker", openTurn: true, lastPromptAt: recentMs)
        let read = await reader(DshProcessEvidence(sessionIDs: ["parent", "child"])).fetch(home: fixture.home)
        let child = try XCTUnwrap(read.tasks.first { $0.id == "dsh:child" })
        XCTAssertEqual(child.parentID, "dsh:parent")
        XCTAssertNil(child.agentNickname)
        let groups = TaskGroup.make(tasks: read.tasks, ancestors: read.ancestors)
        XCTAssertEqual(groups[0].rows.map(\.depth), [0, 1])
        XCTAssertTrue(groups[0].rows[1].isSubagent)
    }

    func testSelfAndMutualCataloguedChildrenDoNotFormFamilies() async throws {
        let fixture = try DshFixture()
        try fixture.write("self", title: "Self", openTurn: true, lastPromptAt: recentMs,
                          subagentLabel: "Loop", children: [("self", "Loop")])
        let read = await reader(DshProcessEvidence(sessionIDs: ["self"])).fetch(home: fixture.home)
        let task = try XCTUnwrap(read.tasks.first)
        XCTAssertNil(task.parentID)
        XCTAssertTrue(read.ancestors.isEmpty)
        XCTAssertEqual(TaskGroup.make(tasks: read.tasks, ancestors: read.ancestors).count, 1)
    }
}

private actor Probe {
    private(set) var calls = 0
    func mark() { calls += 1 }
}

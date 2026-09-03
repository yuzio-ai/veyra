import XCTest
import Foundation

final class RolloutDisplayTests: XCTestCase {
    private func line(_ payload: [String: JSONValue], type: String = "response_item") throws -> Data {
        var data = try JSONEncoder().encode(JSONValue.object(["type": .string(type), "payload": .object(payload)]))
        data.append(10)
        return data
    }
    private func message(_ text: String, turn: String? = "current", role: String = "assistant",
                         phase: String = "commentary", encrypted: Bool = false) throws -> Data {
        try line(["type": .string("message"), "role": .string(role), "phase": .string(phase),
            "content": .array([.object(["type": .string(encrypted ? "encrypted_content" : "output_text"), "text": .string(text)])]),
            "internal_chat_message_metadata_passthrough": .object(["turn_id": turn.map(JSONValue.string) ?? .null])])
    }
    private func tool(_ name: String = "exec", turn: String = "current") throws -> Data {
        try line(["type": .string("custom_tool_call"), "name": .string(name), "input": .string("private arguments"),
            "internal_chat_message_metadata_passthrough": .object(["turn_id": .string(turn)])])
    }
    private func start(_ turn: String = "current") throws -> Data {
        try line(["type": .string("task_started"), "turn_id": .string(turn)], type: "event_msg")
    }
    private func progress(_ state: RolloutState, turn: String = "current") -> TaskProgress? {
        state.display.progress(for: TurnBoundary(turnID: turn, isRunning: true, date: nil))
    }
    private func file(_ data: Data) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("rollout.jsonl")
        try data.write(to: url)
        return url
    }
    private func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
    }

    func testNewestPublicProgressWinsInBothScanDirectionsAndToolIsOnlyFallback() throws {
        let events = try [start(), message("旧进展"), message("新进展"), tool("apply_patch")]
        for reverse in [false, true] {
            var state = RolloutState()
            for event in reverse ? events.reversed().map({ $0 }) : events {
                RolloutEvent.apply(event, to: &state, newestFirst: reverse)
            }
            XCTAssertEqual(progress(state), TaskProgress(kind: .message, text: "新进展"))
        }
        var state = RolloutState()
        RolloutEvent.apply(try tool("apply_patch"), to: &state)
        XCTAssertEqual(progress(state), TaskProgress(kind: .tool, text: "修改文件"))
    }

    func testInheritedUserReasoningFinalEncryptedAndUnattributedTextAreIgnored() throws {
        var state = RolloutState()
        let events = try [message("父任务进展", turn: "parent-turn"), message("用户指令", role: "user"),
            message("开发指令", role: "developer"), message("隐藏推理", phase: "analysis"),
            message("最终结果", phase: "final_answer"), message("缺少轮次", turn: nil),
            message("密文", encrypted: true), message("gAAAAAencrypted"),
            line(["type": .string("reasoning"), "summary": .string("private")]),
            line(["type": .string("agent_message"), "content": .string("NEW_TASK private")]),
            line(["type": .string("function_call_output"), "output": .string("private")])]
        for event in events { RolloutEvent.apply(event, to: &state) }
        XCTAssertNil(progress(state))
        XCTAssertNil(state.display.progress(for: nil))
        XCTAssertNil(state.display.progress(for: TurnBoundary(turnID: "parent-turn", isRunning: false, date: nil)))
    }

    func testNewTurnClearsPreviousProgressAndAmbiguousResolutionDoesNotPublishIt() throws {
        var state = RolloutState()
        RolloutEvent.apply(try start(), to: &state)
        RolloutEvent.apply(try message("上一轮"), to: &state)
        RolloutEvent.apply(try start("next"), to: &state)
        XCTAssertNil(progress(state))
        XCTAssertNil(progress(state, turn: "next"))
        RolloutEvent.apply(try tool(turn: "next"), to: &state)
        let metadata = ThreadMetadata(id: "child", title: "", rolloutPath: "/missing", model: nil,
            source: #"{"subagent":{"thread_spawn":{"parent_thread_id":"parent","agent_path":"/root/review"}}}"#,
            updatedAt: .distantPast, tokens: nil)
        let snapshot = TaskResolver.resolve(metadata: metadata, rollout: state,
            storedTurn: TurnBoundary(turnID: "different", isRunning: true, date: nil), evidence: ProcessEvidence(threadIDs: ["child"]))
        XCTAssertEqual(snapshot?.activity, .unknown)
        XCTAssertNil(snapshot?.progress)
        let known = TaskResolver.resolve(metadata: metadata, rollout: state, storedTurn: nil, evidence: ProcessEvidence(threadIDs: ["child"]))
        XCTAssertEqual(known?.title, "review")
        XCTAssertEqual(known?.progress?.kind, .tool)
    }

    func testOptionalProgressNeverExpandsScanAndIncrementalPartialLinesAndReplacementWork() throws {
        let model = try line(["model": .string("test")], type: "turn_context")
        let token = try line(["type": .string("token_count"), "info": .object(["total_token_usage": .object(["total_tokens": .number(1)])])], type: "event_msg")
        let filler = Data(String(repeating: "{}\n", count: 100_000).utf8)
        let data = try message("扫描预算之外") + filler + start() + model + token
        let url = try file(data)
        var reader = RolloutReader()
        XCTAssertNil(progress(try reader.read(url)))
        XCTAssertEqual(reader.lastReadByteCount, 256 * 1_024)
        _ = try reader.read(url)
        XCTAssertEqual(reader.lastReadByteCount, 0)
        XCTAssertEqual(reader.lastOpenCount, 0)
        let added = try message("增量进展")
        try append(Data(added.dropLast(5)), to: url)
        XCTAssertNil(progress(try reader.read(url)))
        try append(Data(added.suffix(5)), to: url)
        XCTAssertEqual(progress(try reader.read(url))?.text, "增量进展")
        XCTAssertEqual(reader.lastReadByteCount, 5)
        let replacement = try start("replacement") + model + token + tool("view_image", turn: "replacement")
        try replacement.write(to: url, options: .atomic)
        let replaced = try reader.read(url)
        XCTAssertNil(progress(replaced))
        XCTAssertEqual(progress(replaced, turn: "replacement")?.text, "查看图片")
        try Data().write(to: url)
        XCTAssertNil(progress(try reader.read(url), turn: "replacement"))
    }

    func testSummaryMemoryIsBounded() throws {
        var state = RolloutState()
        RolloutEvent.apply(try message(String(repeating: "长", count: 5_000)), to: &state)
        XCTAssertEqual(progress(state)?.text.count, 2_000)
    }
}

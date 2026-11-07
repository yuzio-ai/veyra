import XCTest
import Foundation

final class TaskPresentationTests: XCTestCase {
    private func task(_ id: String, parent: String? = nil, activity: TaskActivity = .running) -> TaskSnapshot {
        TaskSnapshot(id: id, title: id, model: nil, source: parent == nil ? .desktop : .subtask,
                     parentID: parent, startedAt: nil, updatedAt: .distantPast,
                     tokens: TokenUsage(total: 100), activity: activity)
    }

    func testFamilyIncludesSiblingsAndDescendantsInInputOrderWithoutSummingTokens() {
        let tasks = [task("child2", parent: "root"), task("other"), task("child1", parent: "root"),
                     task("grandchild", parent: "child1"), task("root")]
        let groups = TaskGroup.make(tasks: tasks, ancestors: [])
        XCTAssertEqual(groups.map(\.id), ["root", "other"])
        XCTAssertEqual(groups[0].rows.map(\.id), ["root", "child2", "child1", "grandchild"])
        XCTAssertEqual(groups[0].rows.map(\.depth), [0, 1, 1, 2])
        XCTAssertEqual(groups[0].rows.last?.parentTitle, "child1")
        XCTAssertEqual(groups[0].rows.compactMap { $0.task?.tokens.total }, [100, 100, 100, 100])
    }

    func testEndedAncestorsAndMissingParentsAreContextOnly() {
        let groups = TaskGroup.make(tasks: [task("child", parent: "ended"), task("orphan", parent: "missing")],
            ancestors: [TaskReference(id: "ended", title: "父任务标题", parentID: "archived"),
                        TaskReference(id: "archived", title: "祖先任务", parentID: nil),
                        TaskReference(id: "unrelated", title: "不展示", parentID: nil)])
        XCTAssertEqual(groups.map(\.id), ["archived", "missing"])
        XCTAssertEqual(groups[0].rows.map(\.id), ["archived", "ended", "child"])
        XCTAssertEqual(groups[0].rows.last?.parentTitle, "父任务标题")
        XCTAssertEqual(groups[0].rows.compactMap(\.task).count, 1)
        XCTAssertNil(groups[1].rows.first?.task)
        XCTAssertEqual(groups[1].rows.last?.parentTitle, L10n.text("Parent task · \("missing")"))
    }

    func testMixedStatusStaysTogetherAndUnknownOnlyGroupRemainsSeparate() {
        let groups = TaskGroup.make(tasks: [task("running", parent: "uncertain"),
            task("uncertain", activity: .unknown), task("unknownChild", parent: "running", activity: .unknown),
            task("unknownOnly", activity: .unknown)], ancestors: [])
        XCTAssertEqual(groups.count, 2)
        XCTAssertTrue(groups[0].isRunning)
        XCTAssertEqual(groups[0].unknownCount, 2)
        XCTAssertFalse(groups[1].isRunning)
        XCTAssertEqual(groups[1].unknownCount, 1)
        XCTAssertEqual(groups.flatMap(\.rows).compactMap(\.task).filter { $0.activity == .running }.count, 1)
    }

    func testCyclesSelfParentsAndDuplicateTasksDoNotDropOrDuplicateRows() {
        let tasks = [task("b", parent: "a"), task("a", parent: "c"), task("c", parent: "b"),
                     task("self", parent: "self"), task("b", parent: "a")]
        let groups = TaskGroup.make(tasks: tasks, ancestors: [])
        XCTAssertEqual(groups.map(\.id), ["a", "self"])
        XCTAssertEqual(groups.flatMap(\.rows).map(\.id), ["a", "b", "c", "self"])
        XCTAssertEqual(groups[0].rows.map(\.depth), [0, 1, 2])
    }

    func testActiveSnapshotOverridesAncestorMetadataAndEmptyTasksShowNothing() {
        let references = [TaskReference(id: "root", title: "旧标题", parentID: nil)]
        XCTAssertTrue(TaskGroup.make(tasks: [], ancestors: references).isEmpty)
        let groups = TaskGroup.make(tasks: [task("root"), task("child", parent: "root")], ancestors: references)
        XCTAssertEqual(groups[0].rows[0].reference.title, "root")
        XCTAssertEqual(groups[0].rows[1].parentTitle, "root")
    }


    func testTitleFallbackAndSourceMetadata() {
        var metadata = ThreadMetadata(id: "12345678-rest", title: " \n ", rolloutPath: "/missing", model: nil,
            source: #"{"subagent":{"thread_spawn":{"parent_thread_id":"parent","agent_path":"/root/ios_phone_auth_r2_review","agent_nickname":"Lorentz","agent_role":"reviewer"}}}"#,
            updatedAt: .distantPast, tokens: nil)
        XCTAssertEqual(metadata.displayTitle, "ios phone auth r2 review")
        XCTAssertEqual(metadata.agentRole, "reviewer")
        metadata.storedAgentPath = "/root/database_review"
        XCTAssertEqual(metadata.displayTitle, "database review")
        XCTAssertEqual(TaskText.title(" 已有名称 ", id: metadata.id, parentID: "p", agentPath: metadata.agentPath, nickname: nil), "已有名称")
        XCTAssertEqual(TaskText.title(nil, id: metadata.id, parentID: "p", agentPath: nil, nickname: " Lorentz "), "Lorentz")
        XCTAssertEqual(TaskText.title(nil, id: metadata.id, parentID: "p", agentPath: "/root", nickname: nil), L10n.text("Subtask · \("12345678")"))
        XCTAssertEqual(TaskText.title(nil, id: metadata.id, parentID: nil, agentPath: nil, nickname: nil), L10n.text("Untitled task"))
    }

    func testInlineProgressFoldsRecordedLinesWithoutChangingOriginalText() {
        let original = "  已核对缓存\r\n\n  Checking boundaries\u{2028}\t下一步\u{2029}完成  "
        let progress = TaskProgress(kind: .message, text: original)
        XCTAssertEqual(progress.inlineText, "已核对缓存 Checking boundaries 下一步 完成")
        XCTAssertEqual(progress.text, original)
        XCTAssertEqual(TaskProgress(kind: .tool, text: "执行脚本").inlineText, "执行脚本")
        XCTAssertEqual(TaskProgress(kind: .message, text: " \r\n\t\u{2028} ").inlineText, "")
        XCTAssertEqual(TaskProgress(kind: .message, text: "").inlineText, "")
    }

    func testCompactIdentityHelpPreservesFullTitleAndOptionalPath() {
        let title = "任务 · Original title"
        XCTAssertEqual(TaskText.titleHelp(title, path: " /root/review/deep_child \n"),
                       title + "\n/root/review/deep_child")
        XCTAssertEqual(TaskText.titleHelp(title, path: nil), title)
        XCTAssertEqual(TaskText.titleHelp(title, path: " \n"), title)
        XCTAssertEqual(TaskText.pathAccessibilityDescription(nil), "")
        XCTAssertEqual(TaskText.pathAccessibilityDescription(" \n"), "")
    }

    func testCompactProgressAndPathHelpUseLocalizedLabelsAndPreserveContent() {
        for language in ["en", "zh-Hans"] {
            L10n.$languageOverride.withValue(language) {
                let chinese = language == "zh-Hans"
                let text = "Original 内容\nSecond line"
                XCTAssertEqual(TaskProgress(kind: .message, text: text).fullDescription,
                               (chinese ? "最近进展：" : "Latest progress: ") + text)
                XCTAssertEqual(TaskProgress(kind: .tool, text: text).fullDescription,
                               (chinese ? "最近操作：" : "Latest action: ") + text)
                XCTAssertEqual(TaskText.pathAccessibilityDescription(" /root/review "),
                               (chinese ? "任务路径：" : "Task path: ") + "/root/review")
            }
        }
    }
}

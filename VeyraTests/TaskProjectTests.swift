import Foundation
import XCTest

final class TaskProjectTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 100)
    private func project(_ id: String = "p", name: String = "Project", roots: [String]) -> TaskProject {
        TaskProject(id: id, name: name, roots: roots)
    }
    private func task(_ id: String, path: String? = nil, projectID: String? = nil,
                      source: TaskSource = .cli, parent: String? = nil, backend: TaskBackend = .codex,
                      assignment: TaskProjectAssignment = .unavailable, activity: TaskActivity = .running) -> TaskSnapshot {
        TaskSnapshot(id: id, title: id, model: nil, source: source, parentID: parent,
                     startedAt: nil, updatedAt: date, tokens: TokenUsage(), activity: activity,
                     backend: backend, workingDirectory: path, projectID: projectID, projectAssignment: assignment)
    }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func mkdir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    private func write(_ value: String, _ url: URL) throws { try value.write(to: url, atomically: true, encoding: .utf8) }

    func testMigrationIgnoresOldAssignmentsButPreservesExplicitProjectless() async {
        let a = project("a", roots: ["/repo"]), b = project("b", roots: ["/repo"])
        var context = TaskProjectContext(projects: ["a": a, "b": b], aliases: ["old": "a"],
                                         assignments: ["legacy": "old", "db": "a"], projectless: ["none", "cli"])
        let resolver = TaskProjectResolver()
        let tasks = [task("db", path: "/repo", projectID: "b"), task("legacy"), task("none", path: "/repo"),
                     task("broken", path: "/repo", projectID: "deleted")]
        let before = await resolver.resolve(tasks: tasks, ancestors: [], context: context, now: date)
        XCTAssertEqual(before.tasks.map(\.projectAssignment), [.project(a), .project(a), .unassigned, .unassigned])
        context.assignmentsMigrated = true
        context.projects = ["a": a]
        let after = await resolver.resolve(tasks: [task("legacy", source: .desktop), task("cli", path: "/repo"),
                                                   task("desktop", path: "/repo", source: .desktop)],
                                           ancestors: [], context: context, now: date)
        XCTAssertEqual(after.tasks.map(\.projectAssignment), [.unavailable, .unassigned, .project(a)])
    }

    func testPartialMigrationUsesPerThreadAuthorityAndDoesNotRestoreOldAssignments() async {
        let a = project("a", roots: []), b = project("b", roots: [])
        let context = TaskProjectContext(projects: ["a": a, "b": b],
            assignments: ["pending": "a", "migrated": "a", "cleared": "a"],
            pendingAssignmentIDs: ["pending"])
        let result = await TaskProjectResolver().resolve(tasks: [
            task("pending", projectID: "b", source: .desktop),
            task("migrated", projectID: "b", source: .desktop), task("cleared", source: .desktop)],
            ancestors: [], context: context, now: date)
        XCTAssertEqual(result.tasks.map(\.projectAssignment), [.project(a), .project(b), .unavailable])
    }

    func testMigratedMissingMembershipInfersProjectWhileExplicitChoicesRemainAuthoritative() async {
        let p = project(roots: ["/repo"])
        for completed in [false, true] {
            let context = TaskProjectContext(projects: [p.id: p],
                membershipHosts: ["remote-marker": "remote"],
                projectless: ["explicit", "reassigned", "remote-marker"],
                assignmentsMigrated: completed, pendingAssignmentIDs: completed ? nil : ["pending"])
            let result = await TaskProjectResolver().resolve(tasks: [
                task("missing", path: "/repo/src", source: .desktop),
                task("explicit", path: "/repo/src", source: .desktop),
                task("reassigned", path: "/elsewhere", projectID: p.id, source: .desktop),
                task("remote-marker", path: "/repo", source: .desktop),
                task("unknown", source: .desktop),
                task("deleted-project", path: "/repo", projectID: "deleted", source: .desktop)],
                ancestors: [TaskReference(id: "ancestor", title: "Ancestor", parentID: nil,
                    workingDirectory: "/repo", source: .desktop)], context: context, now: date)
            XCTAssertEqual(result.tasks.map(\.projectAssignment), [
                .project(p), .unassigned, .project(p), .project(p), .unavailable, .unassigned])
            XCTAssertEqual(result.ancestors.first?.projectAssignment, .project(p))
            XCTAssertTrue(result.tasks.allSatisfy { $0.activity == .running && $0.backend == .codex })
        }
    }

    func testLongestRootPathBoundariesAmbiguityAndDshInference() async {
        let broad = project("broad", roots: ["/workspace", "/shared"])
        let nested = project("nested", roots: ["/workspace/app", "/other"])
        let overlap = project("overlap", roots: ["/shared"])
        let context = TaskProjectContext(projects: [broad.id: broad, nested.id: nested, overlap.id: overlap],
                                         assignments: ["dsh:1": "broad"])
        let result = await TaskProjectResolver().resolve(tasks: [
            task("nested", path: "/workspace/app/src"), task("prefix", path: "/workspace/application"),
            task("ambiguous", path: "/shared/sub"), task("outside", path: "/workspaces"),
            task("other", path: "/other/sub"), task("dsh:1", path: "/other/sub", backend: .dsh),
            task("relative", path: "workspace/app"), task("no-path")], ancestors: [], context: context, now: date)
        XCTAssertEqual(result.tasks.map(\.projectAssignment), [
            .project(nested), .project(broad), .unavailable, .unavailable,
            .project(nested), .project(nested), .unavailable, .unavailable])
    }

    func testCorruptDesktopMappingDoesNotGuessDesktopMembershipButOtherSourcesCanInfer() async {
        let p = project(roots: ["/repo"])
        let context = TaskProjectContext(projects: [p.id: p], desktopStateUnreadable: true)
        let result = await TaskProjectResolver().resolve(tasks: [
            task("desktop", path: "/repo", projectID: p.id, source: .desktop),
            task("cli", path: "/repo"), task("dsh:1", path: "/repo", source: .desktop, backend: .dsh),
            task("child", path: "/repo", source: .subtask)],
            ancestors: [], context: context, now: date)
        XCTAssertEqual(result.tasks.map(\.projectAssignment), [.unassigned, .project(p), .project(p), .unassigned])
        XCTAssertEqual(result.tasks.map(\.activity), [.running, .running, .running, .running])
    }

    func testMainCheckoutRelativeWorktreesSubdirectoriesSymlinksAndIndependentClone() async throws {
        let directory = try temporaryDirectory()
        let main = directory.appendingPathComponent("main"), worktree = directory.appendingPathComponent("wt")
        let second = directory.appendingPathComponent("wt2"), clone = directory.appendingPathComponent("clone")
        for url in [main.appendingPathComponent(".git/worktrees/wt"), main.appendingPathComponent(".git/worktrees/wt2"),
                    worktree.appendingPathComponent("src"), second, clone.appendingPathComponent(".git")] { try mkdir(url) }
        try write("gitdir: ../main/.git/worktrees/wt\n", worktree.appendingPathComponent(".git"))
        try write("gitdir: \(main.path)/.git/worktrees/wt2\n", second.appendingPathComponent(".git"))
        for name in ["wt", "wt2"] { try write("../..\n", main.appendingPathComponent(".git/worktrees/\(name)/commondir")) }
        let link = directory.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: worktree)
        let p = project(roots: [main.path])
        let context = TaskProjectContext(projects: [p.id: p])
        let result = await TaskProjectResolver().resolve(tasks: [
            task("main", path: main.path), task("wt", path: worktree.path + "/src"),
            task("second", path: second.path), task("link", path: link.path), task("clone", path: clone.path)],
            ancestors: [], context: context, now: date)
        XCTAssertEqual(result.tasks.map(\.projectAssignment), [.project(p), .project(p), .project(p), .project(p), .unavailable])
    }

    func testGitCacheExpiresIncludingMissingAndDeletedMetadata() throws {
        let directory = try temporaryDirectory(), repo = directory.appendingPathComponent("repo")
        try mkdir(repo)
        var identities = TaskRepositoryIdentity()
        XCTAssertNil(identities.identity(for: repo.path, now: date))
        try mkdir(repo.appendingPathComponent(".git"))
        XCTAssertNil(identities.identity(for: repo.path, now: date.addingTimeInterval(29)))
        let identity = identities.identity(for: repo.path, now: date.addingTimeInterval(30))
        XCTAssertNotNil(identity)
        try FileManager.default.removeItem(at: repo)
        XCTAssertEqual(identities.identity(for: repo.path, now: date.addingTimeInterval(31)), identity)
        XCTAssertNil(identities.identity(for: repo.path, now: date.addingTimeInterval(60)))
    }

    func testBrokenWorktreeDoesNotGuessFromDirectoryNameAndOverlapStaysUnknown() async throws {
        let directory = try temporaryDirectory(), main = directory.appendingPathComponent("repo")
        let worktree = directory.appendingPathComponent("elsewhere/repo")
        try mkdir(main.appendingPathComponent(".git/worktrees/wt")); try mkdir(worktree)
        try write("gitdir: \(main.path)/.git/worktrees/wt", worktree.appendingPathComponent(".git"))
        try write("../..", main.appendingPathComponent(".git/worktrees/wt/commondir"))
        let a = project("a", roots: [main.path]), b = project("b", roots: [main.path])
        let resolver = TaskProjectResolver()
        let result = await resolver.resolve(tasks: [task("wt", path: worktree.path)], ancestors: [],
                                           context: TaskProjectContext(projects: ["a": a, "b": b]), now: date)
        XCTAssertEqual(result.tasks[0].projectAssignment, .unavailable)
        try write("gitdir: /missing/repo", worktree.appendingPathComponent(".git"))
        let broken = await TaskProjectResolver().resolve(tasks: [task("wt", path: worktree.path)], ancestors: [],
                                           context: TaskProjectContext(projects: ["a": a]), now: date)
        XCTAssertEqual(broken.tasks[0].projectAssignment, .unavailable)
    }

    func testFamilyUsesAncestorAndDoesNotSplitOrCountContextRows() {
        let a = project("a", roots: []), b = project("b", roots: [])
        let tasks = [task("child", parent: "ended", assignment: .project(b)),
                     task("grandchild", parent: "child", assignment: .project(b), activity: .unknown),
                     task("independent", assignment: .project(a))]
        let ancestors = [TaskReference(id: "ended", title: "Ended", parentID: nil, projectAssignment: .project(a))]
        let groups = TaskProjectGroup.make(groups: TaskGroup.make(tasks: tasks, ancestors: ancestors))
        XCTAssertEqual(groups.count, 1); XCTAssertEqual(groups[0].project, a)
        XCTAssertEqual(groups[0].groups.flatMap(\.rows).map(\.id), ["ended", "child", "grandchild", "independent"])
        XCTAssertEqual(groups[0].runningCount, 2); XCTAssertEqual(groups[0].unknownCount, 1)
        let conflicted = TaskProjectGroup.make(groups: TaskGroup.make(tasks: [
            task("one", parent: "missing", assignment: .project(a)),
            task("two", parent: "missing", assignment: .project(b))], ancestors: []))
        XCTAssertNil(conflicted[0].project); XCTAssertEqual(conflicted[0].groups.count, 1)
        let inherited = TaskProjectGroup.make(groups: TaskGroup.make(tasks: [
            task("one", parent: "missing", assignment: .project(a)), task("two", parent: "one", assignment: .project(b))], ancestors: []))
        XCTAssertEqual(inherited[0].project, a)
    }

    func testProjectOrderingIsStableUnknownLastSameNameDoesNotMergeAndTreesKeepOrder() {
        let a = project("a", name: "Same", roots: ["/a"]), b = project("b", name: "Same", roots: ["/b"])
        var recent = task("recent", assignment: .project(b)); recent = TaskSnapshot(id: recent.id, title: recent.title,
            model: nil, source: .cli, parentID: nil, startedAt: nil, updatedAt: date.addingTimeInterval(1),
            tokens: TokenUsage(), activity: .running, projectAssignment: .project(b))
        let input = [task("unknown"), recent, task("a1", assignment: .project(a)), task("a2", assignment: .project(a))]
        let groups = TaskProjectGroup.make(groups: TaskGroup.make(tasks: input, ancestors: []))
        XCTAssertEqual(groups.map(\.id), ["project:b", "project:a", "unassigned"])
        XCTAssertEqual(groups[1].groups.map(\.id), ["a1", "a2"])
        let tied = TaskProjectGroup.make(groups: TaskGroup.make(tasks: [task("b", assignment: .project(b)), task("a", assignment: .project(a))], ancestors: []))
        XCTAssertEqual(tied.map(\.id), ["project:a", "project:b"])
    }

    func testProjectlessAncestorBlocksDescendantInferenceAndFallbackTitleLocalizes() {
        let p = project(roots: [])
        let groups = TaskGroup.make(tasks: [task("child", parent: "root", assignment: .project(p))],
            ancestors: [TaskReference(id: "root", title: "Root", parentID: nil, projectAssignment: .unassigned)])
        let result = TaskProjectGroup.make(groups: groups)
        XCTAssertNil(result[0].project)
        for language in ["en", "zh-Hans"] {
            L10n.$languageOverride.withValue(language) {
                XCTAssertEqual(result[0].title, language == "en" ? "Unassigned project" : "未归属项目")
                XCTAssertEqual(L10n.text("\(p.name) · \(2) running tasks"), language == "en" ? "Project · 2 running tasks" : "Project · 2 个运行中任务")
            }
        }
    }

    func testProjectCountsSeparateActivityAndSubagentClassification() {
        let tasks = [task("root"), task("child", parent: "root"),
                     task("deep", parent: "child", activity: .unknown),
                     task("standalone-subagent", source: .subtask),
                     task("dsh", backend: .dsh), task("unknown-main", activity: .unknown)]
        let project = TaskProjectGroup(project: nil, groups: TaskGroup.make(tasks: tasks, ancestors: []))
        XCTAssertEqual(project.counts(for: .running), TaskProjectCounts(main: 2, subtasks: 2))
        XCTAssertEqual(project.counts(for: .unknown), TaskProjectCounts(main: 1, subtasks: 1))
        XCTAssertEqual(project.runningCount, 4)
        XCTAssertEqual(project.unknownCount, 2)
    }

    func testOnlyRunningChildDoesNotCountAncestorPlaceholderOrUnknownParent() {
        let child = task("child", parent: "parent")
        let ancestor = TaskReference(id: "parent", title: "Parent", parentID: nil)
        let context = TaskProjectGroup(project: nil, groups: TaskGroup.make(tasks: [child], ancestors: [ancestor]))
        XCTAssertEqual(context.counts(for: .running), TaskProjectCounts(main: 0, subtasks: 1))
        XCTAssertEqual(context.counts(for: .unknown), TaskProjectCounts())
        let mixed = TaskProjectGroup(project: nil, groups: TaskGroup.make(
            tasks: [task("parent", activity: .unknown), child], ancestors: []))
        XCTAssertEqual(mixed.counts(for: .running), TaskProjectCounts(main: 0, subtasks: 1))
        XCTAssertEqual(mixed.counts(for: .unknown), TaskProjectCounts(main: 1, subtasks: 0))
    }

    func testDshSubagentRowsCountAsSubtasksAndRootsAsMainTasks() {
        // dsh spawns a session per subagent; the catalog link makes the row a
        // subtask, so a fan-out never reads as that many independent tasks.
        let child = task("dsh:child", source: .subtask, backend: .dsh)
        let row = TaskGroupRow(reference: TaskReference(id: child.id, title: child.title, parentID: "dsh:parent",
                                                        backend: .dsh),
                               task: child, parentTitle: "Parent", depth: 1)
        XCTAssertTrue(row.isSubagent)
        let project = TaskProjectGroup(project: nil, groups: [TaskGroup(id: row.id, rows: [row])])
        XCTAssertEqual(project.counts(for: .running), TaskProjectCounts(main: 0, subtasks: 1))
        let parent = task("dsh:parent", backend: .dsh)
        let root = TaskGroupRow(reference: TaskReference(id: parent.id, title: parent.title, parentID: nil,
                                                        backend: .dsh),
                                task: parent, parentTitle: nil, depth: 0)
        XCTAssertFalse(root.isSubagent)
    }

    func testProjectCountSummaryLocalizesPluralsAndOmitsZeroParts() {
        for language in ["en", "zh-Hans"] {
            L10n.$languageOverride.withValue(language) {
                let english = language == "en"
                XCTAssertEqual(TaskProjectCounts(main: 1, subtasks: 1).summary,
                               english ? "1 main task · 1 subtask" : "1 主任务 · 1 子任务")
                XCTAssertEqual(TaskProjectCounts(main: 2, subtasks: 3).summary,
                               english ? "2 main tasks · 3 subtasks" : "2 主任务 · 3 子任务")
                XCTAssertEqual(TaskProjectCounts(main: 1, subtasks: 0).summary,
                               english ? "1 main task" : "1 主任务")
                XCTAssertEqual(TaskProjectCounts(main: 0, subtasks: 2).summary,
                               english ? "2 subtasks" : "2 子任务")
                XCTAssertEqual(TaskProjectCounts().summary, english ? "0 main tasks" : "0 主任务")
                XCTAssertEqual(L10n.text("Unconfirmed"), english ? "Unconfirmed" : "未确认")
            }
        }
    }
}

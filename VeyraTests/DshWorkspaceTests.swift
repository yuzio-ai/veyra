import Foundation
import XCTest

final class DshWorkspaceTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 100)

    private func dsh(_ id: String, path: String?) -> TaskSnapshot {
        TaskSnapshot(id: id, title: id, model: nil, source: .desktop, parentID: nil,
                     startedAt: nil, updatedAt: date, tokens: TokenUsage(), activity: .running,
                     backend: .dsh, workingDirectory: path)
    }

    private func catalog(_ json: String) -> DshWorkspaceCatalog {
        DshWorkspaceCatalog.parse(data: Data(json.utf8))
    }

    func testParseKeepsTitlePathAndSessionMembership() throws {
        let catalog = catalog(#"""
        {"unit":{"name":"workspace","version":2},"tables":{"workspaces":{
          "w1":{"path":"/Users/x/mewoo-ios","title":"Mewoo iOS","sessionIds":["session-a","session-b"]},
          "w2":{"path":"/Users/x/mewoo-ios/sub","sessionIds":["session-c"]}
        }}}
        """#)
        XCTAssertEqual(catalog.workspaces.count, 2)
        XCTAssertEqual(catalog.workspace(forSession: "session-a")?.title, "Mewoo iOS")
        XCTAssertEqual(catalog.workspace(forSession: "session-c")?.title, "sub")
        XCTAssertEqual(catalog.workspace(forSession: "missing"), nil)
        XCTAssertEqual(catalog.workspace(forPath: "/Users/x/mewoo-ios/sub/deep/file")?.id, "w2")
        XCTAssertEqual(catalog.workspace(forPath: "/Users/x/mewoo-ios")?.id, "w1")
        XCTAssertNil(catalog.workspace(forPath: "/Users/x/mewoo-iosx"))
    }

    func testEqualRootsStayUnresolvedAndRelativePathsAreIgnored() {
        let catalog = catalog(#"""
        {"tables":{"workspaces":{
          "w1":{"path":"/Users/x/repo","title":"A"},
          "w2":{"path":"/Users/x/repo","title":"B"},
          "w3":{"path":"relative/path","title":"C"}
        }}}
        """#)
        XCTAssertEqual(catalog.workspaces.map(\.id).sorted(), ["w1", "w2"])
        XCTAssertNil(catalog.workspace(forPath: "/Users/x/repo/src"))
    }

    func testMalformedWorkspaceFileDegradesToEmptyCatalog() {
        XCTAssertTrue(catalog("not json").isEmpty)
        XCTAssertTrue(catalog(#"{"tables":{"workspaces":[]}}"#).isEmpty)
        XCTAssertTrue(catalog(#"{"global":{"workspaceIds":["w1"]}}"#).isEmpty)
    }

    func testReaderCachesAndReloadsWhenTheFileChanges() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = home.appendingPathComponent("storages", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let file = directory.appendingPathComponent("workspace.json")
        let reader = DshWorkspaceReader()
        XCTAssertTrue(reader.read(home: home).isEmpty)
        try Data(#"{"tables":{"workspaces":{"w1":{"path":"/repo","title":"Repo"}}}}"#.utf8).write(to: file)
        XCTAssertEqual(reader.read(home: home).workspaces.first?.title, "Repo")
        try Data(#"{"tables":{"workspaces":{"w1":{"path":"/repo","title":"Renamed"}}}}"#.utf8).write(to: file)
        XCTAssertEqual(reader.read(home: home).workspaces.first?.title, "Renamed")
    }

    func testResolverPrefersDshWorkspaceOverCodexProjects() async {
        let codex = TaskProject(id: "codex", name: "Codex Project", roots: ["/repo", "/other"])
        let workspace = DshWorkspace(id: "w1", title: "mewoo-ios", path: "/repo", root: "/repo",
                                     sessionIDs: ["session-1"])
        var workspaces = DshWorkspaceCatalog()
        workspaces.add(workspace)
        let result = await TaskProjectResolver().resolve(tasks: [
            dsh("dsh:session-1", path: "/other"),
            dsh("dsh:session-2", path: "/repo/sub"),
            dsh("dsh:session-3", path: "/elsewhere"),
            dsh("dsh:session-4", path: "/other")
        ], ancestors: [], context: TaskProjectContext(projects: ["codex": codex]),
            workspaces: workspaces, now: date)
        XCTAssertEqual(result.tasks.map(\.projectAssignment), [
            .project(workspace.project), .project(workspace.project), .unavailable, .project(codex)])
    }
}

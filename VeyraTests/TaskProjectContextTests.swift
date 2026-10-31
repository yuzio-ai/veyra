import Foundation
import XCTest

final class TaskProjectContextTests: XCTestCase {
    private func state(_ fixture: SQLiteFixture, migrated: Bool = false, catalogMigrated: Bool = false,
                       name: String = "Legacy", assignment: String = "old", projectless: [String] = []) throws {
        let host = "local:" + fixture.home.path
        let state: [String: Any] = [
            "local-projects": ["old": ["id": "old", "name": name, "rootPaths": ["/repo", "/other"]]],
            "thread-project-assignments": ["thread": ["projectKind": "local", "projectId": assignment]],
            "projectless-thread-ids": projectless,
            "thread-project-membership-host-ids": ["thread": "local"],
            "app-server-project-id-by-legacy-project-id-by-host": [host: ["old": "new"]],
            "app-server-projects-migration-by-host": [host: ["projectsMigrated": catalogMigrated, "threadAssignmentsMigrated": migrated]],
            "unrelated-private-state": ["ignored": "not retained"]]
        try JSONSerialization.data(withJSONObject: state).write(to: fixture.home.appendingPathComponent(".codex-global-state.json"), options: .atomic)
    }
    private func database(_ fixture: SQLiteFixture) throws {
        try fixture.execute("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE projects(id TEXT, name TEXT);
            CREATE TABLE project_roots(project_id TEXT, position INTEGER, path TEXT);
            INSERT INTO projects VALUES ('new', 'Database');
            INSERT INTO project_roots VALUES ('new', 1, '/second'), ('new', 0, '/repo');
            """)
    }

    func testLegacyPartialAndCompleteMigrationSelectsCatalogAndAssignments() throws {
        let fixture = try SQLiteFixture(); try database(fixture)
        let reader = TaskProjectContextReader()
        try state(fixture)
        var context = reader.read(home: fixture.home)
        XCTAssertEqual(context.project("old")?.id, "new")
        XCTAssertEqual(context.project("new")?.name, "Legacy")
        XCTAssertEqual(context.project("old")?.roots, ["/repo", "/other"])
        XCTAssertEqual(context.assignments["thread"], "old")
        XCTAssertFalse(context.assignmentsMigrated)
        try state(fixture, catalogMigrated: true)
        context = reader.read(home: fixture.home)
        XCTAssertEqual(context.project("old")?.name, "Database")
        XCTAssertEqual(context.project("new")?.roots, ["/repo", "/second"])
        XCTAssertEqual(context.assignments["thread"], "old")
        try state(fixture, migrated: true, catalogMigrated: true, projectless: ["thread"])
        context = reader.read(home: fixture.home)
        XCTAssertTrue(context.assignmentsMigrated)
        XCTAssertTrue(context.assignments.isEmpty); XCTAssertTrue(context.projectless.isEmpty)
        try fixture.execute("DELETE FROM projects; DELETE FROM project_roots")
        XCTAssertTrue(reader.read(home: fixture.home).projects.isEmpty, "Do not resurrect deleted migrated projects from legacy state")
    }

    func testFileCacheAtomicReplacementParseFailureRecoveryAndHomeSwitch() throws {
        let first = try SQLiteFixture(), second = try SQLiteFixture()
        let reader = TaskProjectContextReader()
        try state(first)
        XCTAssertEqual(reader.read(home: first.home).project("old")?.name, "Legacy")
        let reads = reader.desktopReads
        _ = reader.read(home: first.home)
        XCTAssertEqual(reader.desktopReads, reads)
        try state(first, name: "Rename")
        XCTAssertEqual(reader.read(home: first.home).project("old")?.name, "Rename")
        try Data("broken".utf8).write(to: first.home.appendingPathComponent(".codex-global-state.json"), options: .atomic)
        XCTAssertTrue(reader.read(home: first.home).projects.isEmpty)
        XCTAssertTrue(reader.read(home: first.home).desktopStateUnreadable)
        let failedReads = reader.desktopReads
        XCTAssertTrue(reader.read(home: first.home).projects.isEmpty)
        XCTAssertEqual(reader.desktopReads, failedReads)
        try state(first, name: "Recover", assignment: "missing")
        XCTAssertEqual(reader.read(home: first.home).assignments["thread"], "missing")
        XCTAssertFalse(reader.read(home: first.home).desktopStateUnreadable)
        try state(second, name: "Second")
        XCTAssertEqual(reader.read(home: second.home).project("old")?.name, "Second")
        XCTAssertEqual(reader.read(home: first.home).project("old")?.name, "Recover")
    }

    func testMissingOptionalTablesColumnsAndMalformedDesktopRetainAvailableDatabaseCatalog() throws {
        let fixture = try SQLiteFixture(); try fixture.threads()
        let reader = TaskProjectContextReader()
        XCTAssertTrue(reader.read(home: fixture.home).projects.isEmpty)
        try fixture.execute("CREATE TABLE projects(id TEXT, name TEXT); INSERT INTO projects VALUES ('p', 'Available')")
        XCTAssertEqual(reader.read(home: fixture.home).projects["p"]?.roots, [])
        try fixture.execute("CREATE TABLE project_roots(project_id TEXT, path TEXT); INSERT INTO project_roots VALUES ('p', '/root')")
        XCTAssertEqual(reader.read(home: fixture.home).projects["p"]?.roots, ["/root"])
        try Data("{bad".utf8).write(to: fixture.home.appendingPathComponent(".codex-global-state.json"))
        XCTAssertEqual(reader.read(home: fixture.home).projects["p"]?.name, "Available")
        try fixture.execute("UPDATE projects SET name='Renamed'; UPDATE project_roots SET path='/moved'")
        let updated = reader.read(home: fixture.home)
        XCTAssertEqual(updated.projects["p"]?.name, "Renamed")
        XCTAssertEqual(updated.projects["p"]?.roots, ["/moved"])
    }

    func testOptionalTaskMetadataReachesSnapshotsAndAncestors() async throws {
        let fixture = try SQLiteFixture(); try fixture.threads()
        try fixture.execute("ALTER TABLE threads ADD COLUMN cwd TEXT; ALTER TABLE threads ADD COLUMN project_id TEXT")
        let parent = try fixture.log("parent"), child = try fixture.log("child")
        try fixture.execute("""
            INSERT INTO threads VALUES ('parent', '\(parent.path)', 'Parent', 'vscode', 'm', 1788400000, 1, '/parent', 'p');
            INSERT INTO threads VALUES ('child', '\(child.path)', 'Child', '{"subagent":{"thread_spawn":{"parent_thread_id":"parent"}}}', 'm', 1788400000, 0, '/child', NULL);
            """)
        var contents = try Data(contentsOf: child)
        contents.append(Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"t\"}}\n".utf8))
        try contents.write(to: child)
        let result = try await LocalTaskReader { _ in ProcessEvidence(threadIDs: ["child"]) }.fetch(home: fixture.home)
        XCTAssertEqual(result.tasks.first?.workingDirectory, "/child")
        XCTAssertEqual(result.ancestors.first?.projectID, "p")
        XCTAssertEqual(result.ancestors.first?.workingDirectory, "/parent")
    }

    @MainActor
    func testStoreRefreshMovesAndRenamesTasksWithoutChangingActivityOrBackend() async throws {
        let fixture = try SQLiteFixture(); try state(fixture)
        let suite = "veyra-project-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(fixture.home.path, forKey: "codexHome")
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let local = TaskSnapshot(id: "thread", title: "Task", model: nil, source: .desktop, parentID: nil,
                                 startedAt: nil, updatedAt: .now, tokens: TokenUsage(), activity: .running)
        let dsh = TaskSnapshot(id: "dsh:s1", title: "dsh", model: nil, source: .desktop, parentID: nil,
                               startedAt: nil, updatedAt: .now, tokens: TokenUsage(), activity: .running,
                               backend: .dsh, workingDirectory: "/repo/sub")
        let store = MonitorStore(readLocal: { _ in TaskReadResult(tasks: [local], fetchedAt: .now, warning: nil) },
                                 readDsh: { _ in DshTaskRead(tasks: [dsh], fetchedAt: .now, warning: nil, parsedFiles: 1, skippedFiles: 0) },
                                 defaults: defaults)
        await store.refreshAll()
        XCTAssertEqual(store.tasks.map(\.projectAssignment).map { assignment -> String? in
            if case .project(let p) = assignment { return p.name }; return nil
        }, ["Legacy", "Legacy"])
        try state(fixture, name: "Renamed", assignment: "missing")
        await store.refreshAll()
        XCTAssertEqual(store.tasks.first?.projectAssignment, .unassigned)
        XCTAssertEqual(store.tasks.last?.projectAssignment, .project(TaskProject(id: "new", name: "Renamed", roots: ["/repo", "/other"])))
        XCTAssertEqual(store.runningTasks.count, 2)
        XCTAssertNil(store.taskError); XCTAssertNil(store.dshWarning)
        try Data("broken".utf8).write(to: fixture.home.appendingPathComponent(".codex-global-state.json"), options: .atomic)
        await store.refreshAll()
        XCTAssertEqual(store.tasks.map(\.activity), [.running, .running])
        XCTAssertEqual(store.tasks.map(\.backend), [.codex, .dsh])
        XCTAssertNil(store.taskError); XCTAssertNil(store.taskWarning); XCTAssertNil(store.dshWarning)
        store.stop()
    }
}

import Foundation

struct TaskProjectContext: Sendable {
    var projects: [String: TaskProject] = [:]
    var aliases: [String: String] = [:]
    var assignments: [String: String] = [:]
    var membershipHosts: [String: String] = [:]
    var projectless: Set<String> = []
    var assignmentsMigrated = false
    var pendingAssignmentIDs: Set<String>?
    var desktopStateUnreadable = false

    func assignmentsMigrated(for id: String) -> Bool {
        assignmentsMigrated || pendingAssignmentIDs.map { !$0.contains(id) } == true
    }

    func project(_ id: String) -> TaskProject? { projects[aliases[id] ?? id] }
}

/// Decode only project fields. Other desktop state is neither retained nor logged.
private struct DesktopProjectState: Decodable {
    struct Project: Decodable {
        let id: String
        let name: String
        let rootPaths: [String]
    }
    struct Assignment: Decodable { let projectKind: String; let projectId: String }
    struct Migration: Decodable {
        let projectsMigrated: Bool?
        let threadAssignmentsMigrated: Bool?
        let pendingThreadAssignmentIds: Set<String>?
    }
    var projects: [String: Project] = [:]
    var assignments: [String: Assignment] = [:]
    var projectless: Set<String> = []
    var membershipHosts: [String: String] = [:]
    var aliases: [String: [String: String]] = [:]
    var migrations: [String: Migration] = [:]

    enum CodingKeys: String, CodingKey {
        case projects = "local-projects"
        case assignments = "thread-project-assignments"
        case projectless = "projectless-thread-ids"
        case membershipHosts = "thread-project-membership-host-ids"
        case aliases = "app-server-project-id-by-legacy-project-id-by-host"
        case migrations = "app-server-projects-migration-by-host"
    }

    init() {}
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projects = try container.decodeIfPresent([String: Project].self, forKey: .projects) ?? [:]
        assignments = try container.decodeIfPresent([String: Assignment].self, forKey: .assignments) ?? [:]
        projectless = try container.decodeIfPresent(Set<String>.self, forKey: .projectless) ?? []
        membershipHosts = try container.decodeIfPresent([String: String].self, forKey: .membershipHosts) ?? [:]
        aliases = try container.decodeIfPresent([String: [String: String]].self, forKey: .aliases) ?? [:]
        migrations = try container.decodeIfPresent([String: Migration].self, forKey: .migrations) ?? [:]
    }
}

/// Confined to TaskProjectResolver. SQLite cache uses data/schema versions;
/// the desktop cache also detects atomic replacement and caches parse failures.
final class TaskProjectContextReader {
    private let databaseCache = SQLiteReadCache<[TaskProject]>()
    private var lastHome: URL?
    private var desktopStamp: String?
    private var desktop = DesktopProjectState()
    private var desktopReadFailed = false
    private(set) var desktopReads = 0

    func read(home: URL) -> TaskProjectContext {
        if lastHome != home {
            databaseCache.reset(); desktopStamp = nil; desktop = DesktopProjectState()
            desktopReadFailed = false; lastHome = home
        }
        let url = home.appendingPathComponent(".codex-global-state.json")
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let stamp = attributes.map { "\($0[.systemFileNumber] ?? 0):\(modified):\($0[.size] ?? 0)" } ?? "missing"
        if desktopStamp != stamp {
            desktopReads += 1
            let decoded = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(DesktopProjectState.self, from: $0) }
            desktop = decoded ?? DesktopProjectState()
            desktopReadFailed = attributes != nil && decoded == nil
            desktopStamp = stamp
        }
        var databaseProjects: [TaskProject] = []
        if let url = SQLiteReader.database(named: "state", in: home) {
            databaseProjects = (try? databaseCache.load(url: url, query: Self.readProjects).value) ?? []
        } else { databaseCache.reset() }
        let host = "local:" + home.path
        let migration = desktop.migrations[host]
        var context = TaskProjectContext()
        context.desktopStateUnreadable = desktopReadFailed
        context.aliases = desktop.aliases[host] ?? [:]
        context.assignmentsMigrated = migration?.threadAssignmentsMigrated == true
        context.pendingAssignmentIDs = migration?.pendingThreadAssignmentIds
        // A NULL project_id does not record whether membership is missing or
        // deliberately cleared. Retain explicit opt-outs across migration;
        // a newer database project_id can supersede them in the resolver.
        context.projectless = desktop.projectless
        context.membershipHosts = desktop.membershipHosts
        for project in desktop.projects.values where migration?.projectsMigrated != true {
            let id = context.aliases[project.id] ?? project.id
            let roots = project.rootPaths.compactMap(TaskText.nonempty)
            context.projects[id] = TaskProject(id: id, name: project.name, roots: roots)
        }
        // Until the project catalog migration completes, legacy names/roots win.
        for project in databaseProjects {
            if migration?.projectsMigrated == true || context.projects[project.id] == nil {
                context.projects[project.id] = project
            }
        }
        if !context.assignmentsMigrated {
            context.assignments = desktop.assignments.compactMapValues {
                $0.projectKind == "local" ? $0.projectId : nil
            }
        }
        return context
    }

    private static func readProjects(_ db: SQLiteReader) throws -> [TaskProject] {
        let columns = try db.columns(in: "projects")
        guard columns.contains("id"), columns.contains("name") else { return [] }
        let rootColumns = try db.columns(in: "project_roots")
        let hasPosition = rootColumns.contains("position")
        var roots: [String: [String]] = [:]
        var primaryRoots: [String: [String]] = [:]
        if rootColumns.contains("project_id"), rootColumns.contains("path") {
            let order = hasPosition ? "project_id, position" : "project_id, path"
            let position = hasPosition ? "position" : "NULL AS position"
            for row in try db.rows("SELECT project_id, path, \(position) FROM project_roots ORDER BY \(order)") {
                guard let id = TaskText.nonempty(row["project_id"]),
                      let path = TaskText.nonempty(row["path"]) else { continue }
                roots[id, default: []].append(path)
                if row["position"] == "0" { primaryRoots[id, default: []].append(path) }
            }
        }
        return try db.rows("SELECT id, name FROM projects").compactMap { row in
            guard let id = TaskText.nonempty(row["id"]), let name = TaskText.nonempty(row["name"]) else { return nil }
            let paths = roots[id] ?? []
            let candidates = hasPosition ? (primaryRoots[id] ?? []) : paths
            let primary = candidates.count == 1 ? candidates.first : nil
            return TaskProject(id: id, name: name, roots: paths, primaryRoot: primary)
        }
    }
}

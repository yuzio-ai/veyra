import Foundation

struct TaskProject: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let roots: [String]
}

/// Unavailable metadata allows inference; an explicit projectless choice does not.
enum TaskProjectAssignment: Equatable, Sendable {
    case project(TaskProject)
    case unassigned
    case unavailable
}

struct TaskProjectCounts: Equatable, Sendable {
    var main = 0
    var subtasks = 0

    var summary: String {
        let mainLabel = L10n.text("\(main) main tasks")
        let subtaskLabel = L10n.text("\(subtasks) subtasks")
        if subtasks == 0 { return mainLabel }
        if main == 0 { return subtaskLabel }
        return L10n.text("\(mainLabel) · \(subtaskLabel)")
    }
}

struct TaskProjectGroup: Identifiable, Equatable, Sendable {
    let project: TaskProject?
    let groups: [TaskGroup]
    var id: String { project.map { "project:" + $0.id } ?? "unassigned" }
    var title: String { project?.name ?? L10n.text("Unassigned project") }
    var runningCount: Int { snapshots.filter { $0.activity == .running }.count }
    var unknownCount: Int { snapshots.filter { $0.activity == .unknown }.count }
    private var snapshots: [TaskSnapshot] { groups.flatMap(\.rows).compactMap(\.task) }
    private var latestActivity: Date {
        snapshots.flatMap { [$0.updatedAt, $0.startedAt ?? .distantPast] }.max() ?? .distantPast
    }

    func counts(for activity: TaskActivity) -> TaskProjectCounts {
        groups.flatMap(\.rows).reduce(into: TaskProjectCounts()) { counts, row in
            guard let task = row.task, task.activity == activity else { return }
            if row.isSubagent { counts.subtasks += 1 }
            else { counts.main += 1 }
        }
    }

    static func make(groups: [TaskGroup]) -> [TaskProjectGroup] {
        var buckets: [String: (TaskProject?, [TaskGroup])] = [:]
        for group in groups {
            // Each known ancestor owns its entire subtree. If separate branches
            // disagree, keep the family together in the unassigned section.
            var selected: TaskProjectAssignment = .unavailable
            var coveredDepth: Int?
            for row in group.rows {
                if let depth = coveredDepth, row.depth > depth { continue }
                coveredDepth = nil
                let assignment = row.reference.projectAssignment
                guard assignment != .unavailable else { continue }
                coveredDepth = row.depth
                if selected == .unavailable { selected = assignment }
                else if selected != assignment { selected = .unassigned }
            }
            let project: TaskProject?
            if case .project(let value) = selected { project = value } else { project = nil }
            let key = project.map { "project:" + $0.id } ?? "unassigned"
            if buckets[key] == nil { buckets[key] = (project, []) }
            buckets[key]?.1.append(group)
        }
        return buckets.values.map { TaskProjectGroup(project: $0.0, groups: $0.1) }.sorted {
            if ($0.project == nil) != ($1.project == nil) { return $0.project != nil }
            if $0.latestActivity != $1.latestActivity { return $0.latestActivity > $1.latestActivity }
            return $0.id < $1.id
        }
    }
}

/// File-system-only Git identity; never starts git or reads repository contents.
struct TaskRepositoryIdentity {
    private struct Entry { let expiresAt: Date; let identity: String? }
    private var entries: [String: Entry] = [:]

    mutating func reset() { entries = [:] }

    static func canonicalPath(_ path: String?) -> String? {
        guard let path = TaskText.nonempty(path), path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    mutating func identity(for path: String, now: Date) -> String? {
        guard let canonical = Self.canonicalPath(path) else { return nil }
        if let cached = entries[canonical], cached.expiresAt > now { return cached.identity }
        // Bound memory even when sessions continually change directories.
        entries = entries.filter { $0.value.expiresAt > now }
        let identity = Self.findIdentity(at: canonical)
        entries[canonical] = Entry(expiresAt: now.addingTimeInterval(30), identity: identity)
        return identity
    }

    private static func text(_ url: URL) -> String? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: 16_385), data.count <= 16_384 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func findIdentity(at path: String) -> String? {
        let files = FileManager.default
        var isDirectory: ObjCBool = false
        guard files.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        var directory = URL(fileURLWithPath: path, isDirectory: true)
        while true {
            let marker = directory.appendingPathComponent(".git")
            if files.fileExists(atPath: marker.path, isDirectory: &isDirectory) {
                let gitDirectory: URL
                if isDirectory.boolValue { gitDirectory = marker }
                else {
                    guard let line = text(marker), line.hasPrefix("gitdir:"),
                          let target = TaskText.nonempty(String(line.dropFirst(7))) else { return nil }
                    gitDirectory = URL(fileURLWithPath: target, relativeTo: directory).standardizedFileURL
                }
                var common = gitDirectory
                let commonFile = gitDirectory.appendingPathComponent("commondir")
                if files.fileExists(atPath: commonFile.path) {
                    guard let target = text(commonFile), !target.isEmpty else { return nil }
                    common = URL(fileURLWithPath: target, relativeTo: gitDirectory).standardizedFileURL
                }
                let canonical = common.resolvingSymlinksInPath().path
                guard files.fileExists(atPath: canonical, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
                return canonical
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { return nil }
            directory = parent
        }
    }
}

struct TaskProjectResolution: Sendable {
    let tasks: [TaskSnapshot]
    let ancestors: [TaskReference]
}

/// Owns all project/Git I/O outside the main actor. A broken catalog never
/// changes task activity, counts, or monitoring warnings.
actor TaskProjectResolver {
    private let reader = TaskProjectContextReader()
    private var repositories = TaskRepositoryIdentity()
    private var lastHome: URL?

    func resolve(tasks: [TaskSnapshot], ancestors: [TaskReference], home: URL) -> TaskProjectResolution {
        if lastHome != home { repositories.reset(); lastHome = home }
        let context = reader.read(home: home)
        return resolve(tasks: tasks, ancestors: ancestors, context: context, now: Date())
    }

    func resolve(tasks: [TaskSnapshot], ancestors: [TaskReference], context: TaskProjectContext,
                 now: Date) -> TaskProjectResolution {
        let tasks = tasks.map { task in
            var copy = task
            copy.projectAssignment = assignment(id: task.id, path: task.workingDirectory, projectID: task.projectID,
                                                source: task.source, backend: task.backend, context: context, now: now)
            return copy
        }
        let ancestors = ancestors.map { reference in
            var copy = reference
            copy.projectAssignment = assignment(id: reference.id, path: reference.workingDirectory, projectID: reference.projectID,
                                                source: reference.source, backend: .codex, context: context, now: now)
            return copy
        }
        return TaskProjectResolution(tasks: tasks, ancestors: ancestors)
    }

    private func assignment(id: String, path: String?, projectID: String?, source: TaskSource,
                            backend: TaskBackend, context: TaskProjectContext, now: Date) -> TaskProjectAssignment {
        if backend == .codex {
            // A corrupt desktop mapping may hide an explicit project choice.
            // Do not replace that choice with a directory-based guess.
            if source != .cli, context.desktopStateUnreadable { return .unassigned }
            let migrated = context.assignmentsMigrated(for: id)
            // Ignore entries belonging to a remote host even if its thread ID is present locally.
            let local = context.membershipHosts[id].map { $0 == "local" } ?? true
            let explicitlyProjectless = local && context.projectless.contains(id)
            if !migrated {
                if explicitlyProjectless { return .unassigned }
                if local, let assignment = context.assignments[id] {
                    return context.project(assignment).map(TaskProjectAssignment.project) ?? .unassigned
                }
            }
            if let projectID {
                return context.project(projectID).map(TaskProjectAssignment.project) ?? .unassigned
            }
            if explicitlyProjectless { return .unassigned }
            // Migration selects which assignment source to trust. It does not
            // turn absent membership into an explicit opt-out from inference.
        }
        guard let path = TaskRepositoryIdentity.canonicalPath(path) else { return .unavailable }
        var matches: [TaskProject] = [], longest = -1
        for project in context.projects.values {
            for root in project.roots {
                guard let root = TaskRepositoryIdentity.canonicalPath(root),
                      path == root || path.hasPrefix(root == "/" ? "/" : root + "/") else { continue }
                if root.count > longest { longest = root.count; matches = [project] }
                else if root.count == longest { matches.append(project) }
            }
        }
        if longest >= 0 { return unique(matches) }
        guard let repository = repositories.identity(for: path, now: now) else { return .unavailable }
        for project in context.projects.values {
            if project.roots.contains(where: { repositories.identity(for: $0, now: now) == repository }) {
                matches.append(project)
            }
        }
        return unique(matches)
    }

    private func unique(_ matches: [TaskProject]) -> TaskProjectAssignment {
        let ids = Set(matches.map(\.id))
        guard ids.count == 1, let project = matches.first else { return .unavailable }
        return .project(project)
    }
}

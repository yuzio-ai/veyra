import Foundation

/// One dsh workspace from `storages/workspace.json`: dsh's own project concept,
/// a titled directory that owns a set of sessions. Codex projects are a
/// different catalog, so dsh tasks resolve against this one first.
struct DshWorkspace: Equatable, Sendable {
    let id: String
    let title: String
    let path: String
    /// Canonical root kept beside the raw path for longest-prefix matching.
    let root: String?
    let sessionIDs: Set<String>

    var project: TaskProject {
        TaskProject(id: "dsh-workspace:" + id, name: title, roots: [path])
    }
}

/// Best-effort view of the workspace table. The file format is unpublished, so
/// a missing, truncated, or reshaped file degrades to "no workspaces" instead
/// of failing the dsh task read.
struct DshWorkspaceCatalog: Equatable, Sendable {
    private(set) var workspaces: [DshWorkspace] = []
    private var sessions: [String: DshWorkspace] = [:]

    static let empty = DshWorkspaceCatalog()
    var isEmpty: Bool { workspaces.isEmpty }

    mutating func add(_ workspace: DshWorkspace) {
        guard !workspaces.contains(where: { $0.id == workspace.id }) else { return }
        workspaces.append(workspace)
        for session in workspace.sessionIDs { sessions[session] = workspace }
    }

    /// Membership is exact, so a session keeps its workspace even after the
    /// working directory moves mid-session.
    func workspace(forSession id: String) -> DshWorkspace? { sessions[id] }

    /// Longest-prefix directory match, for records that carry no membership.
    /// Overlapping roots of equal length stay unresolved on purpose.
    func workspace(forPath path: String) -> DshWorkspace? {
        guard let candidate = TaskRepositoryIdentity.canonicalPath(path) else { return nil }
        var match: DshWorkspace?
        var longest = -1
        for workspace in workspaces {
            guard let root = workspace.root,
                  candidate == root || candidate.hasPrefix(root == "/" ? "/" : root + "/") else { continue }
            if root.count > longest {
                longest = root.count
                match = workspace
            } else if root.count == longest, match?.id != workspace.id {
                match = nil
            }
        }
        return match
    }

    static func parse(data: Data) -> DshWorkspaceCatalog {
        var catalog = DshWorkspaceCatalog()
        guard let table = (try? JSONValue.decode(data))?["tables"]["workspaces"].object else { return catalog }
        for (id, record) in table {
            guard let path = TaskText.nonempty(record["path"].string),
                  path.hasPrefix("/") else { continue }
            let title = TaskText.nonempty(record["title"].string)
                ?? URL(fileURLWithPath: path).lastPathComponent
            let sessions = Set(record["sessionIds"].array?.compactMap { TaskText.nonempty($0.string) } ?? [])
            catalog.add(DshWorkspace(id: id, title: title, path: path,
                                     root: TaskRepositoryIdentity.canonicalPath(path), sessionIDs: sessions))
        }
        return catalog
    }
}

/// Confined to TaskProjectResolver. Cached by stamp so an unchanged workspace
/// file is decoded at most once per poll.
final class DshWorkspaceReader {
    private var lastHome: URL?
    private var stamp: String?
    private var catalog = DshWorkspaceCatalog.empty

    func read(home: URL) -> DshWorkspaceCatalog {
        if lastHome != home {
            lastHome = home
            stamp = nil
            catalog = .empty
        }
        let url = home.appendingPathComponent("storages/workspace.json", isDirectory: false)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let current = attributes.map { "\($0[.systemFileNumber] ?? 0):\(modified):\($0[.size] ?? 0)" } ?? "missing"
        guard current != stamp else { return catalog }
        stamp = current
        catalog = (try? Data(contentsOf: url, options: .mappedIfSafe))
            .map(DshWorkspaceCatalog.parse(data:)) ?? .empty
        return catalog
    }
}

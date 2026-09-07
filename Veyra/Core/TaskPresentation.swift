import Foundation

struct TaskProgress: Equatable, Sendable {
    enum Kind: Sendable { case message, tool }
    let kind: Kind
    let text: String
    var label: String { kind == .message ? L10n.text("Latest progress") : L10n.text("Latest action") }
}

/// Minimal context for ancestors that need not have an active turn or readable rollout.
struct TaskReference: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let parentID: String?
}

struct TaskGroupRow: Identifiable, Equatable, Sendable {
    let reference: TaskReference
    let task: TaskSnapshot?
    let parentTitle: String?
    let depth: Int
    var id: String { reference.id }
}

struct TaskGroup: Identifiable, Equatable, Sendable {
    let id: String
    let rows: [TaskGroupRow]
    var isRunning: Bool { rows.contains { $0.task?.activity == .running } }
    var unknownCount: Int { rows.filter { $0.task?.activity == .unknown }.count }

    /// Input order is the reader's activity/start-time/ID order. Ancestors never add to counts.
    static func make(tasks: [TaskSnapshot], ancestors: [TaskReference]) -> [TaskGroup] {
        var snapshots: [String: TaskSnapshot] = [:], references: [String: TaskReference] = [:]
        for reference in ancestors { references[reference.id] = reference }
        for task in tasks where snapshots[task.id] == nil {
            snapshots[task.id] = task
            references[task.id] = TaskReference(id: task.id, title: task.title, parentID: task.parentID)
        }
        var included: Set<String> = [], priority: [String: Int] = [:]
        for (rank, task) in tasks.enumerated() {
            var next: String? = task.id, visited: Set<String> = []
            while let id = next, visited.insert(id).inserted {
                included.insert(id)
                priority[id] = min(priority[id] ?? rank, rank)
                if references[id] == nil {
                    references[id] = TaskReference(id: id, title: L10n.text("Parent task · \(String(id.prefix(8)))"), parentID: nil)
                }
                next = references[id]?.parentID
            }
        }
        var parents: [String: String] = [:]
        for id in included {
            if let parent = references[id]?.parentID, included.contains(parent) { parents[id] = parent }
        }
        // Break each malformed cycle at a deterministic ID, retaining every task exactly once.
        var checked: Set<String> = []
        for start in included.sorted() where !checked.contains(start) {
            var path: [String] = [], positions: [String: Int] = [:], next: String? = start
            while let id = next, !checked.contains(id) {
                if let position = positions[id] {
                    if let root = path[position...].min() { parents.removeValue(forKey: root) }
                    break
                }
                positions[id] = path.count; path.append(id); next = parents[id]
            }
            checked.formUnion(path)
        }
        func ordered(_ ids: [String]) -> [String] {
            ids.sorted {
                let lhs = priority[$0] ?? Int.max, rhs = priority[$1] ?? Int.max
                return lhs == rhs ? $0 < $1 : lhs < rhs
            }
        }
        var children: [String: [String]] = [:]
        for (id, parent) in parents { children[parent, default: []].append(id) }
        let roots = ordered(included.filter { parents[$0] == nil })
        return roots.map { root in
            var rows: [TaskGroupRow] = [], pending: [(String, Int)] = [(root, 0)]
            while let (id, depth) = pending.popLast() {
                guard let reference = references[id] else { continue }
                rows.append(TaskGroupRow(reference: reference, task: snapshots[id],
                    parentTitle: reference.parentID.flatMap { references[$0]?.title }, depth: depth))
                pending.append(contentsOf: ordered(children[id] ?? []).reversed().map { ($0, depth + 1) })
            }
            return TaskGroup(id: root, rows: rows)
        }
    }
}

enum TaskText {
    static func nonempty(_ value: String?) -> String? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    static func title(_ title: String?, id: String, parentID: String?, agentPath: String?, nickname: String?) -> String {
        if let title = nonempty(title) { return title }
        if let leaf = nonempty(agentPath)?.split(separator: "/").last, leaf != "root" {
            return String(leaf).replacingOccurrences(of: "_", with: " ")
        }
        if let nickname = nonempty(nickname) { return nickname }
        return parentID == nil ? L10n.text("Untitled task") : L10n.text("Subtask · \(String(id.prefix(8)))")
    }
}

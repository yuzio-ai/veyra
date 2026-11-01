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
    var workingDirectory: String?
    var projectID: String?
    var projectAssignment: TaskProjectAssignment = .unavailable
    var source: TaskSource = .desktop
    /// Ancestors resolve against their own backend's catalog, so a dsh family
    /// never falls through to Codex project matching.
    var backend: TaskBackend = .codex
}

struct TaskGroupRow: Identifiable, Equatable, Sendable {
    let reference: TaskReference
    let task: TaskSnapshot?
    let parentTitle: String?
    let depth: Int
    var id: String { reference.id }
    var isSubagent: Bool {
        guard let task else { return false }
        return depth > 0 || task.source == .subtask
    }
}

struct TaskGroup: Identifiable, Equatable, Sendable {
    let id: String
    let rows: [TaskGroupRow]
    var isRunning: Bool { rows.contains { $0.task?.activity == .running } }
    var unknownCount: Int { rows.filter { $0.task?.activity == .unknown }.count }

    /// A group never mixes backends, so the first row that knows its backend
    /// speaks for the family; ancestor-only rows carry it on the reference.
    func backend(tasksByID: [String: TaskSnapshot]) -> TaskBackend {
        for row in rows {
            if let task = tasksByID[row.id] { return task.backend }
            if row.reference.backend != .codex { return row.reference.backend }
        }
        return .codex
    }

    /// Input order is the reader's activity/start-time/ID order. Ancestors never add to counts.
    static func make(tasks: [TaskSnapshot], ancestors: [TaskReference]) -> [TaskGroup] {
        var snapshots: [String: TaskSnapshot] = [:], references: [String: TaskReference] = [:]
        for reference in ancestors { references[reference.id] = reference }
        for task in tasks where snapshots[task.id] == nil {
            snapshots[task.id] = task
            references[task.id] = TaskReference(id: task.id, title: task.title, parentID: task.parentID,
                workingDirectory: task.workingDirectory, projectID: task.projectID,
                projectAssignment: task.projectAssignment, source: task.source, backend: task.backend)
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
    static func subagentBadge(nickname: String?) -> String {
        nonempty(nickname).map { L10n.text("Subagent: \($0)") } ?? L10n.text("Subagent")
    }

    /// dsh sessions record model identifiers, never display names. Surface the
    /// context it does record instead of inventing a prettier name.
    static func modelDetail(model: String?, provider: String?, effort: String?) -> String? {
        guard let model = nonempty(model) else { return nil }
        var parts = [model]
        if let provider = nonempty(provider) { parts.append(L10n.text("provider \(provider)")) }
        if let effort = nonempty(effort) { parts.append(L10n.text("reasoning \(effort)")) }
        return parts.count > 1 ? parts.joined(separator: " · ") : nil
    }

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

/// Exact, localized counts are shared by detail rows, help and accessibility.
enum TaskTokenText {
    static func cacheHit(_ usage: TokenUsage, precise: Bool = true) -> String {
        let percent = usage.cachedInputPercent.map {
            $0.formatted(.number.locale(L10n.languageOverride.map(Locale.init(identifier:)) ?? .current)
                .precision(.fractionLength(precise ? 1 : 0))) + "%"
        } ?? "—"
        return L10n.text("Cache hit \(percent)")
    }

    static func count(_ value: Int64?) -> String {
        guard let value, value >= 0 else { return "—" }
        return value.formatted(.number.locale(L10n.languageOverride.map(Locale.init(identifier:)) ?? .current))
    }

    static func totalHelp(_ usage: TokenUsage) -> String {
        let total = usage.total.flatMap { $0 >= 0 ? $0 : nil }
        let text = total.map { L10n.text("\(count($0)) tokens total") } ?? L10n.text("Total usage unavailable")
        guard usage.hasInconsistentBreakdown else { return text }
        return text + "\n" + L10n.text("The source total differs from the sum of the details.")
    }

    static func outputAccessibility(_ usage: TokenUsage) -> String {
        L10n.text("Output \(count(usage.output)), including reasoning \(count(usage.includedReasoningOutput))")
    }
}

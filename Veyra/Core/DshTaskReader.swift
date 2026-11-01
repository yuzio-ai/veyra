import Foundation

struct DshTaskRead: Sendable {
    let tasks: [TaskSnapshot]
    let fetchedAt: Date
    let warning: String?
    let parsedFiles: Int
    let skippedFiles: Int
    var state: TaskSourceReadState = .available
    /// Parents that are not running themselves: kept as context rows so a
    /// running subagent still renders under the task that spawned it.
    var ancestors: [TaskReference] = []

    static let empty = DshTaskRead(tasks: [], fetchedAt: Date(timeIntervalSince1970: 0),
                                   warning: nil, parsedFiles: 0, skippedFiles: 0, state: .notFound)
}

/// Reads dsh sessions from `storages/session_projcache/sessions/*.json` — plain
/// JSON, no SQLite and no compressed logs — and resolves visibility with the
/// same semantics as TaskResolver: the boundary decides running, the process
/// confirms liveness, and stale unconfirmed records are hidden after 24h.
/// Read-only by contract: never writes, never reads credentials, no network.
actor DshTaskReader {
    static let recentActivityWindow = TaskResolver.recentActivityWindow

    private var cache = DshProjcacheCache()
    private var lastHome: URL?
    private let now: @Sendable () -> Date
    private let collectEvidence: @Sendable (URL) async -> DshProcessEvidence

    init(now: @escaping @Sendable () -> Date = Date.init,
         collectEvidence: @escaping @Sendable (URL) async -> DshProcessEvidence = DshProcessEvidence.collect) {
        self.now = now
        self.collectEvidence = collectEvidence
    }

    func fetch(home: URL) async -> DshTaskRead {
        let checkedAt = now()
        if lastHome != home { cache.reset(); lastHome = home }
        let directory = home.appendingPathComponent("storages/session_projcache/sessions", isDirectory: true)
        // A missing dsh installation is not a warning condition: stay silent.
        // Check before collecting evidence so non-dsh users never spawn lsof (F1).
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles])
        } catch {
            cache.keepOnly(paths: [])
            let failure = error as NSError
            let missing = failure.domain == NSCocoaErrorDomain
                && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code)
            return DshTaskRead(tasks: [], fetchedAt: checkedAt,
                              warning: missing ? nil : L10n.text("Unable to read dsh session records. Check its data directory."),
                              parsedFiles: 0, skippedFiles: 0, state: missing ? .notFound : .failed)
        }
        let evidence = await collectEvidence(home)
        var records: [DshSessionMetadata] = [], parsed = 0, skipped = 0
        var livePaths: Set<String> = []
        for url in urls where url.pathExtension == "json" {
            livePaths.insert(url.path)
            let attributes = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let stamp = DshProjcacheCache.stamp(modificationDate: attributes?.contentModificationDate,
                                                size: attributes?.fileSize.map { Int64($0) })
            let loaded = cache.load(url: url, stamp: stamp)
            guard let metadata = loaded.value else { skipped += 1; continue }
            parsed += 1
            records.append(metadata)
        }
        cache.keepOnly(paths: livePaths)
        let links = Self.parentLinks(in: records)
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var tasks: [TaskSnapshot] = [], resolved: Set<String> = []
        for metadata in records {
            // A catalogued child whose parent record is gone keeps the subtask
            // classification but loses the dangling link.
            let parentID = links[metadata.id].flatMap { byID[$0] != nil ? Self.taskID($0) : nil }
            guard let task = resolve(metadata: metadata, parentID: parentID, evidence: evidence, now: checkedAt)
            else { continue }
            resolved.insert(metadata.id)
            tasks.append(task)
        }
        tasks.sort {
            if $0.activity != $1.activity { return $0.activity == .running }
            if $0.startedAt != $1.startedAt { return ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
            return $0.id < $1.id
        }
        // Mirror the Codex warning priority: process verification first.
        let warning = !evidence.reliable
            ? L10n.text("Unable to verify dsh processes. Task status is uncertain.")
            : skipped > 0 ? L10n.text("Some dsh session records are unreadable.") : nil
        return DshTaskRead(tasks: tasks, fetchedAt: checkedAt, warning: warning,
                           parsedFiles: parsed, skippedFiles: skipped,
                           ancestors: ancestors(of: resolved, links: links, byID: byID))
    }

    /// dsh writes one session per subagent and records the parent link only in
    /// the parent's `subagentCatalog`, so the family is rebuilt from every
    /// record on each poll. A missing or bounded catalog simply leaves the
    /// child standalone.
    static func parentLinks(in records: [DshSessionMetadata]) -> [String: String] {
        var links: [String: String] = [:]
        for record in records {
            for child in record.subagentChildren where child.id != record.id {
                if links[child.id] == nil { links[child.id] = record.id }
            }
        }
        return links
    }

    static func taskID(_ sessionID: String) -> String { "dsh:" + sessionID }

    /// Finished parents still name the family in the panel; they are context
    /// only and never add to counts.
    private func ancestors(of resolved: Set<String>, links: [String: String],
                           byID: [String: DshSessionMetadata]) -> [TaskReference] {
        var ancestors: [String: TaskReference] = [:]
        for id in resolved {
            var next = links[id]
            var visited: Set<String> = [id]
            while let parentID = next, visited.insert(parentID).inserted, let parent = byID[parentID] {
                if !resolved.contains(parentID) {
                    ancestors[parentID] = TaskReference(
                        id: Self.taskID(parentID), title: parent.displayTitle,
                        parentID: links[parentID].flatMap { byID[$0] != nil ? Self.taskID($0) : nil },
                        workingDirectory: parent.workingDirectory,
                        source: parent.subagentLabel == nil ? .desktop : .subtask,
                        backend: .dsh)
                }
                next = links[parentID]
            }
        }
        return ancestors.values.sorted { $0.id < $1.id }
    }

    private func resolve(metadata: DshSessionMetadata, parentID: String?,
                         evidence: DshProcessEvidence, now: Date) -> TaskSnapshot? {
        guard let updatedAt = metadata.latestActivity else { return nil }
        let hasProcess = evidence.matches(sessionID: metadata.id)
        switch metadata.turnOpen {
        case .some(false):
            // A finished turn ends the task even while the session stays open.
            return nil
        case .some(true), .none:
            if metadata.turnOpen == nil, !hasProcess,
               now.timeIntervalSince(updatedAt) >= Self.recentActivityWindow { return nil }
            if evidence.reliable, !hasProcess, let latest = metadata.latestActivity,
               now.timeIntervalSince(latest) >= Self.recentActivityWindow { return nil }
            let activity: TaskActivity = metadata.turnOpen == true && hasProcess && evidence.reliable
                ? .running : .unknown
            // Catalogued children and labelled subagents are subtasks even when
            // the parent link is missing, so they never inflate the main count.
            let isSubtask = parentID != nil || metadata.subagentLabel != nil
            return TaskSnapshot(id: Self.taskID(metadata.id), title: metadata.displayTitle, model: metadata.model,
                                source: isSubtask ? .subtask : .desktop, parentID: parentID,
                                // Approximation: a turn starts with the latest prompt;
                                // the record carries no separate turn-start timestamp.
                                startedAt: metadata.turnOpen == true ? metadata.lastPromptAt : nil,
                                updatedAt: updatedAt, tokens: metadata.tokens, activity: activity,
                                agentNickname: metadata.subagentLabel,
                                backend: .dsh, workingDirectory: metadata.workingDirectory,
                                modelProvider: metadata.modelProvider,
                                reasoningEffort: metadata.reasoningEffort)
        }
    }
}

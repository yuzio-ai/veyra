import Foundation

struct DshTaskRead: Sendable {
    let tasks: [TaskSnapshot]
    let fetchedAt: Date
    let warning: String?
    let parsedFiles: Int
    let skippedFiles: Int

    static let empty = DshTaskRead(tasks: [], fetchedAt: Date(timeIntervalSince1970: 0),
                                   warning: nil, parsedFiles: 0, skippedFiles: 0)
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
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else {
            cache.keepOnly(paths: [])
            return DshTaskRead(tasks: [], fetchedAt: checkedAt, warning: nil, parsedFiles: 0, skippedFiles: 0)
        }
        let evidence = await collectEvidence(home)
        var tasks: [TaskSnapshot] = [], parsed = 0, skipped = 0
        var livePaths: Set<String> = []
        for url in urls where url.pathExtension == "json" {
            livePaths.insert(url.path)
            let attributes = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let stamp = DshProjcacheCache.stamp(modificationDate: attributes?.contentModificationDate,
                                                size: attributes?.fileSize.map { Int64($0) })
            let loaded = cache.load(url: url, stamp: stamp)
            guard let metadata = loaded.value else { skipped += 1; continue }
            parsed += 1
            if let task = resolve(metadata: metadata, evidence: evidence, now: checkedAt) { tasks.append(task) }
        }
        cache.keepOnly(paths: livePaths)
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
                           parsedFiles: parsed, skippedFiles: skipped)
    }

    private func resolve(metadata: DshSessionMetadata, evidence: DshProcessEvidence, now: Date) -> TaskSnapshot? {
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
            return TaskSnapshot(id: "dsh:" + metadata.id, title: metadata.displayTitle, model: metadata.model,
                                source: .desktop, parentID: nil,
                                // Approximation: a turn starts with the latest prompt;
                                // the record carries no separate turn-start timestamp.
                                startedAt: metadata.turnOpen == true ? metadata.lastPromptAt : nil,
                                updatedAt: updatedAt, tokens: metadata.tokens, activity: activity,
                                backend: .dsh)
        }
    }
}

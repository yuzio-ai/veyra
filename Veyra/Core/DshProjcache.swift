import Foundation

/// One child session listed by a parent's `subagentCatalog` row. `dsh` spawns
/// a full session per subagent, so this is the only parent link the record
/// carries; the child's own file never names its parent.
struct DshSubagentSession: Equatable, Sendable {
    let id: String
    let label: String?
}

/// One parsed `storages/session_projcache/sessions/<id>.json` record. Every
/// field is optional: the format is unpublished (observed v7, dsh 0.1.5-rc),
/// so parsing is best-effort and degrades instead of failing (AC-5).
struct DshSessionMetadata: Equatable, Sendable {
    let id: String
    let title: String?
    let subagentLabel: String?
    let createdAt: Date?
    let lastPromptAt: Date?
    /// nil when the turnBoundary row is absent or malformed: state unknown,
    /// as opposed to `false` (turn finished) or `true` (turn running).
    let turnOpen: Bool?
    let tokens: TokenUsage
    let model: String?
    /// Provider and effort live beside the model id; neither is a display name.
    let modelProvider: String?
    let reasoningEffort: String?
    let formatVersion: Int?
    var workingDirectory: String?
    var hasCompleteAPICostUsage = false
    /// Sessions this record spawned as subagents. The window is bounded (only
    /// recent children are listed): an aged-out child loses its parent link
    /// rather than failing the read.
    var subagentChildren: [DshSubagentSession] = []

    /// Recorded activity only; file timestamps are never used (a migration
    /// could refresh them without any real activity).
    var latestActivity: Date? { [lastPromptAt, createdAt].compactMap { $0 }.max() }
    var displayTitle: String {
        TaskText.nonempty(title) ?? TaskText.nonempty(subagentLabel) ?? L10n.text("Untitled task")
    }

    /// Returns nil when the data is not a JSON object at all; missing or
    /// unknown fields simply leave the corresponding property nil.
    static func parse(id: String, data: Data) -> DshSessionMetadata? {
        guard let value = try? JSONValue.decode(data), value.object != nil else { return nil }
        let record = value["record"]
        let identity = record["identity"]
        let rows = record["rows"]
        func timestamp(_ number: Double?) -> Date? {
            guard let number, number.isFinite, number > 0 else { return nil }
            return Date(timeIntervalSince1970: number / 1000)
        }
        let openSeq = rows["turnBoundary"]["val"]["openTurnStartSeq"]
        let turnOpen: Bool? = rows["turnBoundary"]["val"].object == nil ? nil : openSeq.integer != nil
        let totals = rows["tokenUsage"]["val"]["totals"]
        let lastUsed = rows["modelSelection"]["val"]["lastUsed"]
        let tokens = TokenUsage(
            input: Self.sum(totals["uncachedInputTokens"].integer, totals["cacheReadTokens"].integer,
                            totals["cacheWriteTokens"].integer),
            output: totals["outputTokens"].integer,
            cachedInput: totals["cacheReadTokens"].integer,
            total: nil)
        // Subagent children are listed only while they are recent; the entry
        // names the child session and (usually) its dsh-assigned label.
        let children = (rows["subagentCatalog"]["val"]["head"]["values"].array ?? []).compactMap { entry in
            TaskText.nonempty(entry["childId"].string).map {
                DshSubagentSession(id: $0, label: TaskText.nonempty(entry["label"].string))
            }
        }
        return DshSessionMetadata(
            id: id,
            title: rows["title"]["val"].string,
            subagentLabel: rows["subagent"]["val"]["identity"]["label"].string,
            createdAt: timestamp(identity["createdAt"].double),
            lastPromptAt: timestamp(rows["sessionListMetadata"]["val"]["lastPromptAt"].double),
            turnOpen: turnOpen,
            tokens: tokens.withTotal(),
            model: lastUsed["model"].string,
            modelProvider: TaskText.nonempty(lastUsed["provider"].string),
            reasoningEffort: TaskText.nonempty(lastUsed["reasoningEffort"].string),
            formatVersion: value["version"].integer.map { Int($0) },
            workingDirectory: TaskText.nonempty(identity["cwd"].string),
            hasCompleteAPICostUsage: ["uncachedInputTokens", "cacheReadTokens", "cacheWriteTokens", "outputTokens"].allSatisfy {
                guard let number = totals[$0].double, let count = totals[$0].integer else { return false }
                return count >= 0 && number.rounded(.towardZero) == number
            },
            subagentChildren: children)
    }

    private static func sum(_ parts: Int64?...) -> Int64? {
        var total: Int64 = 0, seen = false
        for part in parts {
            guard let part else { continue }
            let result = total.addingReportingOverflow(part)
            guard !result.overflow else { return nil }
            total = result.partialValue; seen = true
        }
        return seen ? total : nil
    }
}

private extension TokenUsage {
    /// Derives total from input+output when the record carries no explicit one.
    func withTotal() -> TokenUsage {
        var copy = self
        if copy.total == nil, let input = copy.input, let output = copy.output {
            let sum = input.addingReportingOverflow(output)
            copy.total = sum.overflow ? nil : sum.partialValue
        }
        return copy
    }
}

/// mtime+size-stamped cache mirroring SQLiteReadCache: unchanged files are not
/// reparsed, and parse failures are cached too so a corrupt file is not
/// re-decoded on every poll.
struct DshProjcacheCache {
    private var entries: [String: (stamp: String, value: DshSessionMetadata?)] = [:]

    mutating func reset() { entries = [:] }

    /// Keeps only the given paths, dropping cache entries for deleted files.
    mutating func keepOnly(paths: Set<String>) { entries = entries.filter { paths.contains($0.key) } }

    static func stamp(modificationDate: Date?, size: Int64?) -> String {
        "\(modificationDate?.timeIntervalSince1970 ?? 0):\(size ?? -1)"
    }

    /// Returns the cached or freshly parsed metadata, plus whether a parse ran.
    mutating func load(url: URL, stamp: String) -> (value: DshSessionMetadata?, parsed: Bool) {
        if let entry = entries[url.path], entry.stamp == stamp { return (entry.value, false) }
        let id = url.deletingPathExtension().lastPathComponent
        let value = (try? Data(contentsOf: url, options: .mappedIfSafe))
            .flatMap { DshSessionMetadata.parse(id: id, data: $0) }
        entries[url.path] = (stamp, value)
        return (value, true)
    }
}

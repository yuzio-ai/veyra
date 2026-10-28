import Foundation

struct HistoryScanProgress: Sendable {
    let completed: Int
    let total: Int
}

/// Independent from the five-second monitor. Source files and SQLite connections are always read-only.
actor HistoryIndex {
    private struct Cursor: Codable {
        var path: String
        var identity: String = ""
        var size: UInt64 = 0
        var modified: Date?
        var offset: UInt64 = 0
        var prefixHash: UInt64 = 0
        var parser: HistoryParser
        var parserRevision: Int?
    }
    private struct Partition: Codable {
        var cursors: [String: Cursor] = [:]
        var retainedTasks: [String: HistoryTask] = [:]
        var updatedAt: Date?
    }
    private struct DiskIndex: Codable {
        var version = 1
        var partitions: [String: Partition] = [:]
    }
    private let indexURL: URL
    private var disk = DiskIndex()
    private var loaded = false

    init(indexURL: URL) { self.indexURL = indexURL }

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Veyra/History/index.json")
    }

    func clear() throws {
        // Clear all configured roots, including retained records whose source was deleted.
        disk = DiskIndex(); loaded = true
        try save()
    }

    func scan(home: URL, now: Date = Date(),
              progress: @Sendable (HistoryScanProgress) async -> Void = { _ in }) async throws -> HistorySnapshot {
        try load()
        let home = home.standardizedFileURL.resolvingSymlinksInPath()
        let key = home.path
        var partition = disk.partitions[key] ?? Partition()
        var needsSave = disk.partitions[key] == nil
        var snapshot = HistorySnapshot()
        var metadata: [String: HistoryTask] = [:]
        var paths: [String: String] = [:]
        var canonicalPaths: [String: String] = [:]
        var excludedPaths: Set<String> = []
        if let url = SQLiteReader.database(named: "state", in: home) {
            do {
                let db = try SQLiteReader(url: url)
                let columns = try db.columns(in: "threads")
                guard columns.contains("id"), columns.contains("rollout_path") else { throw MonitorFailure("schema") }
                let optional = ["name", "title", "cwd", "source", "archived", "model"]
                    .map { columns.contains($0) ? $0 : "NULL AS \($0)" }.joined(separator: ",")
                for row in try db.rows("SELECT id, rollout_path, \(optional) FROM threads") {
                    guard let id = row["id"], let path = row["rollout_path"] else { continue }
                    let source = row["source"] ?? ""
                    let sourceJSON = source.data(using: .utf8).flatMap { try? JSONValue.decode($0) }
                    if row["model"]?.hasPrefix("codex-auto-review") == true || sourceJSON?["subagent"]["other"].string != nil {
                        let absolute = path.hasPrefix("/") ? URL(fileURLWithPath: path) : home.appendingPathComponent(path)
                        excludedPaths.insert(absolute.standardizedFileURL.resolvingSymlinksInPath().path)
                        continue
                    }
                    let parent = sourceJSON?["subagent"]["thread_spawn"]["parent_thread_id"].string
                    metadata[id] = HistoryTask(id: id, title: TaskText.historyTitle(name: row["name"], title: row["title"]),
                        project: TaskText.nonempty(row["cwd"]), source: ["cli", "exec"].contains(source) ? "cli" : "desktop",
                        parentID: parent, archived: row["archived"] == "1")
                    let absolute = path.hasPrefix("/") ? URL(fileURLWithPath: path) : home.appendingPathComponent(path)
                    paths[absolute.standardizedFileURL.resolvingSymlinksInPath().path] = id
                    canonicalPaths[id] = absolute.standardizedFileURL.resolvingSymlinksInPath().path
                }
            } catch { snapshot.metadataUnavailable = true }
        } else { snapshot.metadataUnavailable = true }

        // Include readable orphan and archived logs even when the state database no longer lists them.
        for folder in ["sessions", "archived_sessions"] {
            let directory = home.appendingPathComponent(folder)
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            var enumerationFailed = false
            let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles], errorHandler: { _, _ in enumerationFailed = true; return false })
            while let url = enumerator?.nextObject() as? URL {
                let path = url.standardizedFileURL.resolvingSymlinksInPath().path
                if url.pathExtension == "jsonl", paths[path] == nil, !excludedPaths.contains(path) {
                    paths[path] = "log-" + url.deletingPathExtension().lastPathComponent
                }
            }
            if enumerationFailed || enumerator == nil { snapshot.unreadableFiles += 1 }
        }
        for path in excludedPaths {
            if partition.cursors.removeValue(forKey: path) != nil { needsSave = true }
        }
        let work = Set(paths.keys).union(partition.cursors.keys).sorted()
        snapshot.totalFiles = work.count
        for (number, path) in work.enumerated() {
            try Task.checkCancellation()
            let original = partition.cursors[path]
            let id = paths[path] ?? partition.cursors[path]?.parser.task.id ?? path
            var cursor = partition.cursors[path] ?? Cursor(path: path, parser: HistoryParser(task:
                metadata[id] ?? HistoryTask(id: id, title: L10n.text("Untitled task"), source: "desktop", parentID: nil)))
            if cursor.parserRevision != 5, FileManager.default.fileExists(atPath: path) {
                // Replay readable logs after parsing fixes without clearing retained, deleted sources.
                var task = metadata[id] ?? cursor.parser.task
                task.turns = []
                cursor = Cursor(path: path, parser: HistoryParser(task: task), parserRevision: 5)
                needsSave = true
            }
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: path)
                let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                let identity = "\(attributes[.systemNumber] ?? 0):\(attributes[.systemFileNumber] ?? 0)"
                let modified = attributes[.modificationDate] as? Date
                if identity != cursor.identity || size != cursor.size || modified != cursor.modified || cursor.offset < size {
                    let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
                    defer { try? file.close() }
                    let prefix = try file.read(upToCount: Int(min(4096, size))) ?? Data()
                    snapshot.bytesRead += prefix.count
                    let hash = prefix.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
                    // Compare the original prefix length on append; a short file's growing prefix isn't replacement.
                    let oldPrefix = prefix.prefix(Int(min(4096, cursor.size)))
                    let oldHash = oldPrefix.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
                    let replaced = identity != cursor.identity || size < cursor.size || oldHash != cursor.prefixHash
                        || (size == cursor.size && modified != cursor.modified)
                    let retainedTask = cursor.parser.task
                    let retained = replaced ? retainedTask.turns : []
                    let retainedSamples = Dictionary(retained.flatMap(\.samples).map { ($0.id, $0) },
                                                     uniquingKeysWith: { first, _ in first })
                    if replaced {
                        cursor.offset = 0
                        var task = metadata[id] ?? cursor.parser.task; task.turns = []
                        cursor.parser = HistoryParser(task: task)
                    }
                    try file.seek(toOffset: cursor.offset)
                    var pending = Data(), lineOffset = cursor.offset, discarding = false
                    while let chunk = try file.read(upToCount: 256 * 1024), !chunk.isEmpty {
                        try Task.checkCancellation()
                        snapshot.bytesRead += chunk.count
                        pending.append(chunk)
                        while let newline = pending.firstIndex(of: 10) {
                            let count = pending.distance(from: pending.startIndex, to: newline) + 1
                            if !discarding, count <= 4 * 1024 * 1024 {
                                let sameTask = retainedTask.id == cursor.parser.task.id
                                    && (cursor.parser.sessionID != nil || metadata[cursor.parser.task.id] != nil)
                                cursor.parser.apply(Data(pending.prefix(count - 1)), offset: lineOffset,
                                                    retainedSamples: sameTask ? retainedSamples : [:])
                            } else { cursor.parser.malformedEvents += 1 }
                            lineOffset += UInt64(count)
                            pending.removeFirst(count); cursor.offset = lineOffset; discarding = false
                        }
                        if pending.count > 4 * 1024 * 1024 {
                            // Oversized lines are skipped without retaining private text or unbounded memory.
                            lineOffset += UInt64(pending.count); pending.removeAll(keepingCapacity: false); discarding = true
                        }
                    }
                    // A partial last line is reread on the next refresh; never persist its raw contents.
                    if replaced, retainedTask.id != cursor.parser.task.id, !retained.isEmpty {
                        var oldTask = retainedTask; oldTask.sourceAvailable = false
                        for index in oldTask.turns.indices {
                            oldTask.turns[index].sourceAvailable = false
                            if oldTask.turns[index].result == .running { oldTask.turns[index].result = .unknown }
                        }
                        partition.retainedTasks[oldTask.id] = oldTask
                    } else {
                        mergeRetainedTurns(retained, into: &cursor.parser)
                    }
                    cursor.identity = identity; cursor.size = size; cursor.modified = modified; cursor.prefixHash = hash
                }
                cursor.parser.task.sourceAvailable = true
            } catch is CancellationError { throw CancellationError() }
            catch {
                cursor.parser.task.sourceAvailable = FileManager.default.fileExists(atPath: path)
                if cursor.parser.task.sourceAvailable { snapshot.unreadableFiles += 1 }
            }
            if let item = metadata[cursor.parser.task.id] {
                cursor.parser.task.title = item.title
                cursor.parser.task.project = item.project ?? cursor.parser.task.project
                cursor.parser.task.parentID = item.parentID ?? cursor.parser.task.parentID
                cursor.parser.task.source = item.source; cursor.parser.task.archived = item.archived
            }
            if cursor.parser.internalTask {
                // Keep only a sanitized cursor so excluded orphan logs are not reread on every refresh.
                cursor.parser.task.title = "internal"
                cursor.parser.task.project = nil; cursor.parser.task.parentID = nil; cursor.parser.task.turns = []
                cursor.parser.seenSamples = []; cursor.parser.baseline = nil; cursor.parser.currentModel = nil
                cursor.parser.activeTurnID = nil; cursor.parser.malformedEvents = 0
            }
            if original?.identity != cursor.identity || original?.size != cursor.size
                || original?.modified != cursor.modified || original?.offset != cursor.offset
                || original?.parser.task != cursor.parser.task {
                needsSave = true
            }
            partition.cursors[path] = cursor
            snapshot.scannedFiles = number + 1
            if number % 10 == 0 || number + 1 == work.count {
                await progress(HistoryScanProgress(completed: number + 1, total: work.count))
            }
        }
        if let historyURL = SQLiteReader.database(named: "thread_history", in: home) {
            do {
                let rows = try SQLiteReader(url: historyURL).rows("SELECT thread_id, turn_id, status, started_at, completed_at FROM thread_turns")
                let taskPaths = Dictionary(grouping: partition.cursors.keys, by: { partition.cursors[$0]!.parser.task.id })
                for row in rows {
                    guard let threadID = row["thread_id"], let turnID = row["turn_id"],
                          let paths = taskPaths[threadID] else { continue }
                    func date(_ key: String) -> Date? { row[key].flatMap(Double.init).flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil } }
                    let result: ExecutionResult
                    switch row["status"] {
                    case "completed": result = .completed
                    case "failed": result = .failed
                    case "interrupted", "aborted": result = .interrupted
                    case "inProgress": result = .running
                    default: result = .unknown
                    }
                    for path in paths {
                        guard var cursor = partition.cursors[path] else { continue }
                        let oldTask = cursor.parser.task
                        cursor.parser.mergeStoredTurn(id: turnID, start: date("started_at"), end: date("completed_at"), result: result)
                        if oldTask != cursor.parser.task { needsSave = true }
                        partition.cursors[path] = cursor
                    }
                }
            } catch { snapshot.historyUnavailable = true }
        }
        try Task.checkCancellation()
        partition.updatedAt = now
        disk.partitions[key] = partition
        if needsSave { try save() }
        // Multiple paths for one session must not multiply task, turn or token totals.
        var tasks = partition.retainedTasks
        let orderedPaths = partition.cursors.keys.sorted { a, b in
            let aCanonical = canonicalPaths[partition.cursors[a]!.parser.task.id] == a
            let bCanonical = canonicalPaths[partition.cursors[b]!.parser.task.id] == b
            return aCanonical != bCanonical ? !aCanonical : a < b
        }
        for path in orderedPaths {
            guard let cursor = partition.cursors[path], !cursor.parser.internalTask else { continue }
            var task = cursor.parser.task
            snapshot.malformedEvents += cursor.parser.malformedEvents
            if let previous = tasks[task.id] {
                var turns = Dictionary(previous.turns.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                for turn in task.turns {
                    if let old = turns[turn.id] {
                        var merged = turn
                        merged.startedAt = preciseDate(turn.startedAt, old.startedAt)
                        merged.endedAt = preciseDate(turn.endedAt, old.endedAt)
                        merged.observedAt = [turn.observedAt, old.observedAt].compactMap { $0 }.max()
                        merged.model = turn.model ?? old.model
                        if old.endedAt != nil && turn.endedAt == nil { merged.result = old.result }
                        if old.endedAt == nil && turn.endedAt == nil {
                            let oldObserved = old.observedAt ?? old.startedAt ?? .distantPast
                            let newObserved = turn.observedAt ?? turn.startedAt ?? .distantPast
                            if oldObserved > newObserved || (oldObserved == newObserved && old.result == .unknown) {
                                merged.result = old.result
                            }
                        }
                        merged.samples = Dictionary((old.samples + turn.samples).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }).values.sorted { $0.date < $1.date }
                        merged.hasTokenGap = old.hasTokenGap || turn.hasTokenGap
                        turns[turn.id] = merged
                    } else { turns[turn.id] = turn }
                }
                task.turns = turns.values.sorted { ($0.startedAt ?? $0.observedAt ?? .distantPast) < ($1.startedAt ?? $1.observedAt ?? .distantPast) }
                task.sourceAvailable = task.sourceAvailable || previous.sourceAvailable
            }
            tasks[task.id] = task
        }
        snapshot.tasks = tasks.values.sorted { $0.id < $1.id }; snapshot.updatedAt = now
        return snapshot
    }

    private func preciseDate(_ current: Date?, _ previous: Date?) -> Date? {
        guard let current, let previous else { return current ?? previous }
        let a = current.timeIntervalSince1970, b = previous.timeIntervalSince1970
        // A DB-only copy has whole seconds. It must not erase precise log evidence.
        if floor(a) == floor(b), a == floor(a), b != floor(b) { return previous }
        return current
    }

    private func mergeRetainedTurns(_ retained: [HistoryTurn], into parser: inout HistoryParser) {
        var positions = Dictionary(parser.task.turns.enumerated().map { ($0.element.id, $0.offset) },
                                   uniquingKeysWith: { first, _ in first })
        for var old in retained {
            parser.seenSamples.formUnion(old.samples.map(\.id))
            guard let index = positions[old.id] else {
                old.sourceAvailable = false
                if old.result == .running { old.result = .unknown }
                positions[old.id] = parser.task.turns.count
                parser.task.turns.append(old)
                continue
            }
            let current = parser.task.turns[index]
            var merged = current
            merged.startedAt = preciseDate(current.startedAt, old.startedAt)
            if let start = current.startedAt, let previousStart = old.startedAt,
               floor(start.timeIntervalSince1970) != floor(previousStart.timeIntervalSince1970) {
                merged.startedAt = min(start, previousStart)
            }
            merged.endedAt = preciseDate(current.endedAt, old.endedAt)
            merged.observedAt = [current.observedAt, old.observedAt].compactMap { $0 }.max()
            merged.model = current.model ?? old.model
            if old.endedAt != nil, current.endedAt == nil { merged.result = old.result }
            let currentSamples = Set(current.samples.map(\.id))
            merged.samples = Dictionary((old.samples + current.samples).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }).values.sorted {
                    $0.date != $1.date ? $0.date < $1.date : $0.id < $1.id
                }
            merged.hasTokenGap = old.hasTokenGap || current.hasTokenGap
            merged.sourceAvailable = current.sourceAvailable
                && currentSamples.isSuperset(of: old.samples.map(\.id))
                && merged.startedAt == current.startedAt && merged.endedAt == current.endedAt
                && merged.observedAt == current.observedAt && merged.model == current.model
            parser.task.turns[index] = merged
        }
    }

    private func load() throws {
        guard !loaded else { return }
        if FileManager.default.fileExists(atPath: indexURL.path) {
            do {
                disk = try JSONDecoder().decode(DiskIndex.self, from: Data(contentsOf: indexURL))
                guard disk.version == 1 else { throw MonitorFailure("version") }
            } catch { throw MonitorFailure(L10n.text("The history index is unreadable. Clear it to rebuild from source records.")) }
        }
        loaded = true
    }

    private func save() throws {
        let directory = indexURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(disk).write(to: indexURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
    }
}

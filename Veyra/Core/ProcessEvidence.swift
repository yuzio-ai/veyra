import Foundation

struct ProcessEvidence: Sendable {
    var threadIDs: Set<String> = []
    var rolloutPaths: Set<String> = []
    var reliable = true

    func matches(threadID: String, path: String) -> Bool {
        if threadIDs.contains(threadID) || rolloutPaths.contains(path) { return true }
        guard !rolloutPaths.isEmpty else { return false }
        return rolloutPaths.contains(URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
    }

    static func parse(_ text: String, home: URL) -> ProcessEvidence {
        var evidence = ProcessEvidence()
        var codexProcess = false
        let prefixes = Set([home.path, home.standardizedFileURL.resolvingSymlinksInPath().path]).map { $0 + "/" }
        for line in text.split(separator: "\n") {
            if line.first == "p" { codexProcess = false }
            if line.first == "c" {
                let command = String(line.dropFirst()).lowercased()
                codexProcess = command == "codex" || (command.hasPrefix("codex-") && !command.contains("host"))
            }
            guard line.first == "n", codexProcess else { continue }
            var path = String(line.dropFirst())
            guard path.hasSuffix(".lock") || path.hasSuffix(".jsonl") else { continue }
            if !prefixes.contains(where: path.hasPrefix) {
                // lsof and Foundation can spell the same home differently (including
                // /private/var). Resolve only potentially relevant, unmatched files.
                path = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                guard prefixes.contains(where: path.hasPrefix) else { continue }
            }
            if path.contains("/thread-writer-locks/"), path.hasSuffix(".lock") {
                let id = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                if UUID(uuidString: id) != nil { evidence.threadIDs.insert(id) }
            } else if path.hasSuffix(".jsonl"), path.contains("/sessions/") || path.contains("/archived_sessions/") {
                evidence.rolloutPaths.insert(path)
            }
        }
        return evidence
    }

    static func collect(home: URL) async -> ProcessEvidence {
        await Task.detached(priority: .utility) {
            let process = Process(), pipe = Pipe(), errorPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            process.arguments = ["-nP", "-Fpcn", "-c", "codex"]
            process.standardOutput = pipe
            process.standardError = errorPipe
            do {
                try process.run()
                let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3, execute: watchdog)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit(); watchdog.cancel()
                let errors = errorPipe.fileHandleForReading.readDataToEndOfFile()
                guard process.terminationStatus == 0 || (process.terminationStatus == 1 && errors.isEmpty) else {
                    return ProcessEvidence(reliable: false)
                }
                return parse(String(decoding: data, as: UTF8.self), home: home)
            } catch { return ProcessEvidence(reliable: false) }
        }.value
    }
}

/// dsh counterpart of ProcessEvidence: a live dsh instance holds `session.lock`
/// for every loaded session. The CLI runs as `node`; DeepSeek Harness Desktop
/// runs as `DeepSeek Harness` (plus its renamed helpers, all under the
/// `DeepSeek` prefix), so both are scanned — parsing only keeps `session.lock`
/// paths under home. Read-only by contract: never writes, never reads
/// credentials, no network.
struct DshProcessEvidence: Sendable {
    var sessionIDs: Set<String> = []
    var reliable = true

    /// Process-name prefixes scanned by a single `lsof -c` pass (`-c` matches
    /// by prefix). The CLI is a `node` script, so `node` covers it; `DeepSeek`
    /// covers Harness Desktop and its renamed helpers
    /// (`DeepSeek Harness Helper (Renderer)`); `dsh` is precautionary in case
    /// a native binary ever ships. Kept as constants (not inlined in `collect`)
    /// so tests can pin them: `parse` ignores `c` lines and cannot guard them.
    static let processNames = ["node", "DeepSeek", "dsh"]

    /// Exact `lsof` invocation built from `processNames`; exposed so tests cover
    /// the `collect` path, not just `parse`.
    static var lsofArguments: [String] { ["-nP", "-Fpcn"] + processNames.flatMap { ["-c", $0] } }

    func matches(sessionID: String) -> Bool { sessionIDs.contains(sessionID) }

    static func parse(_ text: String, home: URL) -> DshProcessEvidence {
        var evidence = DshProcessEvidence()
        let prefixes = Set([home.path, home.standardizedFileURL.resolvingSymlinksInPath().path]).map { $0 + "/" }
        for line in text.split(separator: "\n") {
            guard line.first == "n" else { continue }
            var path = String(line.dropFirst())
            guard path.hasSuffix("/session.lock"), path.contains("/sessions/") else { continue }
            if !prefixes.contains(where: path.hasPrefix) {
                // lsof and Foundation can spell the same home differently (including
                // /private/var). Resolve only potentially relevant, unmatched files.
                path = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                guard prefixes.contains(where: path.hasPrefix) else { continue }
            }
            evidence.sessionIDs.insert(URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent)
        }
        return evidence
    }

    static func collect(home: URL) async -> DshProcessEvidence {
        await Task.detached(priority: .utility) {
            let process = Process(), pipe = Pipe(), errorPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            process.arguments = lsofArguments
            process.standardOutput = pipe
            process.standardError = errorPipe
            do {
                try process.run()
                let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3, execute: watchdog)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit(); watchdog.cancel()
                let errors = errorPipe.fileHandleForReading.readDataToEndOfFile()
                guard process.terminationStatus == 0 || (process.terminationStatus == 1 && errors.isEmpty) else {
                    return DshProcessEvidence(reliable: false)
                }
                return parse(String(decoding: data, as: UTF8.self), home: home)
            } catch { return DshProcessEvidence(reliable: false) }
        }.value
    }
}

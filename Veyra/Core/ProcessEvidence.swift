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

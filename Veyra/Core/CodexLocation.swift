import Foundation

struct CodexLocation: Equatable, Sendable {
    let home: URL
    let executable: URL?

    static func resolve(homePath: String = "", executablePath: String = "") -> CodexLocation {
        let env = ProcessInfo.processInfo.environment
        let fallbackHome = env["CODEX_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        let home = URL(fileURLWithPath: ((homePath.isEmpty ? fallbackHome : homePath) as NSString).expandingTildeInPath)
        if !executablePath.isEmpty {
            return CodexLocation(home: home, executable: URL(fileURLWithPath: (executablePath as NSString).expandingTildeInPath))
        }
        let appPaths = ["/Applications/ChatGPT.app/Contents/Resources/codex", "/Applications/Codex.app/Contents/Resources/codex"]
        let userApps = appPaths.map { FileManager.default.homeDirectoryForCurrentUser.path + $0 }
        let searchPaths = (env["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" }
        let candidates = appPaths + userApps + searchPaths + ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        let executable = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
        return CodexLocation(home: home, executable: executable)
    }
}

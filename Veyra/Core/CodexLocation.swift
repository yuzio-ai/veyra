import Foundation

struct CodexLocation: Equatable, Sendable {
    let home: URL
    let executable: URL?

    static func resolve(homePath: String = "", executablePath: String = "",
                        environment: [String: String] = ProcessInfo.processInfo.environment,
                        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> CodexLocation {
        // A blank CODEX_HOME counts as unset: URL(fileURLWithPath: "") resolves to the process
        // working directory, which for a Finder-launched app is the filesystem root.
        let environmentHome = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackHome = (environmentHome?.isEmpty == false ? environmentHome : nil)
            ?? homeDirectory.appendingPathComponent(".codex").path
        let home = URL(fileURLWithPath: ((homePath.isEmpty ? fallbackHome : homePath) as NSString).expandingTildeInPath)
        if !executablePath.isEmpty {
            return CodexLocation(home: home, executable: URL(fileURLWithPath: (executablePath as NSString).expandingTildeInPath))
        }
        let executable = executableCandidates(environment: environment, homeDirectory: homeDirectory)
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
        return CodexLocation(home: home, executable: executable)
    }

    /// Order: desktop app bundles, then user-level installs, then Homebrew, then inherited PATH.
    /// Finder-launched GUI apps rarely see the shell PATH, so fixed user-level paths come first.
    ///
    /// Both user-level entries are documented install locations: `~/.local/bin` is the default
    /// `CODEX_INSTALL_DIR`, and `$CODEX_HOME/packages/standalone` holds the standalone package cache.
    static func executableCandidates(environment: [String: String],
                                     homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        let desktopApps = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
        ]
        let userDesktopApps = desktopApps.map { homeDirectory.appendingPathComponent(String($0.dropFirst())).path }
        let userInstalls = [
            ".local/bin/codex",
            ".codex/packages/standalone/current/bin/codex",
        ].map { homeDirectory.appendingPathComponent($0).path }
        let packageManagers = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        let pathEntries = (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" }
        return desktopApps + userDesktopApps + userInstalls + packageManagers + pathEntries
    }
}

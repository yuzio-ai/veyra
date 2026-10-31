import Foundation

/// Locates the dsh data directory. There is no executable to resolve: dsh has
/// no query CLI, so monitoring reads `$DSH_HOME` (default `~/.dsh`) directly.
struct DshLocation: Equatable, Sendable {
    let home: URL

    static func resolve(homePath: String = "", environment: [String: String] = ProcessInfo.processInfo.environment) -> DshLocation {
        let fallback = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dsh").path
        let override = homePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let inherited = environment["DSH_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let path = !override.isEmpty ? override : (!inherited.isEmpty ? inherited : fallback)
        return DshLocation(home: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    }
}

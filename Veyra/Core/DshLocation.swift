import Foundation

/// Locates the dsh data directory. There is no executable to resolve: dsh has
/// no query CLI, so monitoring reads `$DSH_HOME` (default `~/.dsh`) directly.
struct DshLocation: Equatable, Sendable {
    let home: URL

    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> DshLocation {
        let fallback = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dsh").path
        let path = environment["DSH_HOME"]?.isEmpty == false ? environment["DSH_HOME"]! : fallback
        return DshLocation(home: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    }
}

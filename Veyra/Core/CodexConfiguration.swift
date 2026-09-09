import Foundation

enum CodexPathField: String, CaseIterable, Sendable {
    case home, executable
}

enum CodexPathError: Error, Equatable, Sendable {
    case absolutePathRequired, invalidDirectory, invalidExecutable

    var message: String {
        switch self {
        case .absolutePathRequired: L10n.text("Use an absolute path or a path beginning with ~. Not applied.")
        case .invalidDirectory: L10n.text("Choose an existing, readable directory. Not applied.")
        case .invalidExecutable: L10n.text("Choose an executable file. Not applied.")
        }
    }
}

enum CodexConfigurationState: Equatable, Sendable {
    case detecting, valid, notFound
    case invalid(CodexPathField)
}

struct CodexConfigurationReport: Equatable, Sendable {
    let location: CodexLocation
    let state: CodexConfigurationState
}

enum CodexPathCommitResult: Equatable {
    case applied, unchanged, superseded
    case rejected(CodexPathError)
}

enum CodexConfiguration {
    static func normalized(_ path: String) -> String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Empty overrides are always allowed, even when discovery currently fails.
    static func validate(_ path: String, field: CodexPathField) async -> CodexPathError? {
        await Task.detached { () -> CodexPathError? in
            let path = normalized(path)
            guard !path.isEmpty else { return nil }
            let expanded = (path as NSString).expandingTildeInPath
            guard (expanded as NSString).isAbsolutePath else { return .absolutePathRequired }
            return validateLocation(URL(fileURLWithPath: expanded), field: field)
        }.value
    }

    static func inspect(home: String, executable: String) async -> CodexConfigurationReport {
        await Task.detached {
            let location = CodexLocation.resolve(homePath: home, executablePath: executable)
            let state: CodexConfigurationState
            if validateLocation(location.home, field: .home) != nil {
                state = .invalid(.home)
            } else if let executable = location.executable {
                state = validateLocation(executable, field: .executable) == nil ? .valid : .invalid(.executable)
            } else {
                state = .notFound
            }
            return CodexConfigurationReport(location: location, state: state)
        }.value
    }

    private static func validateLocation(_ url: URL, field: CodexPathField) -> CodexPathError? {
        let resolved = url.resolvingSymlinksInPath()
        let values = try? resolved.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        let files = FileManager.default
        switch field {
        case .home:
            return values?.isDirectory == true && files.isReadableFile(atPath: resolved.path)
                && files.isExecutableFile(atPath: resolved.path) ? nil : .invalidDirectory
        case .executable:
            return values?.isRegularFile == true && files.isExecutableFile(atPath: resolved.path)
                ? nil : .invalidExecutable
        }
    }
}

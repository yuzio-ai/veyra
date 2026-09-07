import Foundation

/// The anchor also resolves resources when Core is compiled into the standalone test bundle.
private final class LocalizationBundleAnchor: NSObject {}

enum L10n {
    static let resourceBundle = Bundle(for: LocalizationBundleAnchor.self)

    /// Scoped test override; production always uses the bundle's system-selected language.
    @TaskLocal static var languageOverride: String?

    static var bundle: Bundle {
        guard let languageOverride,
              let path = resourceBundle.path(forResource: languageOverride, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return resourceBundle }
        return bundle
    }

    static func text(_ value: String.LocalizationValue) -> String {
        String(localized: value, bundle: bundle,
               locale: languageOverride.map(Locale.init(identifier:)) ?? .current)
    }

    static func resetCount(_ count: Int64) -> String {
        text("\(count) resets")
    }
}

enum TaskReadWarning: String, Sendable, CaseIterable {
    case processUnverified = "process_unverified"
    case historyUnavailable = "history_unavailable"
    case sessionUnreadable = "session_unreadable"

    var message: String {
        switch self {
        case .processUnverified: L10n.text("Unable to verify Codex processes. Task status is uncertain.")
        case .historyUnavailable: L10n.text("Some task history is unreadable. Using session events instead.")
        case .sessionUnreadable: L10n.text("Some session records are unreadable. Details may be incomplete.")
        }
    }
}

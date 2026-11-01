import Foundation

/// Validate developer options before creating NSApplication or starting services.
enum AppArguments {
    enum MenuScenario: String, CaseIterable, Sendable {
        case loading, empty, single, longTitle = "long-title", multiple, quotas, error, expanded, unknown
        case edgeCases = "edge-cases", taskProjects = "task-projects"
        case noQuota = "no-quota", cooldown
        case taskFamily = "task-family", familyExpanded = "family-expanded", familyContext = "family-context"
        case tokenBreakdown = "token-breakdown", tokenEdges = "token-edges"
        case apiCosts = "api-costs"
        case quotaRingLow = "quota-ring-low", quotaRingHigh = "quota-ring-high"
        case dshOnly = "dsh-only", dshIdle = "dsh-idle", dshUnknown = "dsh-unknown"
        case dshError = "dsh-error", noSources = "no-sources", mixedError = "mixed-error"
        case refreshing
        case updateAvailable = "update-available"
        case resetCredits = "reset-credits", resetCreditsExpired = "reset-credits-expired"
        case resetCreditsUnknown = "reset-credits-unknown", resetCreditsZero = "reset-credits-zero"
        case resetCreditsUnavailable = "reset-credits-unavailable", resetCreditsOverflow = "reset-credits-overflow"
        case resetCreditsOnly = "reset-credits-only"
        case planProLite = "plan-prolite", planBusiness = "plan-business", planEnterprise = "plan-enterprise"
        case planUnknown = "plan-unknown"
    }

    enum PreviewAppearance: String, CaseIterable, Sendable {
        case light, dark, lightIncreased = "light-increased", darkIncreased = "dark-increased"
    }

    static func accepts(_ arguments: [String]) -> Bool {
        let flags: Set<String> = [
            "--diagnose", "--network", "--energy-benchmark", "--show-menu", "--show-panel",
            "--exit-after-menu-checks", "--preview-reduce-transparency", "--preview-settings-only",
            "--preview-dsh-only", "--exercise-settings", "--exercise-settings-only"
        ]
        let valued: Set<String> = [
            "--render-previews", "--preview-menu", "--preview-appearance", "--capture-menu-to",
            "--exercise-menu-to", "--preview-lease", "--preview-focus-host"
        ]
        var supplied: Set<String> = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if flags.contains(argument) { supplied.insert(argument); index += 1; continue }
            if valued.contains(argument) {
                guard supplied.insert(argument).inserted,
                      index + 1 < arguments.count, !arguments[index + 1].isEmpty,
                      !arguments[index + 1].hasPrefix("-") else { return false }
                let value = arguments[index + 1]
                if argument == "--preview-menu", MenuScenario(rawValue: value) == nil { return false }
                if argument == "--preview-appearance", PreviewAppearance(rawValue: value) == nil { return false }
                index += 2
                continue
            }
            // Foundation defaults and LaunchServices options use a single dash.
            // Reject unknown double-dash commands without echoing their values.
            if argument.hasPrefix("-"), !argument.hasPrefix("--"), argument.count > 1 {
                if argument.hasPrefix("-psn_") { index += 1; continue }
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else { return false }
                index += 2
                continue
            }
            return false
        }
        let modes: Set<String> = ["--diagnose", "--render-previews", "--preview-menu", "--preview-focus-host"]
        guard supplied.intersection(modes).count <= 1 else { return false }
        let renderModifiers: Set<String> = ["--preview-settings-only", "--preview-dsh-only",
                                            "--exercise-settings", "--exercise-settings-only"]
        if !supplied.isDisjoint(with: renderModifiers), !supplied.contains("--render-previews") { return false }
        let menuModifiers: Set<String> = ["--preview-appearance", "--preview-reduce-transparency",
                                          "--exercise-menu-to", "--exit-after-menu-checks"]
        if !supplied.isDisjoint(with: menuModifiers), !supplied.contains("--preview-menu") { return false }
        if supplied.contains("--exit-after-menu-checks"), !supplied.contains("--exercise-menu-to") { return false }
        if supplied.contains("--preview-focus-host"), !supplied.contains("--preview-lease") { return false }
        if supplied.contains("--network"), !supplied.contains("--diagnose") { return false }
        return true
    }
}

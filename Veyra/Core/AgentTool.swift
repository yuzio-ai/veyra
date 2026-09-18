import Foundation
import Observation

/// Identity of a monitored agent tool.
///
/// Strictly orthogonal to the two existing `*Source` enums: `QuotaSource` says
/// where a quota reading came from (local file / network) and `TaskSource` says
/// how a task was produced (CLI / desktop app / subtask). One WorkBuddy task is
/// therefore `AgentTool.workBuddy` *and* `TaskSource.desktop`; the two answer
/// different questions. Never reuse those enums to carry tool identity.
enum AgentTool: String, CaseIterable, Sendable, Identifiable, Hashable {
    case codex, workBuddy, qwenWork

    var id: String { rawValue }

    /// Selection used only when no stored choice exists (first launch, or a
    /// stored value that no longer maps to a case). Named so the fallback never
    /// appears as a bare literal at a read site.
    static let defaultTool: AgentTool = .codex

    /// Tab title. Localized through `L10n`, so both `en` and `zh-Hans` exist.
    var displayName: String {
        switch self {
        case .codex: L10n.text("Codex")
        case .workBuddy: L10n.text("WorkBuddy")
        case .qwenWork: L10n.text("Qwen Work")
        }
    }
}

/// Why a source could not be read. Kept separate from the availability case so
/// the status line can name a cause instead of reporting a generic failure.
enum AdapterFailure: String, Sendable, CaseIterable {
    case openFailed, schemaUnsupported, busy, permissionDenied

    var message: String {
        switch self {
        case .openFailed: L10n.text("The data file could not be opened.")
        case .schemaUnsupported: L10n.text("The data file format is not supported by this version.")
        case .busy: L10n.text("The data file is in use. Retrying automatically shortly.")
        case .permissionDenied: L10n.text("Permission to read the data file was denied.")
        }
    }
}

/// Three states that never mix: usable, absent, or present but unreadable.
/// Anything other than `ready` must be rendered as a status, never as an empty list.
enum AgentToolAvailability: Equatable, Sendable {
    case ready
    case notInstalled
    case unreadable(AdapterFailure)

    var isReady: Bool { self == .ready }

    /// Stable machine-readable code for diagnostics. Deliberately not localized:
    /// it is compared by scripts, never shown to a reader.
    var diagnosticCode: String {
        switch self {
        case .ready: "ready"
        case .notInstalled: "notInstalled"
        case .unreadable(let failure): "unreadable:\(failure.rawValue)"
        }
    }

    /// Status line for a source that cannot render its list. `hasSnapshot` is
    /// false before the first read completes, which is a loading state rather
    /// than a failure.
    func statusMessage(for tool: AgentTool, hasSnapshot: Bool) -> String? {
        guard hasSnapshot else { return L10n.text("Reading local tasks…") }
        switch self {
        case .ready: return nil
        case .notInstalled: return L10n.text("\(tool.displayName) was not detected on this Mac.")
        case .unreadable(let failure):
            return L10n.text("\(tool.displayName) tasks could not be read. \(failure.message)")
        }
    }
}

/// Quota capability of a source. Only the built-in Codex path reads quotas, and
/// this drives the "no readable quota source" state instead of a zeroed card.
enum QuotaCapability: Sendable, Equatable {
    case supported
    case unsupported

    /// Stable machine-readable code for diagnostics; see `diagnosticCode` above.
    var diagnosticCode: String {
        switch self {
        case .supported: "supported"
        case .unsupported: "unsupported"
        }
    }
}

/// One row of the opt-in source report used by the `--sources` diagnostics flag.
///
/// Carries a count and field names only — never a task title, project name,
/// branch or PR URL. That restriction is what keeps diagnostics free of private
/// session content (AC-8, and `AGENTS.md`).
struct SourceDiagnostic: Sendable {
    let tool: AgentTool
    let availability: AgentToolAvailability
    let quotaCapability: QuotaCapability
    let taskCount: Int
}

/// A task plus the source-specific annotation its row should display.
///
/// `TaskSnapshot` is the Codex-shaped model and deliberately keeps its fields;
/// extra source metadata (a project name, a branch) travels beside it so no
/// Codex-only field has to be stretched to carry it.
struct AdapterTask: Sendable, Equatable {
    let snapshot: TaskSnapshot
    let caption: String?
}

/// Task read outcome. Collapses "hard failure" and "succeeded but empty" into
/// one enum so the caller cannot mistake an unreadable database for no tasks.
enum AdapterTaskResult: Sendable {
    case tasks([AdapterTask])
    case empty
    case unavailable(AgentToolAvailability)
}

protocol AgentToolAdapter: Sendable {
    var tool: AgentTool { get }
    var quotaCapability: QuotaCapability { get }
    /// Cheap check used before the first read so an absent application is
    /// reported as absent rather than as a read failure.
    func probe() async -> AgentToolAvailability
    func readTasks() async -> AdapterTaskResult
}

/// Everything one tab needs to render. The Codex instance maps the store's
/// existing fields one to one; other sources map their own section.
struct ToolPresentation: Sendable {
    let tool: AgentTool
    let availability: AgentToolAvailability
    let quotaCapability: QuotaCapability
    let quota: QuotaDisplayState
    let tasks: [TaskSnapshot]
    let taskAncestors: [TaskReference]
    let hasTaskSnapshot: Bool
    let taskError: String?
    let taskWarning: TaskReadWarning?
    let quotaBusy: Bool
    let tasksBusy: Bool
    let localQuotaWarning: String?
    let nextCalibrationAt: Date?
    let modelConfig: CodexModelConfig?
    let pollingSeconds: Int
    /// Row annotations keyed by task id, supplied by the source adapter.
    let captions: [String: String]
    /// False for the built-in Codex source, whose own error and warning notices
    /// are already part of its rendering. Freezing that path is what keeps the
    /// Codex tab unchanged; every other source uses the three-state status card.
    let rendersAvailabilityCard: Bool

    var runningTasks: [TaskSnapshot] { tasks.filter { $0.activity == .running } }

    /// Count beside the section title. Codex has always counted confirmed
    /// running tasks; a source that lists every task counts every task, so the
    /// badge never reads zero next to a full list.
    var headlineCount: Int { rendersAvailabilityCard ? tasks.count : runningTasks.count }

    /// Non-nil when the section must show a status instead of the task list.
    var sourceStatusMessage: String? {
        guard rendersAvailabilityCard else { return nil }
        if let message = availability.statusMessage(for: tool, hasSnapshot: hasTaskSnapshot) { return message }
        return tasks.isEmpty ? L10n.text("No tasks found for this tool.") : nil
    }
}

/// Shared formatting for source adapters. Lives here rather than in the
/// Codex-shaped model file, which stays untouched.
enum AgentToolFormat {
    static func timestamp(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Joins already-localized fragments with the existing `%@ · %@` key, so a
    /// composed caption stays translatable instead of hard-coding separators.
    static func joined(_ parts: [String?]) -> String? {
        let values = parts.compactMap { TaskText.nonempty($0) }
        guard let first = values.first else { return nil }
        return values.dropFirst().reduce(first) { L10n.text("\($0) · \($1)") }
    }
}

/// Per-source task state. Only sources other than Codex use a section; the Codex
/// fields on `MonitorStore` keep their meaning untouched.
@MainActor @Observable
final class AgentToolSection {
    var availability: AgentToolAvailability = .ready
    var tasks: [TaskSnapshot] = []
    var captions: [String: String] = [:]
    var hasSnapshot = false
    var updatedAt: Date?
    var busy = false
}

import Foundation

/// Installation absence is normal; failed reads belong to the affected source only.
enum TaskSourceReadState: Sendable, Equatable {
    case detecting, notFound, available, failed
}

enum LocalTaskReadFailure: Error { case databaseMissing, homeMissing }


struct AccountSnapshot: Equatable, Sendable {
    let identity: String
    let accountID: String?
    let email: String?
    let plan: String?
    let authType: String

    var planDisplayName: String? {
        // Display only: preserve the API tier for identity and account matching.
        // Verified mappings and source version: docs/plan-display-names.md.
        guard let value = plan?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        switch value.lowercased() {
        case "free", "free_workspace", "guest": return "FREE"
        case "go": return "GO"
        case "plus": return "PLUS"
        case "pro", "prolite": return "PRO"
        case "team", "self_serve_business_prolite", "self_serve_business_usage_based": return "BUSINESS"
        case "business", "enterprise", "enterprise_cbp_automation", "enterprise_cbp_usage_based", "ent26":
            return "ENTERPRISE"
        default:
            let readable = value.split { $0 == "_" || $0 == "-" || $0.isWhitespace }
                .map { $0.uppercased() }.joined(separator: " ")
            return readable.isEmpty ? value.uppercased() : readable
        }
    }

    init(json: JSONValue, accountID: String? = nil) {
        email = json["email"].string
        plan = json["planType"].string
        authType = json["type"].string ?? "unknown"
        self.accountID = accountID ?? json["accountId"].string
        identity = self.accountID ?? "\(authType):\(email ?? "unknown"):\(plan ?? "")"
    }

    func matches(_ other: AccountSnapshot) -> Bool {
        if let accountID, let otherID = other.accountID { return accountID == otherID }
        return email != nil && email == other.email && authType == other.authType && plan == other.plan
    }
}

struct QuotaWindow: Identifiable, Equatable, Sendable {
    let id: String
    let bucketID: String
    let bucketName: String
    let isPrimary: Bool
    let usedPercent: Double?
    let durationMinutes: Int64?
    let resetsAt: Date?
    var remainingPercent: Double? { usedPercent.map { min(100, max(0, 100 - $0)) } }
    var durationLabel: String {
        switch durationMinutes {
        case 10_080: L10n.text("Week")
        case 1_440: "24h"
        case .some(let minutes) where minutes > 0 && minutes % 60 == 0: "\(minutes / 60)h"
        case .some(let minutes) where minutes > 0: L10n.text("\(minutes)min")
        default: isPrimary ? L10n.text("Primary quota") : L10n.text("Secondary quota")
        }
    }

    var durationTitle: String {
        switch durationMinutes {
        case 10_080: L10n.text("Weekly quota")
        case .some(let minutes) where minutes > 0 && minutes % 60 == 0:
            L10n.text("\(minutes / 60)h quota")
        case .some(let minutes) where minutes > 0: L10n.text("\(minutes)min quota")
        default: isPrimary ? L10n.text("Primary quota") : L10n.text("Secondary quota")
        }
    }
}

struct QuotaSnapshot: Equatable, Sendable {
    let windows: [QuotaWindow]
    let fetchedAt: Date
    let accountID: String?
    var resetCredits: ResetCreditsSnapshot?
    var menuWindow: QuotaWindow? {
        windows.first { $0.bucketID == "codex" && $0.isPrimary }
            ?? windows.first { $0.bucketID == "codex" } ?? windows.first
    }
    var menuWindows: [QuotaWindow] {
        guard let bucketID = menuWindow?.bucketID else { return [] }
        return Array(windows.filter { $0.bucketID == bucketID }.sorted { lhs, rhs in
            let leftDuration = lhs.durationMinutes.flatMap { $0 > 0 ? $0 : nil } ?? Int64.max
            let rightDuration = rhs.durationMinutes.flatMap { $0 > 0 ? $0 : nil } ?? Int64.max
            if leftDuration != rightDuration { return leftDuration < rightDuration }
            if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
            return lhs.id < rhs.id
        }.prefix(2))
    }

    static func parse(_ value: JSONValue, at date: Date = Date()) -> QuotaSnapshot {
        var windows: [QuotaWindow] = []
        // An explicitly empty multi-bucket response is authoritative.
        let buckets: [(String, JSONValue)]
        if let map = value["rateLimitsByLimitId"].object {
            buckets = map.sorted {
                if ($0.key == "codex") != ($1.key == "codex") { return $0.key == "codex" }
                return $0.key < $1.key
            }.map { ($0.key, $0.value) }
        } else if value["rateLimits"].object != nil {
            buckets = [(value["rateLimits"]["limitId"].string ?? "codex", value["rateLimits"])]
        } else { buckets = [] }
        for (key, bucket) in buckets {
            let name = bucket["limitName"].string ?? (key == "codex" ? "Codex" : key)
            for kind in ["primary", "secondary"] {
                let window = bucket[kind]
                guard window.object != nil else { continue }
                windows.append(QuotaWindow(
                    id: "\(key):\(kind)", bucketID: key, bucketName: name, isPrimary: kind == "primary",
                    usedPercent: window["usedPercent"].double,
                    durationMinutes: window["windowDurationMins"].integer,
                    resetsAt: window["resetsAt"].double.map(Date.init(timeIntervalSince1970:))
                ))
            }
        }
        return QuotaSnapshot(windows: windows, fetchedAt: date, accountID: value["accountId"].string,
                             resetCredits: ResetCreditsSnapshot.parse(value["rateLimitResetCredits"], at: date))
    }
}

/// Only fixed, safe messages cross the RPC boundary into the UI or diagnostics.
enum QuotaFailure: String, Error, LocalizedError, Sendable, CaseIterable {
    case missingExecutable = "missing_executable"
    case missingHome = "missing_home"
    case launchFailed = "launch_failed"
    case disconnected
    case timeout
    case protocolError = "protocol_error"
    case rpcFailed = "rpc_failed"
    case rateLimited = "rate_limited"
    case unauthorized
    case serviceUnavailable = "service_unavailable"
    case notLoggedIn = "not_logged_in"
    case unsupportedAuthentication = "unsupported_authentication"
    case noQuotaWindows = "no_quota_windows"
    case unknown

    var message: String {
        switch self {
        case .missingExecutable: L10n.missingCodexExecutable()
        case .missingHome: L10n.text("Codex data directory does not exist. Check Settings.")
        case .launchFailed: L10n.text("Unable to start Codex. Check the executable and data directory.")
        case .disconnected: L10n.text("Codex disconnected. Try syncing quota again later.")
        case .timeout: L10n.text("Connection to Codex timed out. Try syncing quota again later.")
        case .protocolError: L10n.text("Codex returned unrecognized data. Check version compatibility.")
        case .rpcFailed: L10n.text("Unable to read quotas. Check your Codex sign-in and network connection, then retry.")
        case .rateLimited: L10n.text("Quota requests are rate-limited. Wait for the cooldown to end before syncing again.")
        case .unauthorized: L10n.text("Quota request unauthorized. Check your Codex sign-in.")
        case .serviceUnavailable: L10n.text("Quota service unavailable. Try syncing quota again later.")
        case .notLoggedIn: L10n.text("Sign in to Codex Desktop or the CLI first.")
        case .unsupportedAuthentication: L10n.text("This sign-in method does not provide ChatGPT subscription quotas.")
        case .noQuotaWindows: L10n.text("No quota windows are currently available for this account.")
        case .unknown: L10n.text("An unknown error occurred while reading quotas. Try syncing again later.")
        }
    }

    var errorDescription: String? { message }

    static func classify(_ error: Error) -> QuotaFailure { error as? QuotaFailure ?? .unknown }
}

struct QuotaRefresh: Sendable {
    var account: AccountSnapshot?
    var snapshot: QuotaSnapshot?
    var error: QuotaFailure?
    /// Set when auth is absent/changed, even if the subsequent network request fails.
    var invalidatePrevious: Bool = false
    var failureDetails: QuotaFailureDetails?
    var didRequestQuota = false
}

struct QuotaDisplayState: Sendable {
    var account: AccountSnapshot?
    var snapshot: QuotaSnapshot?
    var error: String?
    private var networkAccount: AccountSnapshot?
    var resetCredits: ResetCreditsSnapshot? { snapshot?.resetCredits }

    mutating func invalidateAccount() {
        networkAccount = nil
        account = nil
        snapshot = nil
    }
    mutating func apply(_ result: QuotaRefresh) {
        let changedAccount = networkAccount.flatMap { previous in result.account.map { !previous.matches($0) } } ?? false
        if result.invalidatePrevious || changedAccount {
            invalidateAccount()
        }
        if let newAccount = result.account {
            // A fresh sidecar's account/read lacks the quota account ID. If its quota
            // request fails, retain the previously verified identity for this account.
            if result.snapshot != nil || networkAccount?.matches(newAccount) != true {
                networkAccount = newAccount
            }
        }
        if let newSnapshot = result.snapshot { snapshot = newSnapshot }
        account = snapshot == nil ? nil : networkAccount
        error = result.error?.message
    }
}

struct TokenUsage: Equatable, Sendable {
    var input: Int64?
    var output: Int64?
    var cachedInput: Int64?
    var reasoningOutput: Int64?
    var total: Int64?

    /// Cached input is a subset of input, never an additional usage bucket.
    var uncachedInput: Int64? {
        guard let input, input >= 0, let cachedInput,
              cachedInput >= 0, cachedInput <= input else { return nil }
        return input - cachedInput
    }

    var includedReasoningOutput: Int64? {
        guard let output, output >= 0, let reasoningOutput,
              reasoningOutput >= 0, reasoningOutput <= output else { return nil }
        return reasoningOutput
    }

    var hasInconsistentBreakdown: Bool {
        guard uncachedInput != nil, let input, let output, output >= 0,
              let total, total >= 0 else { return false }
        let sum = input.addingReportingOverflow(output)
        return sum.overflow || sum.partialValue != total
    }

    var cachedInputPercent: Double? {
        guard let input, input > 0, let cachedInput,
              cachedInput >= 0, cachedInput <= input else { return nil }
        return Double(cachedInput) / Double(input) * 100
    }

    init(input: Int64? = nil, output: Int64? = nil, cachedInput: Int64? = nil,
         reasoningOutput: Int64? = nil, total: Int64? = nil) {
        self.input = input; self.output = output; self.cachedInput = cachedInput
        self.reasoningOutput = reasoningOutput; self.total = total
    }
    init(json: JSONValue) {
        func count(_ name: String) -> Int64? { json[name].integer.flatMap { $0 >= 0 ? $0 : nil } }
        input = count("input_tokens"); output = count("output_tokens")
        cachedInput = count("cached_input_tokens"); reasoningOutput = count("reasoning_output_tokens")
        total = count("total_tokens")
        if total == nil, let input, let output {
            let sum = input.addingReportingOverflow(output)
            if !sum.overflow { total = sum.partialValue }
        }
    }
}

enum TaskActivity: String, Sendable { case running, unknown }

/// The monitoring backend that produced a task. Codex stays the default so
/// existing construction sites remain valid; only the dsh reader passes `.dsh`.
enum TaskBackend: String, Sendable { case codex, dsh }

enum TaskSource: Sendable {
    case cli, desktop, subtask

    var label: String {
        switch self {
        case .cli: "Codex CLI"
        case .desktop: "Codex"
        case .subtask: L10n.text("Subtask")
        }
    }
}

struct TaskSnapshot: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let model: String?
    let source: TaskSource
    let parentID: String?
    let startedAt: Date?
    let updatedAt: Date
    let tokens: TokenUsage
    var activity: TaskActivity
    var agentPath: String?
    var agentNickname: String?
    var agentRole: String?
    var progress: TaskProgress?
    /// Trailing on purpose: the memberwise default keeps every existing call
    /// site valid; `source` carries no meaning for dsh tasks (a placeholder)
    /// and their label comes from the backend instead. (`var`, not `let`:
    /// only variables join the memberwise initializer with a default value.)
    var backend: TaskBackend = .codex
    var workingDirectory: String?
    var projectID: String?
    var projectAssignment: TaskProjectAssignment = .unavailable
    var apiCostSource: TaskAPICostSource?
    /// dsh records keep the provider and effort next to the model id; they are
    /// shown as context instead of being folded into the displayed name.
    var modelProvider: String?
    var reasoningEffort: String?
    var contextUsage: ContextWindowUsage?
    var rolloutModifiedAt: Date?
    /// Fixture-only snapshots avoid reading real session history during previews.
    var sessionStatistics: TaskSessionStatistics?
    /// The badge stays short so the identity row keeps one line; the full
    /// product name is the badge's help and accessibility text.
    var sourceLabel: String { backend == .dsh ? "DSH" : source.label }
    var sourceDetail: String { backend == .dsh ? "DeepSeek Harness" : source.label }
}

struct TaskReadResult: Sendable {
    let tasks: [TaskSnapshot]
    let fetchedAt: Date
    let warning: TaskReadWarning?
    var metrics = TaskReadMetrics()
    var ancestors: [TaskReference] = []
}

enum DisplayFormat {
    static func tokens(_ value: Int64?) -> String {
        guard let value else { return "—" }
        let n = Double(value)
        if n >= 1_000_000_000 { return String(format: "%.2fB", n / 1_000_000_000) }
        if n >= 1_000_000 { return String(format: "%.2fM", n / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", n / 1_000) }
        return String(value)
    }
    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        // Avoid rounding a nearly exhausted quota up to a misleading full percent.
        return value > 0 && value < 1 ? "<1%" : "\(Int(value.rounded(.down)))%"
    }
    static func duration(since start: Date?, now: Date = Date()) -> String {
        guard let start else { return "—" }
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds >= 86_400 { return L10n.text("\(seconds / 86_400)d \(seconds % 86_400 / 3_600)h") }
        if seconds >= 3_600 { return L10n.text("\(seconds / 3_600)h \(seconds % 3_600 / 60)m") }
        if seconds >= 60 { return L10n.text("\(seconds / 60)m \(seconds % 60)s") }
        return L10n.text("\(seconds)s")
    }
}

import Foundation

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

    func rebucketed(to bucketID: String, name: String) -> QuotaWindow {
        QuotaWindow(id: "\(bucketID):\(isPrimary ? "primary" : "secondary")", bucketID: bucketID,
                    bucketName: name, isPrimary: isPrimary, usedPercent: usedPercent,
                    durationMinutes: durationMinutes, resetsAt: resetsAt)
    }
}

enum QuotaSource: String, Sendable { case local, network }

struct QuotaSnapshot: Equatable, Sendable {
    let windows: [QuotaWindow]
    let fetchedAt: Date
    let accountID: String?
    var source: QuotaSource = .network
    var bucketDates: [String: Date] = [:]
    var bucketSources: [String: QuotaSource] = [:]
    /// Local snapshots only: session model that produced each bucket, used to
    /// match buckets against online limit names during the merge.
    var bucketModels: [String: String] = [:]
    var resetCredits: ResetCreditsSnapshot?
    func recordedAt(for bucketID: String) -> Date { bucketDates[bucketID] ?? fetchedAt }
    func source(for bucketID: String) -> QuotaSource { bucketSources[bucketID] ?? source }
    func isStale(bucketID: String, at now: Date) -> Bool {
        guard source(for: bucketID) == .local else { return false }
        return now.timeIntervalSince(recordedAt(for: bucketID)) > 300
            || windows.contains { $0.bucketID == bucketID && ($0.resetsAt.map { $0 <= now } ?? false) }
    }
    var menuWindow: QuotaWindow? {
        windows.first { $0.bucketID == "codex" && $0.isPrimary }
            ?? windows.first { $0.bucketID == "codex" } ?? windows.first
    }

    /// Local events describe complete individual buckets, not the whole account.
    /// Keep untouched online buckets and their provenance until the next sync.
    func updatingBuckets(from local: QuotaSnapshot) -> QuotaSnapshot {
        let localIDs = Set(local.windows.map(\.bucketID)).union(local.bucketDates.keys)
        // token_count events report the limit governing the request under a
        // generic limit_id, so re-target each local bucket to the online bucket
        // matching its session model; the newest record wins target collisions.
        var retargeted: [String: (date: Date, sourceID: String, windows: [QuotaWindow])] = [:]
        for id in localIDs.sorted() {
            let target = targetBucketID(for: id, model: local.bucketModels[id])
            let date = local.recordedAt(for: id)
            guard retargeted[target].map({ date > $0.date }) ?? true else { continue }
            retargeted[target] = (date, id, local.windows.filter { $0.bucketID == id })
        }
        let newerIDs = Set(retargeted.keys.filter { retargeted[$0]!.date > recordedAt(for: $0) })
        guard !newerIDs.isEmpty else { return self }
        let ids = Set(windows.map(\.bucketID)).union(newerIDs).sorted {
            if ($0 == "codex") != ($1 == "codex") { return $0 == "codex" }
            return $0 < $1
        }
        var dates: [String: Date] = [:]
        var sources: [String: QuotaSource] = [:]
        let merged = ids.flatMap { id -> [QuotaWindow] in
            if let replacement = retargeted[id], newerIDs.contains(id) {
                dates[id] = replacement.date
                sources[id] = local.source(for: replacement.sourceID)
                guard replacement.sourceID != id else { return replacement.windows }
                let name = bucketName(for: id) ?? replacement.windows.first?.bucketName ?? id
                return replacement.windows.map { $0.rebucketed(to: id, name: name) }
            }
            dates[id] = recordedAt(for: id)
            sources[id] = source(for: id)
            return windows.filter { $0.bucketID == id }
        }
        var result = QuotaSnapshot(windows: merged, fetchedAt: dates.values.max() ?? fetchedAt,
                                   accountID: nil, bucketDates: dates, bucketSources: sources,
                                   resetCredits: resetCredits)
        // The summary source follows the menu's quota; cards use their own source.
        result.source = result.menuWindow.map { result.source(for: $0.bucketID) } ?? source
        return result
    }

    private func bucketName(for bucketID: String) -> String? {
        windows.first { $0.bucketID == bucketID }?.bucketName
    }

    /// Match a local bucket to its online bucket by session model. Local
    /// limit_ids do not distinguish model families, while online limit names
    /// mirror the model slug (gpt-5.3-codex-spark matches GPT-5.3-Codex-Spark).
    private func targetBucketID(for localID: String, model: String?) -> String {
        guard let slug = model.map(Self.normalized), !slug.isEmpty else { return localID }
        let ids = Set(windows.map(\.bucketID)).sorted()
        for id in ids where Self.normalized(bucketName(for: id) ?? "") == slug { return id }
        for id in ids where Self.normalized(id) == slug { return id }
        return localID
    }

    static func normalized(_ value: String) -> String {
        String(value.lowercased().filter { $0.isLetter || $0.isNumber })
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
        case .missingExecutable: L10n.text("Codex executable not found. Specify it in Settings.")
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
    private(set) var localSnapshot: QuotaSnapshot?
    private var networkSnapshot: QuotaSnapshot?
    private var networkAccount: AccountSnapshot?
    var resetCredits: ResetCreditsSnapshot? { networkSnapshot?.resetCredits }

    mutating func updateLocal(_ value: QuotaSnapshot?) {
        localSnapshot = value
        selectSource()
    }
    mutating func invalidateAccount() {
        networkSnapshot = nil; networkAccount = nil
        account = nil; snapshot = localSnapshot
    }
    private mutating func selectSource() {
        guard let networkSnapshot else {
            snapshot = localSnapshot; account = nil
            return
        }
        snapshot = localSnapshot.map { networkSnapshot.updatingBuckets(from: $0) } ?? networkSnapshot
        // Account metadata remains independently verified until authentication changes.
        // Local/combined quota snapshots never acquire the network account ID.
        account = networkAccount
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
        if let newSnapshot = result.snapshot { networkSnapshot = newSnapshot }
        selectSource()
        error = result.error?.message
    }
}

struct TokenUsage: Equatable, Sendable {
    var input: Int64?
    var output: Int64?
    var cachedInput: Int64?
    var reasoningOutput: Int64?
    var total: Int64?

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

struct TaskSnapshot: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let model: String?
    let sourceLabel: String
    let parentID: String?
    let startedAt: Date?
    let updatedAt: Date
    let tokens: TokenUsage
    var activity: TaskActivity
    var agentPath: String?
    var agentNickname: String?
    var agentRole: String?
    var progress: TaskProgress?
}

struct TaskReadResult: Sendable {
    let tasks: [TaskSnapshot]
    let fetchedAt: Date
    let warning: TaskReadWarning?
    var localQuota: QuotaSnapshot?
    var quotaWarning: String?
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

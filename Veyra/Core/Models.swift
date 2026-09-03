import Foundation

struct AccountSnapshot: Equatable, Sendable {
    let identity: String
    let email: String?
    let plan: String?
    let authType: String

    init(json: JSONValue, accountID: String? = nil) {
        email = json["email"].string
        plan = json["planType"].string
        authType = json["type"].string ?? "unknown"
        identity = accountID ?? json["accountId"].string ?? "\(authType):\(email ?? "unknown"):\(plan ?? "")"
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
        case 10_080: "周"
        case 1_440: "24h"
        case .some(let minutes) where minutes > 0 && minutes % 60 == 0: "\(minutes / 60)h"
        case .some(let minutes) where minutes > 0: "\(minutes)分钟"
        default: isPrimary ? "主额度" : "次额度"
        }
    }
}

struct QuotaSnapshot: Equatable, Sendable {
    let windows: [QuotaWindow]
    let fetchedAt: Date
    let accountID: String?
    var menuWindow: QuotaWindow? {
        windows.first { $0.bucketID == "codex" && $0.isPrimary }
            ?? windows.first { $0.bucketID == "codex" } ?? windows.first
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
        return QuotaSnapshot(windows: windows, fetchedAt: date, accountID: value["accountId"].string)
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
    case notLoggedIn = "not_logged_in"
    case unsupportedAuthentication = "unsupported_authentication"
    case noQuotaWindows = "no_quota_windows"
    case unknown

    var message: String {
        switch self {
        case .missingExecutable: "未找到 Codex 可执行文件，请在设置中指定。"
        case .missingHome: "Codex 数据目录不存在，请检查设置。"
        case .launchFailed: "无法启动 Codex，请检查可执行文件和数据目录。"
        case .disconnected: "Codex 连接已断开，稍后将自动重试。"
        case .timeout: "连接 Codex 超时，稍后将自动重试。"
        case .protocolError: "Codex 返回了无法识别的数据，请检查版本兼容性。"
        case .rpcFailed: "额度读取失败，请检查 Codex 登录与网络连接后重试。"
        case .notLoggedIn: "尚未登录 Codex。请先在 Codex 桌面端或 CLI 中登录。"
        case .unsupportedAuthentication: "当前登录方式不提供 ChatGPT 订阅额度。"
        case .noQuotaWindows: "账号暂未返回可用额度窗口。"
        case .unknown: "额度读取遇到未知错误，稍后将自动重试。"
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
}

struct QuotaDisplayState: Sendable {
    var account: AccountSnapshot?
    var snapshot: QuotaSnapshot?
    var error: String?
    mutating func apply(_ result: QuotaRefresh) {
        if result.invalidatePrevious || (account != nil && result.account != nil && account?.identity != result.account?.identity) {
            snapshot = nil
            account = nil
        }
        if let newAccount = result.account { account = newAccount }
        if let newSnapshot = result.snapshot { snapshot = newSnapshot }
        error = result.error?.message
    }
}

struct TokenUsage: Equatable, Sendable {
    var input: Int64?
    var output: Int64?
    var cachedInput: Int64?
    var reasoningOutput: Int64?
    var total: Int64?

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
    let activity: TaskActivity
}

struct TaskReadResult: Sendable {
    let tasks: [TaskSnapshot]
    let fetchedAt: Date
    let warning: String?
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
        if seconds >= 86_400 { return "\(seconds / 86_400)天 \(seconds % 86_400 / 3_600)时" }
        if seconds >= 3_600 { return "\(seconds / 3_600)时 \(seconds % 3_600 / 60)分" }
        if seconds >= 60 { return "\(seconds / 60)分 \(seconds % 60)秒" }
        return "\(seconds)秒"
    }
}

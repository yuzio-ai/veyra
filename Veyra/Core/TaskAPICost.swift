import Foundation

/// Reference prices only. Never used for quota accounting or an actual bill.
enum TaskAPICostCatalog {
    static let checkedOn = "2026-10-31"
    static let currency = "USD"
    static let openAISource = "https://developers.openai.com/api/docs/pricing"

    struct Rate: Sendable {
        let input: Decimal
        let cached: Decimal?
        let output: Decimal

        init(_ input: String, _ cached: String?, _ output: String) {
            self.input = Decimal(string: input, locale: Locale(identifier: "en_US_POSIX"))!
            self.cached = cached.map { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX"))! }
            self.output = Decimal(string: output, locale: Locale(identifier: "en_US_POSIX"))!
        }

        func cost(_ tokens: TaskCostTokens) -> Decimal? {
            guard tokens.cached == 0 || cached != nil else { return nil }
            return (Decimal(tokens.input - tokens.cached) * input
                    + Decimal(tokens.cached) * (cached ?? 0) + Decimal(tokens.output) * output) / 1_000_000
        }
    }

    // Standard, short-context text prices per million tokens. Cache writes are
    // deliberately folded into ordinary input for this base-price comparison.
    static let openAI: [String: Rate] = [
        "gpt-6-astra": Rate("10", "1", "50"),
        "gpt-6.1-sol": Rate("2", "0.10", "10"),
        "gpt-6.1-terra": Rate("1", "0.05", "5"),
        "gpt-6-luna": Rate("0.10", "0.01", "0.50"),
        "gpt-6-sol": Rate("2", "0.20", "10"),
        "gpt-5.6-sol": Rate("4", "0.40", "20"),
        "gpt-5.6-terra": Rate("2", "0.20", "12"),
        "gpt-5.6-luna": Rate("0.20", "0.02", "1.20"),
        "gpt-5.5": Rate("5", "0.50", "30"),
        "gpt-5.5-pro": Rate("30", nil, "180"),
        "gpt-5.4": Rate("2.50", "0.25", "15"),
        "gpt-5.4-pro": Rate("30", nil, "180"),
        "gpt-5.4-mini": Rate("0.75", "0.075", "4.50"),
        "gpt-5.4-nano": Rate("0.20", "0.02", "1.25"),
        "gpt-5.3-codex": Rate("1.75", "0.175", "14"),
        "gpt-5.2": Rate("1.75", "0.175", "14"),
        "gpt-5.2-pro": Rate("21", nil, "168"),
        "gpt-5.1": Rate("1.25", "0.125", "10"),
        "gpt-5": Rate("1.25", "0.125", "10"),
        "gpt-5-mini": Rate("0.25", "0.025", "2"),
        "gpt-5-nano": Rate("0.05", "0.005", "0.40"),
        "gpt-5-pro": Rate("15", nil, "120"),
        "gpt-4.1": Rate("2", "0.50", "8"),
        "gpt-4.1-mini": Rate("0.40", "0.10", "1.60"),
        "gpt-4.1-nano": Rate("0.10", "0.025", "0.40"),
        "gpt-4o": Rate("2.50", "1.25", "10"),
        "gpt-4o-2024-05-13": Rate("5", nil, "15"),
        "gpt-4o-mini": Rate("0.15", "0.075", "0.60"),
        "o1": Rate("15", "7.50", "60"),
        "o1-pro": Rate("150", nil, "600"),
        "o3-pro": Rate("20", nil, "80"),
        "o3": Rate("2", "0.50", "8"),
        "o4-mini": Rate("1.10", "0.275", "4.40"),
        "o3-mini": Rate("1.10", "0.55", "4.40"),
        "gpt-4-turbo-2024-04-09": Rate("10", nil, "30"),
        "gpt-4-0613": Rate("30", nil, "60"),
        "gpt-3.5-turbo": Rate("0.50", nil, "1.50"),
        "gpt-3.5-turbo-0125": Rate("0.50", nil, "1.50")
    ]

    static func prices(model: String) -> Rate? { openAI[model] }

}

struct TaskCostTokens: Equatable, Sendable {
    let input: Int64
    let cached: Int64
    let output: Int64

    init?(usage: TokenUsage) {
        guard let input = usage.input, let cached = usage.cachedInput, let output = usage.output,
              input >= 0, cached >= 0, cached <= input, output >= 0,
              !usage.hasInconsistentBreakdown else { return nil }
        if let reasoning = usage.reasoningOutput, reasoning < 0 || reasoning > output { return nil }
        self.input = input; self.cached = cached; self.output = output
    }

    private init(input: Int64, cached: Int64, output: Int64) {
        self.input = input; self.cached = cached; self.output = output
    }

    static let zero = TaskCostTokens(input: 0, cached: 0, output: 0)

    func difference(from previous: Self) -> Self? {
        guard input >= previous.input, cached >= previous.cached, output >= previous.output,
              cached - previous.cached <= input - previous.input else { return nil }
        return Self(input: input - previous.input, cached: cached - previous.cached, output: output - previous.output)
    }
}

enum TaskAPICostIssue: Hashable, Sendable {
    case unknownModel(String), unknownCachePrice(String), missingModel, invalidUsage, missingUsage, historyUnreadable, counterReset, outOfDate

    var text: String {
        switch self {
        case .unknownModel(let model): L10n.text("No verified price for model: \(model)")
        case .unknownCachePrice(let model): L10n.text("No verified cache-read price for model: \(model)")
        case .missingModel: L10n.text("Some usage has no confirmed model.")
        case .invalidUsage: L10n.text("Some token counts are missing or inconsistent.")
        case .missingUsage: L10n.text("Token usage is unavailable.")
        case .historyUnreadable: L10n.text("Some session history could not be read.")
        case .counterReset: L10n.text("Token counters reset; earlier usage cannot be attributed.")
        case .outOfDate: L10n.text("Usage changed. Waiting for task refresh.")
        }
    }
}

struct TaskAPICostLine: Equatable, Sendable {
    let model: String
    var amountUSD: Decimal
}

struct TaskAPICostEstimate: Equatable, Sendable {
    var lines: [TaskAPICostLine] = []
    var issues: [TaskAPICostIssue] = []

    var total: TaskAPICostLine? {
        guard !lines.isEmpty else { return nil }
        return lines.reduce(TaskAPICostLine(model: "", amountUSD: 0)) {
            TaskAPICostLine(model: "", amountUSD: $0.amountUSD + $1.amountUSD)
        }
    }

    var isPartial: Bool { total != nil && !issues.isEmpty }

    mutating func note(_ issue: TaskAPICostIssue) {
        if !issues.contains(issue) { issues.append(issue) }
    }

    mutating func add(_ tokens: TaskCostTokens, model: String?) {
        guard let model, !model.isEmpty else { note(.missingModel); return }
        guard let rate = TaskAPICostCatalog.prices(model: model) else {
            note(.unknownModel(model)); return
        }
        guard let amount = rate.cost(tokens) else { note(.unknownCachePrice(model)); return }
        if let index = lines.firstIndex(where: { $0.model == model }) {
            lines[index].amountUSD += amount
        } else { lines.append(TaskAPICostLine(model: model, amountUSD: amount)) }
    }
}

enum TaskAPICostSource: Equatable, Sendable {
    case codex(URL)
    /// An already computed reference, also used by deterministic previews.
    case recorded(TaskAPICostEstimate)
}

enum TaskAPICostText {
    /// Compact display only. Historical cost arithmetic remains unchanged.
    static func summaryAmount(_ line: TaskAPICostLine?) -> String {
        guard let line else { return "—" }
        if line.amountUSD > 0 && line.amountUSD < Decimal(string: "0.01")! { return "< US$0.01" }
        return value(line.amountUSD, digits: 2)
    }

    static func amount(_ line: TaskAPICostLine?) -> String {
        guard let line else { return "—" }
        if line.amountUSD > 0 && line.amountUSD < Decimal(string: "0.001")! { return "< US$0.001" }
        return value(line.amountUSD)
    }

    private static func value(_ amount: Decimal, digits: Int = 3) -> String {
        if amount > 0 && amount < Decimal(string: "0.001")! { return "< US$0.001" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = digits; formatter.maximumFractionDigits = digits
        formatter.roundingMode = .halfUp
        let number = formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "—"
        return "≈ US$" + number
    }
}

import Foundation
import XCTest

final class TaskAPICostTests: XCTestCase {
    private func decimal(_ text: String) -> Decimal { Decimal(string: text)! }

    private func estimate(_ usage: TokenUsage, model: String = "gpt-6.1-sol") throws -> TaskAPICostEstimate {
        var result = TaskAPICostEstimate()
        result.add(try XCTUnwrap(TaskCostTokens(usage: usage)), model: model)
        return result
    }

    func testScreenshotUsesExactDecimalPricesAndDoesNotChargeReasoningTwice() throws {
        let usage = TokenUsage(input: 250_229, output: 1_404, cachedInput: 211_840, reasoningOutput: 420, total: 251_633)
        let result = try estimate(usage)
        XCTAssertEqual(result.total?.amountUSD, decimal("0.112002"))
        XCTAssertEqual(TaskAPICostText.amount(result.total), "≈ US$0.112")
        XCTAssertFalse(result.isPartial)
        XCTAssertEqual(TaskAPICostCatalog.currency, "USD")
        XCTAssertEqual(TaskAPICostCatalog.checkedOn, "2026-10-31")
        var withoutReasoning = usage; withoutReasoning.reasoningOutput = nil
        XCTAssertEqual(try estimate(withoutReasoning), result)
    }

    func testModelsHaveDifferentPricesAndMatchingIsExact() throws {
        let usage = TokenUsage(input: 1_000_000, output: 1_000_000, cachedInput: 0)
        XCTAssertEqual(try estimate(usage).total?.amountUSD, 12)
        XCTAssertEqual(try estimate(usage, model: "gpt-6.1-terra").total?.amountUSD, 6)
        XCTAssertEqual(try estimate(usage, model: "gpt-5.3-codex").total?.amountUSD, decimal("15.75"))
        for model in ["gpt-6.1-sol-custom", "GPT-6.1-Sol", "deepseek-flash", "unknown"] {
            let result = try estimate(usage, model: model)
            XCTAssertNil(result.total)
            XCTAssertEqual(result.issues, [.unknownModel(model)])
        }
    }




    func testMissingAndInvalidCountsNeverBecomeZero() {
        for usage in [TokenUsage(), TokenUsage(total: 100), TokenUsage(input: 1, output: 2),
                      TokenUsage(input: -1, output: 0, cachedInput: 0),
                      TokenUsage(input: 10, output: 2, cachedInput: 11),
                      TokenUsage(input: 10, output: 2, cachedInput: 1, reasoningOutput: 3),
                      TokenUsage(input: 10, output: 2, cachedInput: 1, total: 13)] {
            XCTAssertNil(TaskCostTokens(usage: usage))
        }
    }

    func testZeroSmallAndLargeValuesHaveUnambiguousUSDText() throws {
        let zero = try estimate(TokenUsage(input: 0, output: 0, cachedInput: 0))
        XCTAssertEqual(TaskAPICostText.amount(zero.total), "≈ US$0.000")
        XCTAssertEqual(TaskAPICostText.summaryAmount(zero.total), "≈ US$0.00")
        let tiny = try estimate(TokenUsage(input: 1, output: 0, cachedInput: 0))
        XCTAssertEqual(TaskAPICostText.amount(tiny.total), "< US$0.001")
        XCTAssertEqual(TaskAPICostText.summaryAmount(tiny.total), "< US$0.01")
        XCTAssertEqual(TaskAPICostText.summaryAmount(nil), "—")
        XCTAssertEqual(TaskAPICostText.amount(nil), "—")
        let large = try estimate(TokenUsage(input: Int64.max / 2, output: Int64.max / 2, cachedInput: 0))
        XCTAssertNotNil(large.total)
        XCTAssertFalse(TaskAPICostText.amount(large.total).contains("—"))
    }

    func testMissingCacheRateDoesNotAssumeCacheIsFree() throws {
        let unknownCache = try estimate(TokenUsage(input: 100, output: 10, cachedInput: 50), model: "gpt-5.5-pro")
        XCTAssertNil(unknownCache.total)
        XCTAssertEqual(unknownCache.issues, [.unknownCachePrice("gpt-5.5-pro")])
    }

    func testSummaryRoundsOnlySingleValuesAndPreservesDetailedCost() {
        let amount = Decimal(string: "6.799")!
        let line = TaskAPICostLine(model: "fixture", amountUSD: amount)
        XCTAssertEqual(TaskAPICostText.summaryAmount(line), "≈ US$6.80")
        XCTAssertEqual(TaskAPICostText.amount(line), "≈ US$6.799")
        let fraction = Decimal(string: "0.009")!
        XCTAssertEqual(TaskAPICostText.summaryAmount(TaskAPICostLine(model: "fixture", amountUSD: fraction)), "< US$0.01")

    }

    func testMixedKnownUnknownAndMissingModelsProducePartialEstimateInStableOrder() throws {
        let tokens = try XCTUnwrap(TaskCostTokens(usage: TokenUsage(input: 1_000_000, output: 0, cachedInput: 0)))
        var result = TaskAPICostEstimate()
        result.add(tokens, model: "gpt-6.1-sol")
        result.add(tokens, model: "unknown")
        result.add(tokens, model: nil)
        result.add(tokens, model: "gpt-6.1-terra")
        result.add(tokens, model: "gpt-6.1-sol")
        result.add(tokens, model: "unknown")
        XCTAssertEqual(result.lines.map(\.model), ["gpt-6.1-sol", "gpt-6.1-terra"])
        XCTAssertEqual(result.total?.amountUSD, 5)
        XCTAssertTrue(result.isPartial)
        XCTAssertEqual(result.issues, [.unknownModel("unknown"), .missingModel])
    }

    func testEveryCatalogPriceIsUsableWithoutCacheHits() throws {
        // Rate.init force-unwraps Decimal(string:); a typo in any entry would
        // crash on first use, so price every model at least once.
        let usage = TokenUsage(input: 1_000_000, output: 1_000_000, cachedInput: 0)
        let noCache = try XCTUnwrap(TaskCostTokens(usage: usage))
        XCTAssertFalse(TaskAPICostCatalog.openAI.isEmpty)
        for (model, rate) in TaskAPICostCatalog.openAI {
            XCTAssertGreaterThan(rate.input, 0, model)
            XCTAssertGreaterThan(rate.output, 0, model)
            if let cached = rate.cached { XCTAssertGreaterThanOrEqual(cached, 0, model) }
            var estimate = TaskAPICostEstimate()
            estimate.add(noCache, model: model)
            XCTAssertNotNil(estimate.total, model)
            XCTAssertTrue(estimate.issues.isEmpty, model)
        }

    }

    func testCostWarningsAreLocalized() {
        for language in ["en", "zh-Hans"] {
            L10n.$languageOverride.withValue(language) {
                let translated = TaskAPICostIssue.missingModel.text
                XCTAssertEqual(translated, language == "en" ? "Some usage has no confirmed model." : "部分用量没有可确认的模型归属。")
                XCTAssertTrue(TaskAPICostIssue.unknownModel("fixture").text.contains("fixture"))
            }
        }
    }
}

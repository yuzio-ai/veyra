import Foundation
import XCTest

final class TaskAPICostTests: XCTestCase {
    private func decimal(_ text: String) -> Decimal { Decimal(string: text)! }

    private func estimate(_ usage: TokenUsage, model: String = "gpt-6.1-sol") throws -> TaskAPICostEstimate {
        var result = TaskAPICostEstimate()
        result.add(try XCTUnwrap(TaskCostTokens(usage: usage)), model: model, backend: .codex)
        return result
    }

    func testScreenshotUsesExactDecimalPricesAndDoesNotChargeReasoningTwice() throws {
        let usage = TokenUsage(input: 250_229, output: 1_404, cachedInput: 211_840, reasoningOutput: 420, total: 251_633)
        let result = try estimate(usage)
        XCTAssertEqual(result.total?.lowerUSD, decimal("0.112002"))
        XCTAssertEqual(result.total?.upperUSD, decimal("0.112002"))
        XCTAssertEqual(TaskAPICostText.amount(result.total), "≈ US$0.112")
        XCTAssertFalse(result.isPartial)
        XCTAssertEqual(TaskAPICostCatalog.currency, "USD")
        XCTAssertEqual(TaskAPICostCatalog.checkedOn, "2026-10-31")
        var withoutReasoning = usage; withoutReasoning.reasoningOutput = nil
        XCTAssertEqual(try estimate(withoutReasoning), result)
    }

    func testModelsHaveDifferentPricesAndMatchingIsExact() throws {
        let usage = TokenUsage(input: 1_000_000, output: 1_000_000, cachedInput: 0)
        XCTAssertEqual(try estimate(usage).total?.lowerUSD, 12)
        XCTAssertEqual(try estimate(usage, model: "gpt-6.1-terra").total?.lowerUSD, 6)
        XCTAssertEqual(try estimate(usage, model: "gpt-5.3-codex").total?.lowerUSD, decimal("15.75"))
        for model in ["gpt-6.1-sol-custom", "GPT-6.1-Sol", "deepseek-flash", "unknown"] {
            let result = try estimate(usage, model: model)
            XCTAssertNil(result.total)
            XCTAssertEqual(result.issues, [.unknownModel(model)])
        }
    }

    func testDeepSeekPeakValleyAndOnlyDocumentedAliases() {
        let usage = TokenUsage(input: 2_000_000, output: 1_000_000, cachedInput: 1_000_000)
        let flash = TaskAPICostEstimate.dsh(usage: usage, model: "deepseek-flash")
        XCTAssertEqual(flash.total?.lowerUSD, decimal("0.753"))
        XCTAssertEqual(flash.total?.upperUSD, decimal("1.506"))
        XCTAssertEqual(TaskAPICostText.amount(flash.total), "≈ US$0.753–1.506")
        XCTAssertTrue(flash.usesLastModel)
        for alias in ["deepseek-v4-flash", "deepseek-v4-flash-vision-exp"] {
            let result = TaskAPICostEstimate.dsh(usage: usage, model: alias)
            XCTAssertEqual(result.total?.lowerUSD, flash.total?.lowerUSD)
            XCTAssertEqual(result.total?.upperUSD, flash.total?.upperUSD)
        }
        let pro = TaskAPICostEstimate.dsh(usage: usage, model: "deepseek-v4-pro")
        XCTAssertEqual(pro.total?.lowerUSD, decimal("2.662"))
        XCTAssertEqual(pro.total?.upperUSD, decimal("5.324"))
        for model in ["kimi-k3", "gpt-6.1-sol", "deepseek-chat", "deepseek-flash-custom"] {
            XCTAssertNil(TaskAPICostEstimate.dsh(usage: usage, model: model).total)
        }
    }

    func testDshCacheWriteBelongsToOrdinaryInputExactlyOnce() throws {
        let data = Data(#"{"record":{"rows":{"tokenUsage":{"val":{"totals":{"uncachedInputTokens":100,"cacheReadTokens":40,"cacheWriteTokens":5,"outputTokens":10}}},"modelSelection":{"val":{"lastUsed":{"model":"deepseek-flash"}}}}}}"#.utf8)
        let metadata = try XCTUnwrap(DshSessionMetadata.parse(id: "fixture", data: data))
        let result = TaskAPICostEstimate.dsh(usage: metadata.tokens, model: metadata.model)
        XCTAssertEqual(metadata.tokens.input, 145)
        XCTAssertTrue(metadata.hasCompleteAPICostUsage)
        XCTAssertEqual(result.total?.lowerUSD, decimal("0.00002187"))
        XCTAssertEqual(result.total?.upperUSD, decimal("0.00004374"))
    }

    func testDshIncompleteSourceBucketsAreNotSilentlyTreatedAsZero() throws {
        for counts in [#""cacheReadTokens":40,"cacheWriteTokens":0,"outputTokens":10"#,
                       #""uncachedInputTokens":100.5,"cacheReadTokens":40,"cacheWriteTokens":0,"outputTokens":10"#] {
            let data = Data((#"{"record":{"rows":{"tokenUsage":{"val":{"totals":{\#(counts)}}}}}}"#).utf8)
            let metadata = try XCTUnwrap(DshSessionMetadata.parse(id: "fixture", data: data))
            XCTAssertFalse(metadata.hasCompleteAPICostUsage)
        }
    }

    func testMissingAndInvalidCountsNeverBecomeZero() {
        for usage in [TokenUsage(), TokenUsage(total: 100), TokenUsage(input: 1, output: 2),
                      TokenUsage(input: -1, output: 0, cachedInput: 0),
                      TokenUsage(input: 10, output: 2, cachedInput: 11),
                      TokenUsage(input: 10, output: 2, cachedInput: 1, reasoningOutput: 3),
                      TokenUsage(input: 10, output: 2, cachedInput: 1, total: 13)] {
            XCTAssertNil(TaskCostTokens(usage: usage))
            let result = TaskAPICostEstimate.dsh(usage: usage, model: "deepseek-flash")
            XCTAssertNil(result.total)
            XCTAssertEqual(result.issues, [.invalidUsage])
        }
    }

    func testZeroSmallRangeAndLargeValuesHaveUnambiguousUSDText() throws {
        let zero = try estimate(TokenUsage(input: 0, output: 0, cachedInput: 0))
        XCTAssertEqual(TaskAPICostText.amount(zero.total), "≈ US$0.000")
        XCTAssertEqual(TaskAPICostText.summaryAmount(zero.total), "≈ US$0.00")
        let tiny = try estimate(TokenUsage(input: 1, output: 0, cachedInput: 0))
        XCTAssertEqual(TaskAPICostText.amount(tiny.total), "< US$0.001")
        XCTAssertEqual(TaskAPICostText.summaryAmount(tiny.total), "< US$0.01")
        XCTAssertEqual(TaskAPICostText.summaryAmount(nil), "—")
        XCTAssertEqual(TaskAPICostText.amount(nil), "—")
        let range = TaskAPICostEstimate.dsh(usage: TokenUsage(input: 1, output: 1, cachedInput: 0), model: "deepseek-flash")
        XCTAssertEqual(TaskAPICostText.amount(range.total), "< US$0.001")
        XCTAssertEqual(TaskAPICostText.summaryAmount(range.total), TaskAPICostText.amount(range.total))
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
        let line = TaskAPICostLine(model: "fixture", lowerUSD: amount, upperUSD: amount)
        XCTAssertEqual(TaskAPICostText.summaryAmount(line), "≈ US$6.80")
        XCTAssertEqual(TaskAPICostText.amount(line), "≈ US$6.799")
        let fraction = Decimal(string: "0.009")!
        XCTAssertEqual(TaskAPICostText.summaryAmount(TaskAPICostLine(model: "fixture", lowerUSD: fraction, upperUSD: fraction)), "< US$0.01")
        let range = TaskAPICostLine(model: "fixture", lowerUSD: Decimal(string: "0.005")!, upperUSD: Decimal(string: "0.015")!)
        XCTAssertEqual(TaskAPICostText.summaryAmount(range), TaskAPICostText.amount(range))
    }

    func testMixedKnownUnknownAndMissingModelsProducePartialEstimateInStableOrder() throws {
        let tokens = try XCTUnwrap(TaskCostTokens(usage: TokenUsage(input: 1_000_000, output: 0, cachedInput: 0)))
        var result = TaskAPICostEstimate()
        result.add(tokens, model: "gpt-6.1-sol", backend: .codex)
        result.add(tokens, model: "unknown", backend: .codex)
        result.add(tokens, model: nil, backend: .codex)
        result.add(tokens, model: "gpt-6.1-terra", backend: .codex)
        result.add(tokens, model: "gpt-6.1-sol", backend: .codex)
        result.add(tokens, model: "unknown", backend: .codex)
        XCTAssertEqual(result.lines.map(\.model), ["gpt-6.1-sol", "gpt-6.1-terra"])
        XCTAssertEqual(result.total?.lowerUSD, 5)
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
            estimate.add(noCache, model: model, backend: .codex)
            XCTAssertNotNil(estimate.total, model)
            XCTAssertTrue(estimate.issues.isEmpty, model)
        }
        for model in ["deepseek-flash", "deepseek-v4-flash", "deepseek-v4-flash-vision-exp", "deepseek-v4-pro"] {
            let estimate = TaskAPICostEstimate.dsh(usage: usage, model: model)
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

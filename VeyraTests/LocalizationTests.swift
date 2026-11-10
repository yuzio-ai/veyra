import Foundation
import XCTest

final class LocalizationTests: XCTestCase {
    func testBothLanguagesAreBundledAndTranslationsHaveMatchingArguments() throws {
        let bundle = L10n.resourceBundle
        XCTAssertTrue(bundle.localizations.contains("en"))
        XCTAssertTrue(bundle.localizations.contains("zh-Hans"))
        let english = try strings("en"), chinese = try strings("zh-Hans")
        // Plural entries compile into .stringsdict instead of .strings.
        XCTAssertEqual(Set(english.keys).union(try pluralKeys("en")),
                       Set(chinese.keys).union(try pluralKeys("zh-Hans")))
        let arguments = try NSRegularExpression(pattern: "%(@|lld)")
        func placeholders(_ text: String) -> [String] {
            arguments.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
                String(text[Range($0.range, in: text)!])
            }.sorted()
        }
        for (key, translation) in chinese {
            XCTAssertFalse(translation.isEmpty, key)
            XCTAssertEqual(placeholders(key), placeholders(translation), key)
        }
        XCTAssertEqual(english["Settings"], "Settings")
        XCTAssertEqual(chinese["Settings"], "设置")
    }

    func testSystemLanguageNegotiation() {
        let languages = L10n.resourceBundle.localizations
        XCTAssertEqual(Bundle.preferredLocalizations(from: languages, forPreferences: ["en-US"]).first, "en")
        XCTAssertEqual(Bundle.preferredLocalizations(from: languages, forPreferences: ["zh-CN"]).first, "zh-Hans")
        XCTAssertEqual(Bundle.preferredLocalizations(from: languages, forPreferences: ["fr-FR", "zh-Hans"]).first, "zh-Hans")
    }

    func testQuotaTitlesAndCompactDurationsInBothLanguages() {
        for language in ["en", "zh-Hans"] {
            L10n.$languageOverride.withValue(language) {
                let chinese = language == "zh-Hans"
                XCTAssertEqual(L10n.text("Codex quota"), chinese ? "Codex 额度" : "Codex quota")
                for (minutes, english, translated) in [
                    (10_080, "Weekly quota", "每周额度"), (1_440, "24h quota", "24h额度"),
                    (300, "5h quota", "5h额度"), (15, "15min quota", "15分钟额度")
                ] {
                    XCTAssertEqual(window(Int64(minutes)).durationTitle, chinese ? translated : english)
                }
                XCTAssertEqual(window(nil).durationTitle, chinese ? "主额度" : "Primary quota")
                XCTAssertEqual(window(0, primary: false).durationTitle, chinese ? "次额度" : "Secondary quota")
                XCTAssertEqual(window(10_080).durationLabel, chinese ? "周" : "Week")
                XCTAssertEqual(window(15).durationLabel, chinese ? "15分钟" : "15min")
                let start = Date(timeIntervalSince1970: 0)
                for (seconds, english, translated) in [
                    (0, "0s", "0秒"), (59, "59s", "59秒"), (61, "1m 1s", "1分 1秒"),
                    (3_660, "1h 1m", "1时 1分"), (90_000, "1d 1h", "1天 1时")
                ] {
                    XCTAssertEqual(DisplayFormat.duration(since: start, now: start.addingTimeInterval(Double(seconds))),
                                   chinese ? translated : english)
                }
            }
        }
    }

    func testResetCountPluralizationAndExpiredState() {
        let now = Date(timeIntervalSince1970: 200)
        for language in ["en", "zh-Hans"] {
            L10n.$languageOverride.withValue(language) {
                for count: Int64 in [0, 1, 2, 21] {
                    let snapshot = ResetCreditsSnapshot(availableCount: count, credits: [], fetchedAt: now, hasIncompleteDetails: false)
                    let english = count == 1 ? "1 reset" : "\(count) resets"
                    XCTAssertEqual(snapshot.totalLabel(at: now), language == "en" ? english : "\(count) 次")
                }
                let expired = ResetCreditsSnapshot(availableCount: 2, credits: [.init(expiresAt: now)],
                                                   fetchedAt: now, hasIncompleteDetails: false)
                XCTAssertEqual(expired.totalLabel(at: now), language == "en" ? "Sync needed" : "待校准")
            }
        }
    }

    @MainActor
    func testWarningsPreserveConfirmedMenuCountInEitherLanguage() {
        for language in ["en", "zh-Hans"] {
            L10n.$languageOverride.withValue(language) {
                let store = MonitorStore()
                store.isPreview = true
                store.tasksUpdatedAt = .now
                let base = language == "en" ? "Quota — · Running 0" : "额度 — · 运行 0"
                store.taskWarning = .processUnverified
                XCTAssertTrue(store.menuLabel.hasPrefix(base))
                XCTAssertEqual(store.menuTaskCount, "0")
                store.taskWarning = nil
                XCTAssertEqual(store.menuLabel, base)
                store.taskError = "fixture error"
                XCTAssertEqual(store.menuTaskCount, "0")
                XCTAssertTrue(store.menuLabel.contains(L10n.text("Some task data is unavailable. Running count may be incomplete.")))
                XCTAssertEqual(store.taskSourceWarningSummary, language == "en"
                    ? "Some task data is unavailable. Running count may be incomplete."
                    : "部分任务数据暂不可用，运行数量可能不完整。")
                store.taskError = nil
                store.previewCodexServicesAvailable = false
                XCTAssertEqual(store.menuLabel, language == "en" ? "Running 0" : "运行 0")
                store.taskError = "fixture warning"
                XCTAssertEqual(store.menuTaskCount, "0")
            }
        }
    }

    func testTaskContentRemainsVerbatimAndFallbackTitlesAreLocalized() {
        for language in ["en", "zh-Hans"] {
            L10n.$languageOverride.withValue(language) {
                XCTAssertEqual(TaskText.title("原始任务 · Original", id: "123456789", parentID: nil, agentPath: nil, nickname: nil),
                               "原始任务 · Original")
                XCTAssertEqual(TaskText.title(nil, id: "123456789", parentID: "parent", agentPath: nil, nickname: nil),
                               language == "en" ? "Subtask · 12345678" : "子任务 · 12345678")
                XCTAssertEqual(QuotaFailure.timeout.message, language == "en"
                    ? "Connection to Codex timed out. Try syncing quota again later."
                    : "连接 Codex 超时，请稍后手动校准。")
            }
        }
    }

    func testTaskDetailLabelsAndExactAccessibilityInBothLanguages() {
        for language in ["en", "zh-Hans"] {
            L10n.$languageOverride.withValue(language) {
                let chinese = language == "zh-Hans"
                XCTAssertEqual(TaskText.subagentBadge(nickname: " Schrodinger "), "Schrodinger")
                XCTAssertEqual(TaskText.subagentDetail(nickname: " Schrodinger "),
                               chinese ? "子代理：Schrodinger" : "Subagent: Schrodinger")
                XCTAssertEqual(TaskText.subagentBadge(nickname: " "), chinese ? "子代理" : "Subagent")
                XCTAssertEqual(TaskText.subagentDetail(nickname: " "), chinese ? "子代理" : "Subagent")
                XCTAssertEqual(TaskTokenText.count(nil), "—")
                XCTAssertEqual(TaskTokenText.count(-1), "—")
                XCTAssertEqual(TaskTokenText.count(1_501_590), "1,501,590")
                let usage = TokenUsage(input: 1_493_699, output: 7_891, cachedInput: 1_397_632,
                                       reasoningOutput: 546, total: 1_501_590)
                XCTAssertEqual(TaskTokenText.totalHelp(usage), chinese ? "累计 1,501,590 tokens" : "1,501,590 tokens total")
                XCTAssertEqual(TaskTokenText.outputAccessibility(usage),
                               chinese ? "输出 7,891，其中推理 546" : "Output 7,891, including reasoning 546")
                XCTAssertEqual(L10n.text("(\(TaskTokenText.count(546)))"), chinese ? "（546）" : "(546)")
                XCTAssertTrue(TaskTokenText.outputAccessibility(TokenUsage(output: 7_891)).contains("—"))
                let inconsistent = TokenUsage(input: 100, output: 20, cachedInput: 80, total: 121)
                XCTAssertTrue(TaskTokenText.totalHelp(inconsistent).contains(chinese
                    ? "来源总量与明细合计不一致。" : "The source total differs from the sum of the details."))
                XCTAssertFalse(TaskTokenText.totalHelp(usage).contains("\n"))
                XCTAssertEqual(TaskTokenText.cacheHit(usage), chinese ? "缓存命中 93.6%" : "Cache hit 93.6%")
                XCTAssertEqual(TaskTokenText.cacheHit(TokenUsage()), chinese ? "缓存命中 —" : "Cache hit —")
                XCTAssertEqual(TaskTokenText.cacheHit(TokenUsage(input: 0, cachedInput: 0)),
                               chinese ? "缓存命中 —" : "Cache hit —")
                XCTAssertEqual(TaskSessionText.duration(1_300), chinese ? "1.3秒" : "1.3 seconds")
                XCTAssertEqual(TaskSessionText.duration(0), chinese ? "0.0秒" : "0.0 seconds")
                XCTAssertEqual(TaskSessionText.duration(61_000), chinese ? "1分 1秒" : "1m 1s")
                XCTAssertEqual(TaskSessionText.duration(nil), "—")
                XCTAssertEqual(TaskSessionText.duration(.infinity), "—")
                XCTAssertEqual(L10n.text("Context used"), chinese ? "上下文已用" : "Context used")
                XCTAssertEqual(L10n.text("Session statistics"), chinese ? "会话统计" : "Session statistics")
                XCTAssertEqual(L10n.text("Updating…"), chinese ? "更新中…" : "Updating…")
                XCTAssertEqual(L10n.text("Updating. Showing the previous recorded result."),
                               chinese ? "正在更新。当前显示上次记录的结果。" : "Updating. Showing the previous recorded result.")
                let samples: Int64 = 2
                XCTAssertEqual(L10n.text("\(samples) completed-turn samples"),
                               chinese ? "2 个已完成轮次样本" : "2 completed-turn samples")
                let oneSample: Int64 = 1
                XCTAssertEqual(L10n.text("\(oneSample) completed-turn samples"),
                               chinese ? "1 个已完成轮次样本" : "1 completed-turn sample")
                XCTAssertEqual(TaskSessionText.basedOn(11), chinese ? "基于11轮" : "Based on 11 turns")
                XCTAssertEqual(TaskSessionText.basedOn(1), chinese ? "基于1轮" : "Based on 1 turn")
                XCTAssertEqual(TaskSource.desktop.label, "Codex")
                XCTAssertEqual(TaskSource.cli.label, "Codex CLI")
                XCTAssertEqual(TaskOrigin.desktop.detail, chinese
                    ? "会话记录的来源：Codex Desktop。当前客户端可能不同。"
                    : "Recorded source: Codex Desktop. The current client may differ.")
                XCTAssertEqual(TaskOrigin.exec.detail, chinese
                    ? "会话记录的来源：Codex CLI（非交互式）。当前客户端可能不同。"
                    : "Recorded source: Codex CLI (non-interactive). The current client may differ.")
                XCTAssertEqual(L10n.text("API cost (reference)"), chinese ? "API 费用（参考）" : "API cost (reference)")
                XCTAssertEqual(L10n.text("Tool call time (cumulative)"), chinese ? "工具调用用时（累计）" : "Tool call time (cumulative)")
                XCTAssertEqual(L10n.text("First token latency (average)"), chinese ? "首 Token 延时（平均）" : "First token latency (average)")
            }
        }
    }

    private func window(_ minutes: Int64?, primary: Bool = true) -> QuotaWindow {
        QuotaWindow(id: "fixture", bucketID: "codex", bucketName: "Codex", isPrimary: primary,
                    usedPercent: 20, durationMinutes: minutes, resetsAt: nil)
    }

    private func strings(_ language: String) throws -> [String: String] {
        let url = try XCTUnwrap(L10n.resourceBundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
    }

    private func pluralKeys(_ language: String) throws -> Set<String> {
        guard let url = L10n.resourceBundle.url(forResource: "Localizable", withExtension: "stringsdict",
                                               subdirectory: nil, localization: language) else { return [] }
        let entries = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        return Set(entries.keys)
    }
}

import Foundation
import XCTest

final class LocalizationTests: XCTestCase {
    func testBothLanguagesAreBundledAndTranslationsHaveMatchingArguments() throws {
        let bundle = L10n.resourceBundle
        XCTAssertTrue(bundle.localizations.contains("en"))
        XCTAssertTrue(bundle.localizations.contains("zh-Hans"))
        let english = try strings("en"), chinese = try strings("zh-Hans")
        // English plural entries compile into .stringsdict instead of .strings.
        XCTAssertEqual(Set(english.keys).union(["%lld resets"]), Set(chinese.keys))
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
    func testWarningTypeControlsMenuCountInEitherLanguage() {
        for language in ["en", "zh-Hans"] {
            L10n.$languageOverride.withValue(language) {
                let store = MonitorStore()
                store.tasksUpdatedAt = .now
                store.taskWarning = .processUnverified
                XCTAssertEqual(store.menuLabel, language == "en" ? "Quota — · Running —" : "额度 — · 运行 —")
                store.taskWarning = .historyUnavailable
                XCTAssertEqual(store.menuLabel, language == "en" ? "Quota — · Running 0" : "额度 — · 运行 0")
                store.taskWarning = .sessionUnreadable
                XCTAssertTrue(store.menuLabel.hasSuffix("0"))
                store.taskWarning = nil
                store.taskError = "fixture error"
                XCTAssertTrue(store.menuLabel.hasSuffix("—"))
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

    private func window(_ minutes: Int64?, primary: Bool = true) -> QuotaWindow {
        QuotaWindow(id: "fixture", bucketID: "codex", bucketName: "Codex", isPrimary: primary,
                    usedPercent: 20, durationMinutes: minutes, resetsAt: nil)
    }

    private func strings(_ language: String) throws -> [String: String] {
        let url = try XCTUnwrap(L10n.resourceBundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
    }
}

import XCTest
import Foundation

final class CodexModelConfigTests: XCTestCase {
    private func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testTopLevelModelAndProviderAreParsed() {
        let config = CodexModelConfig.parse("""
            model = "kimi-k3"
            model_provider = "moonshot"

            [model_providers.moonshot]
            name = "Moonshot"
            base_url = "https://api.example.invalid/v1"
            """)
        XCTAssertEqual(config.model, "kimi-k3")
        XCTAssertEqual(config.provider, "moonshot")
        XCTAssertTrue(config.usesCustomProvider)
        XCTAssertEqual(config.customProvider, "moonshot")
    }

    func testDefaultAndMissingProvidersAreNotCustom() {
        for text in ["model_provider = \"openai\"", "model = \"example-coding-model\"", "", "model_provider = \"\""] {
            let config = CodexModelConfig.parse(text)
            XCTAssertFalse(config.usesCustomProvider, text)
            XCTAssertNil(config.customProvider, text)
        }
    }

    func testOpenAIBaseURLOverridesAreCustomWithImplicitOrExplicitProvider() {
        for selector in ["", "model_provider = \"openai\"\n"] {
            for url in ["https://gateway.example.invalid/v1", ""] {
                let config = CodexModelConfig.parse(selector + "openai_base_url = '\(url)'\n")
                XCTAssertTrue(config.usesCustomProvider)
                XCTAssertEqual(config.customProvider, "openai")
                XCTAssertEqual(config.openAIBaseURL, url)
            }
        }
    }

    func testCommentedAndProfileScopedOpenAIBaseURLsDoNotOverrideGlobalRoute() {
        for text in ["# openai_base_url = 'https://gateway.example.invalid/v1'",
                     "[profiles.gateway]\nopenai_base_url = 'https://gateway.example.invalid/v1'"] {
            let config = CodexModelConfig.parse(text)
            XCTAssertNil(config.openAIBaseURL)
            XCTAssertFalse(config.usesCustomProvider)
        }
    }

    func testSectionKeysAndCommentsNeverMarkCustom() {
        let config = CodexModelConfig.parse("""
            # model_provider = "commented-out"
            model = "example-coding-model" # trailing comment
            [profiles.work]
            model_provider = "moonshot"
            model = "kimi-k3"
            """)
        XCTAssertEqual(config.model, "example-coding-model")
        XCTAssertNil(config.provider)
        XCTAssertFalse(config.usesCustomProvider)
    }

    func testLegacyProfileDoesNotOverrideGlobalModelAndProvider() {
        let config = CodexModelConfig.parse("""
            model = "example-coding-model"
            profile = "work"

            [profiles.work]
            model = "kimi-k3"
            model_provider = "moonshot"

            [profiles.play]
            model_provider = "other"
            """)
        XCTAssertEqual(config.model, "example-coding-model")
        XCTAssertNil(config.provider)
        XCTAssertFalse(config.usesCustomProvider)
        XCTAssertNil(config.customProvider)
    }

    func testProfilePartialOverrideKeepsTopLevelProvider() {
        let config = CodexModelConfig.parse("""
            model_provider = "openai"
            profile = "fast"

            [profiles.fast]
            model = "example-fast-model"
            """)
        XCTAssertNil(config.model)
        XCTAssertEqual(config.provider, "openai")
        XCTAssertFalse(config.usesCustomProvider)
    }

    func testMissingProfileTableKeepsTopLevelSelection() {
        let config = CodexModelConfig.parse("""
            profile = "missing"
            model_provider = "openai"
            """)
        XCTAssertEqual(config.provider, "openai")
        XCTAssertFalse(config.usesCustomProvider)
    }

    func testQuotedLegacyProfileIsNotAGlobalProvider() {
        let config = CodexModelConfig.parse("""
            profile = "my profile"

            [profiles."my profile"]
            model_provider = "moonshot"
            """)
        XCTAssertNil(config.provider)
        XCTAssertFalse(config.usesCustomProvider)
    }

    func testQuotedValuesKeepHashesAndSingleQuotesWork() {
        XCTAssertEqual(CodexModelConfig.parse("model_provider = \"mo#on\"").provider, "mo#on")
        XCTAssertEqual(CodexModelConfig.parse("model_provider = 'moonshot'").provider, "moonshot")
        XCTAssertNil(CodexModelConfig.parse("model_provider = moonshot").provider)
        XCTAssertNil(CodexModelConfig.parse("model_provider = \"unterminated").provider)
    }

    func testLoadReadsConfigTomlFromHome() throws {
        let home = try temp()
        XCTAssertNil(CodexModelConfig.load(home: home))
        try "model_provider = \"moonshot\"\nmodel = \"kimi-k3\"\n".write(
            to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let config = CodexModelConfig.load(home: home)
        XCTAssertEqual(config?.provider, "moonshot")
        XCTAssertEqual(config?.model, "kimi-k3")
    }
}

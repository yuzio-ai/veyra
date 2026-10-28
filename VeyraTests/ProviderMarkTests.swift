import XCTest

final class ProviderMarkTests: XCTestCase {
    func testEveryPresetResolvesToItsBundledMark() {
        let expected: [String: ProviderMark] = [
            "DeepSeek": .deepSeek,
            "Kimi": .kimi,
            "GLM": .glm,
            "MiniMax": .miniMax,
            "MiMo": .mimo
        ]
        XCTAssertEqual(Set(expected.keys), Set(ProviderPreset.all.map(\.name)))
        for preset in ProviderPreset.all {
            XCTAssertEqual(ProviderMark.resolve(providerName: preset.name), expected[preset.name], preset.name)
        }
    }

    func testAliasesIgnoreCaseSpacingAndPunctuation() {
        let cases: [(String, ProviderMark)] = [
            ("DeepSeek", .deepSeek),
            ("deep seek", .deepSeek),
            ("Moonshot AI", .kimi),
            ("Kimi", .kimi),
            ("Z.ai", .glm),
            ("Zhipu AI", .glm),
            ("ChatGLM", .glm),
            ("MiniMax AI", .miniMax),
            ("Xiaomi MiMo", .mimo),
            ("MiMo", .mimo)
        ]
        for (name, mark) in cases {
            XCTAssertEqual(ProviderMark.resolve(providerName: name), mark, name)
        }
    }

    func testUnknownProviderKeepsTheInitialFallback() {
        XCTAssertNil(ProviderMark.resolve(providerName: "Local gateway"))
        XCTAssertNil(ProviderMark.resolve(providerName: ""))
    }

    func testOfficialIdentityUsesTheOpenAIMark() {
        XCTAssertEqual(ProviderMark.resolve(CodexProviderIdentity(name: "OpenAI", isOfficial: true)), .openAI)
        // A custom provider that merely borrows the name does not claim the official mark.
        XCTAssertNil(ProviderMark.resolve(CodexProviderIdentity(name: "OpenAI")))
    }

    func testAssetNamesAndTemplateFlags() {
        XCTAssertEqual(ProviderMark.deepSeek.assetName, "DeepSeekProvider")
        XCTAssertEqual(ProviderMark.mimo.assetName, "MiMoProvider")
        XCTAssertFalse(ProviderMark.deepSeek.isTemplate)
        XCTAssertFalse(ProviderMark.miniMax.isTemplate)
        XCTAssertFalse(ProviderMark.mimo.isTemplate)
        XCTAssertTrue(ProviderMark.kimi.isTemplate)
        XCTAssertTrue(ProviderMark.glm.isTemplate)
        XCTAssertTrue(ProviderMark.openAI.isTemplate)
    }
}

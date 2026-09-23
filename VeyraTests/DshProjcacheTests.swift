import XCTest
import Foundation

final class DshProjcacheTests: XCTestCase {
    private func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Minimal projcache document; rows can be replaced or removed per test.
    private func document(rows: [String: String] = [:], removing: [String] = [], version: Int = 7,
                          createdAt: Double? = 1_789_331_174_483) -> String {
        var all: [String: String] = [
            "title": #"{"ver":1,"seq":63,"val":"Review the quota reader"}"#,
            "subagent": #"{"ver":2,"seq":63,"val":{}}"#,
            "turnBoundary": #"{"ver":2,"seq":63,"val":{"openTurnStartSeq":174}}"#,
            "tokenUsage": #"{"ver":2,"seq":63,"val":{"totals":{"uncachedInputTokens":41245,"outputTokens":1411,"cacheReadTokens":65771,"cacheWriteTokens":120}}}"#,
            "modelSelection": #"{"ver":2,"seq":63,"val":{"lastUsed":{"provider":"moonshotai-cn","model":"kimi-k3","reasoningEffort":"max"},"pending":null}}"#,
            "sessionListMetadata": #"{"ver":1,"seq":63,"val":{"blank":false,"lastPromptAt":1789331174540}}"#,
        ]
        for key in removing { all.removeValue(forKey: key) }
        for (key, value) in rows { all[key] = value }
        let body = all.map { #""\#($0)":\#($1)"# }.joined(separator: ",")
        let identity = createdAt.map { #"{"formatVersion":3,"createdAt":\#(Int($0)),"cwd":"/tmp/work"}"# } ?? #"{"formatVersion":3}"#
        return #"{"version":\#(version),"record":{"identity":\#(identity),"rows":{\#(body)}}}"#
    }

    func testParsesFullRecord() {
        let meta = DshSessionMetadata.parse(id: "session-abc", data: Data(document().utf8))
        XCTAssertEqual(meta?.id, "session-abc")
        XCTAssertEqual(meta?.title, "Review the quota reader")
        XCTAssertEqual(meta?.turnOpen, true)
        XCTAssertEqual(meta?.model, "kimi-k3")
        XCTAssertEqual(meta?.formatVersion, 7)
        XCTAssertEqual(meta?.createdAt, Date(timeIntervalSince1970: 1_789_331_174.483))
        XCTAssertEqual(meta?.lastPromptAt, Date(timeIntervalSince1970: 1_789_331_174.540))
        XCTAssertEqual(meta?.tokens.input, 41245 + 65771 + 120)
        XCTAssertEqual(meta?.tokens.cachedInput, 65771)
        XCTAssertEqual(meta?.tokens.output, 1411)
        XCTAssertEqual(meta?.tokens.total, 41245 + 65771 + 120 + 1411)
        XCTAssertNil(meta?.subagentLabel)
        XCTAssertEqual(meta?.displayTitle, "Review the quota reader")
    }

    func testTurnBoundaryTriState() {
        let open = DshSessionMetadata.parse(id: "a", data: Data(document().utf8))
        XCTAssertEqual(open?.turnOpen, true)
        let closed = DshSessionMetadata.parse(id: "a", data: Data(document(rows: [
            "turnBoundary": #"{"ver":2,"seq":63,"val":{"openTurnStartSeq":null,"lastTurn":1}}"#]).utf8))
        XCTAssertEqual(closed?.turnOpen, false)
        let nullVal = DshSessionMetadata.parse(id: "a", data: Data(document(rows: [
            "turnBoundary": #"{"ver":2,"seq":63,"val":null}"#]).utf8))
        XCTAssertNil(nullVal?.turnOpen ?? nil)
        // Row absent entirely: also unknown, not finished.
        let absent = DshSessionMetadata.parse(id: "a", data: Data(document(removing: ["turnBoundary"]).utf8))
        XCTAssertNil(absent?.turnOpen ?? nil)
    }

    func testTitleFallsBackToSubagentLabelThenUntitled() {
        let subagent = DshSessionMetadata.parse(id: "a", data: Data(document(rows: [
            "title": #"{"ver":1,"seq":63,"val":null}"#,
            "subagent": #"{"ver":2,"seq":63,"val":{"identity":{"mode":"one-shot","label":"Inspect the layout tree","seq":5}}}"#]).utf8))
        XCTAssertEqual(subagent?.displayTitle, "Inspect the layout tree")
        let blank = DshSessionMetadata.parse(id: "a", data: Data(document(rows: [
            "title": #"{"ver":1,"seq":63,"val":"  "}"#]).utf8))
        XCTAssertEqual(blank?.displayTitle, L10n.text("Untitled task"))
    }

    func testRejectsNonObjectAndKeepsParsingUnknownVersions() {
        XCTAssertNil(DshSessionMetadata.parse(id: "a", data: Data("not json".utf8)))
        XCTAssertNil(DshSessionMetadata.parse(id: "a", data: Data(#"[1,2,3]"#.utf8)))
        let future = DshSessionMetadata.parse(id: "a", data: Data(document(version: 99).utf8))
        XCTAssertEqual(future?.formatVersion, 99)
        XCTAssertEqual(future?.turnOpen, true)
    }

    func testMissingTotalsLeaveTokenFieldsNil() {
        let meta = DshSessionMetadata.parse(id: "a", data: Data(document(rows: [
            "tokenUsage": #"{"ver":2,"seq":63,"val":{}}"#]).utf8))
        XCTAssertNil(meta?.tokens.input)
        XCTAssertNil(meta?.tokens.output)
        XCTAssertNil(meta?.tokens.cachedInput)
        XCTAssertNil(meta?.tokens.total)
    }

    func testCacheSkipsUnchangedFilesAndReparsesOnStampChange() throws {
        let folder = try temp(), url = folder.appendingPathComponent("session-a.json")
        try Data(document().utf8).write(to: url)
        var cache = DshProjcacheCache()
        func stamp() -> String {
            // FileManager, not URL.resourceValues: values cached on the URL
            // struct would go stale after the file is rewritten.
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            return DshProjcacheCache.stamp(modificationDate: attributes?[.modificationDate] as? Date,
                                         size: (attributes?[.size] as? NSNumber)?.int64Value)
        }
        let first = cache.load(url: url, stamp: stamp())
        XCTAssertTrue(first.parsed)
        XCTAssertEqual(first.value?.turnOpen, true)
        let second = cache.load(url: url, stamp: stamp())
        XCTAssertFalse(second.parsed)
        XCTAssertEqual(second.value, first.value)
        // Same path, new size: reparse. A corrupt file is cached as a miss too.
        try Data("garbage".utf8).write(to: url)
        let third = cache.load(url: url, stamp: stamp())
        XCTAssertTrue(third.parsed)
        XCTAssertNil(third.value)
        let fourth = cache.load(url: url, stamp: stamp())
        XCTAssertFalse(fourth.parsed)
        XCTAssertNil(fourth.value)
        cache.keepOnly(paths: [])
        let fifth = cache.load(url: url, stamp: stamp())
        XCTAssertTrue(fifth.parsed)
    }
}

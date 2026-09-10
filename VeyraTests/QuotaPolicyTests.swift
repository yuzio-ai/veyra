import XCTest
import Foundation

final class QuotaPolicyTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_788_410_400)
    private func event(bucket: String? = "codex", used: Int = 20, date: String = "2026-09-03T01:00:00Z", secondary: Bool = false) -> Data {
        let id = bucket.map { ",\"limit_id\":\"\($0)\"" } ?? ""
        let second = secondary ? ",\"secondary\":{\"used_percent\":90,\"window_minutes\":10080}" : ""
        return Data("{\"timestamp\":\"\(date)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":null,\"rate_limits\":{\"primary\":{\"used_percent\":\(used),\"window_minutes\":300,\"resets_at\":1789000000}\(id)\(second)}}}".utf8)
    }
    func testIndependentQuotaEventsWholeBucketsAndEventTimeOrdering() {
        var state = RolloutState()
        RolloutEvent.apply(event(bucket: nil, secondary: true), to: &state)
        XCTAssertNil(state.usage)
        XCTAssertEqual(state.quotaBuckets["codex"]?.windows.count, 2)
        RolloutEvent.apply(event(used: 40, date: "2026-09-03T01:02:00Z"), to: &state)
        RolloutEvent.apply(event(used: 5, date: "2026-09-03T01:01:00Z", secondary: true), to: &state)
        RolloutEvent.apply(event(bucket: "spark", used: 90), to: &state)
        let snapshot = LocalQuotaBucket.snapshot(state.quotaBuckets)!
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(snapshot.menuWindow?.remainingPercent, 60)
        XCTAssertEqual(snapshot.source, .local)
        XCTAssertNil(snapshot.accountID)
        XCTAssertGreaterThan(snapshot.recordedAt(for: "codex"), snapshot.recordedAt(for: "spark"))
        XCTAssertFalse(snapshot.isStale(bucketID: "codex", at: snapshot.fetchedAt.addingTimeInterval(300)))
        XCTAssertTrue(snapshot.isStale(bucketID: "spark", at: snapshot.fetchedAt.addingTimeInterval(300)))
    }
    func testMissingWindowsInvalidTimestampAndResetNeverInventAllowance() {
        var state = RolloutState()
        RolloutEvent.apply(event(used: 100), to: &state)
        RolloutEvent.apply(event(used: 0, date: "invalid"), to: &state)
        let snapshot = LocalQuotaBucket.snapshot(state.quotaBuckets)!
        XCTAssertEqual(snapshot.menuWindow?.remainingPercent, 0)
        XCTAssertTrue(snapshot.isStale(bucketID: "codex", at: Date(timeIntervalSince1970: 1_789_000_001)))
        let missing = LocalQuotaBucket.parse(.object(["primary": .object([:])]), at: date)!
        XCTAssertNil(missing.windows.first?.remainingPercent)
        XCTAssertNil(LocalQuotaBucket.parse(.null, at: date))
    }
    func testEqualTimestampsUseLastRecordInBothScanDirectionsWithoutInheritingWindows() {
        let events = [event(used: 20, secondary: true), event(used: 70),
                      event(used: 5, date: "2026-09-03T00:59:59Z", secondary: true)]
        for reverse in [false, true] {
            var state = RolloutState()
            for line in reverse ? Array(events.reversed()) : events {
                RolloutEvent.apply(line, to: &state, newestFirst: reverse)
            }
            if reverse { RolloutEvent.flushPendingQuota(into: &state, model: nil) }
            XCTAssertEqual(state.quotaBuckets["codex"]?.windows.count, 1)
            XCTAssertEqual(state.quotaBuckets["codex"]?.windows.first?.remainingPercent, 30)
        }
    }
    func testEqualTimestampQuotaAgreesAcrossIncrementalColdAndUpgradedReads() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("quota.jsonl")
        let newline = Data([10]), filler = Data(String(repeating: "{}\n", count: 100_000).utf8)
        try (filler + event(bucket: "spark") + newline + event(secondary: true) + newline).write(to: url)
        var incremental = RolloutReader(), upgraded = RolloutReader()
        _ = try incremental.read(url, quotaOnly: true)
        _ = try upgraded.read(url, quotaOnly: true)
        let fields = Data((#"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn"}}"# + "\n" +
            #"{"type":"turn_context","payload":{"model":"test"}}"# + "\n" +
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":123}}}}"# + "\n").utf8)
        let added = filler + fields + event(used: 70) + newline + event(used: 5, date: "2026-09-03T00:59:59Z", secondary: true) + newline
        let file = try FileHandle(forWritingTo: url)
        try file.seekToEnd(); try file.write(contentsOf: added); try file.close()
        let warm = try incremental.read(url, quotaOnly: true)
        XCTAssertEqual(incremental.lastReadByteCount, added.count)
        let rescanned = try upgraded.read(url)
        XCTAssertEqual(upgraded.lastReadByteCount, 256 * 1_024)
        var fresh = RolloutReader()
        let cold = try fresh.read(url, quotaOnly: true)
        for state in [warm, rescanned, cold] {
            XCTAssertEqual(state.quotaBuckets["codex"]?.windows.count, 1)
            XCTAssertEqual(state.quotaBuckets["codex"]?.windows.first?.remainingPercent, 30)
        }
        XCTAssertEqual(rescanned.quotaBuckets["spark"], warm.quotaBuckets["spark"])
        XCTAssertNotNil(rescanned.quotaBuckets["spark"])
        _ = try upgraded.read(url)
        XCTAssertEqual(upgraded.lastReadByteCount, 0)
        XCTAssertEqual(upgraded.lastOpenCount, 0)
    }
    private func quota(_ id: String, used: Double, primary: Bool = true) -> QuotaWindow {
        QuotaWindow(id: "\(id):\(primary ? "primary" : "secondary")", bucketID: id, bucketName: id,
                    isPrimary: primary, usedPercent: used, durationMinutes: primary ? 300 : 10_080,
                    resetsAt: nil)
    }

    func testNewerLocalBucketPreservesOtherOnlineBucketsAndVerifiedPlan() throws {
        let account = AccountSnapshot(json: .object(["type": .string("chatgpt"), "planType": .string("prolite")]), accountID: "a")
        let spark = [quota("spark", used: 0), quota("spark", used: 0, primary: false)]
        let network = QuotaSnapshot(windows: [quota("codex", used: 80)] + spark, fetchedAt: date, accountID: "a")
        let local = LocalQuotaBucket.snapshot(["codex": LocalQuotaBucket(id: "codex",
            windows: [quota("codex", used: 89)], recordedAt: date.addingTimeInterval(10))])!
        var state = QuotaDisplayState()
        state.apply(QuotaRefresh(account: account, snapshot: network))
        for _ in 0..<3 {
            state.updateLocal(local)
            let displayed = try XCTUnwrap(state.snapshot)
            XCTAssertEqual(displayed.windows, local.windows + spark)
            XCTAssertEqual(displayed.source(for: "codex"), .local)
            XCTAssertEqual(displayed.source(for: "spark"), .network)
            XCTAssertEqual(displayed.recordedAt(for: "codex"), local.fetchedAt)
            XCTAssertEqual(displayed.recordedAt(for: "spark"), date)
            XCTAssertEqual(displayed.source, .local)
            XCTAssertTrue(displayed.isStale(bucketID: "codex", at: date.addingTimeInterval(400)))
            XCTAssertFalse(displayed.isStale(bucketID: "spark", at: date.addingTimeInterval(400)))
            XCTAssertNil(displayed.accountID)
            XCTAssertEqual(state.account, account)
        }
        state.apply(QuotaRefresh(error: .timeout))
        XCTAssertEqual(state.snapshot?.windows, local.windows + spark)
        state.invalidateAccount()
        XCTAssertEqual(state.snapshot, local)
        XCTAssertNil(state.account)
        state.updateLocal(nil)
        XCTAssertNil(state.snapshot)
    }

    func testLocalFreshnessIsComparedPerBucketAndEqualDatesPreferOnline() {
        let network = QuotaSnapshot(windows: [quota("codex", used: 40), quota("spark", used: 50)],
                                    fetchedAt: date, accountID: "a")
        for offset: TimeInterval in [-10, 0] {
            let local = LocalQuotaBucket.snapshot([
                "codex": LocalQuotaBucket(id: "codex", windows: [quota("codex", used: 1)], recordedAt: date.addingTimeInterval(offset)),
                "spark": LocalQuotaBucket(id: "spark", windows: [quota("spark", used: 60)], recordedAt: date.addingTimeInterval(10)),
                "old": LocalQuotaBucket(id: "old", windows: [quota("old", used: 1)], recordedAt: date.addingTimeInterval(-10))
            ])!
            var state = QuotaDisplayState()
            state.updateLocal(local)
            state.apply(QuotaRefresh(snapshot: network))
            XCTAssertEqual(state.snapshot?.windows, [quota("codex", used: 40), quota("spark", used: 60)])
            XCTAssertEqual(state.snapshot?.source, .network)
            XCTAssertEqual(state.snapshot?.source(for: "spark"), .local)
        }
    }

    func testLocalReplacementRemovesMissingWindowsAndExplicitlyEmptyBuckets() {
        let network = QuotaSnapshot(windows: [quota("codex", used: 40), quota("codex", used: 50, primary: false),
                                              quota("spark", used: 0)], fetchedAt: date, accountID: "a")
        for windows in [[quota("codex", used: 60)], []] {
            let local = LocalQuotaBucket.snapshot(["codex": LocalQuotaBucket(id: "codex", windows: windows,
                recordedAt: date.addingTimeInterval(10))])!
            var state = QuotaDisplayState()
            state.apply(QuotaRefresh(snapshot: network))
            state.updateLocal(local)
            XCTAssertEqual(state.snapshot?.windows, windows + [quota("spark", used: 0)])
            // A new authoritative sync must remove old buckets, even for an empty response.
            let empty = QuotaSnapshot(windows: [], fetchedAt: date.addingTimeInterval(20), accountID: "a")
            state.apply(QuotaRefresh(snapshot: empty))
            XCTAssertEqual(state.snapshot, empty)
        }
    }

    func testAbsentLocalBucketsCannotEraseOnlineQuota() {
        let network = QuotaSnapshot(windows: [quota("spark", used: 0)], fetchedAt: date, accountID: "a")
        var state = QuotaDisplayState()
        state.apply(QuotaRefresh(snapshot: network))
        state.updateLocal(QuotaSnapshot(windows: [], fetchedAt: date.addingTimeInterval(10), accountID: nil, source: .local))
        XCTAssertEqual(state.snapshot, network)
        state.updateLocal(nil)
        XCTAssertEqual(state.snapshot, network)
    }

    private func sparkOnline(_ used: Double, primary: Bool = true) -> QuotaWindow {
        QuotaWindow(id: "codex_bengalfox:\(primary ? "primary" : "secondary")", bucketID: "codex_bengalfox",
                    bucketName: "GPT-5.3-Codex-Spark", isPrimary: primary, usedPercent: used,
                    durationMinutes: primary ? 300 : 10_080, resetsAt: nil)
    }

    // A Spark task reports its governing limit under the generic limit_id "codex";
    // the session model must steer the record to the matching online bucket.
    func testLocalBucketRetargetsToOnlineBucketMatchingSessionModel() throws {
        let exhausted = quota("codex", used: 100, primary: false)
        let network = QuotaSnapshot(windows: [exhausted, sparkOnline(0), sparkOnline(0, primary: false)],
                                    fetchedAt: date, accountID: "a")
        let localWindows = [quota("codex", used: 7), quota("codex", used: 3, primary: false)]
        let local = LocalQuotaBucket.snapshot(["codex": LocalQuotaBucket(id: "codex", windows: localWindows,
            recordedAt: date.addingTimeInterval(10), model: "gpt-5.3-codex-spark")])!
        var state = QuotaDisplayState()
        state.apply(QuotaRefresh(snapshot: network))
        for _ in 0..<3 {
            state.updateLocal(local)
            let displayed = try XCTUnwrap(state.snapshot)
            XCTAssertEqual(displayed.windows, [exhausted,
                localWindows[0].rebucketed(to: "codex_bengalfox", name: "GPT-5.3-Codex-Spark"),
                localWindows[1].rebucketed(to: "codex_bengalfox", name: "GPT-5.3-Codex-Spark")])
            XCTAssertEqual(displayed.source(for: "codex"), .network)
            XCTAssertEqual(displayed.source(for: "codex_bengalfox"), .local)
            XCTAssertEqual(displayed.recordedAt(for: "codex"), date)
            XCTAssertEqual(displayed.recordedAt(for: "codex_bengalfox"), date.addingTimeInterval(10))
            XCTAssertEqual(displayed.menuWindow?.remainingPercent, 0)
        }
    }

    func testLocalBucketWithoutModelMatchKeepsReportedLimitID() throws {
        let network = QuotaSnapshot(windows: [quota("codex", used: 100), sparkOnline(0)],
                                    fetchedAt: date, accountID: "a")
        for model in [nil, "", "gpt-6-astra", "gpt-5.3-codex"] {
            let local = LocalQuotaBucket.snapshot(["codex": LocalQuotaBucket(id: "codex", windows: [quota("codex", used: 7)],
                recordedAt: date.addingTimeInterval(10), model: model)])!
            var state = QuotaDisplayState()
            state.apply(QuotaRefresh(snapshot: network))
            state.updateLocal(local)
            XCTAssertEqual(state.snapshot?.windows, [quota("codex", used: 7), sparkOnline(0)], model ?? "nil")
            XCTAssertEqual(state.snapshot?.source(for: "codex"), .local)
            XCTAssertEqual(state.snapshot?.source(for: "codex_bengalfox"), .network)
        }
    }

    func testRetargetCollisionsKeepNewestLocalRecord() {
        let network = QuotaSnapshot(windows: [quota("codex", used: 100), sparkOnline(0)],
                                    fetchedAt: date, accountID: "a")
        let local = LocalQuotaBucket.snapshot([
            "codex": LocalQuotaBucket(id: "codex", windows: [quota("codex", used: 7)],
                                      recordedAt: date.addingTimeInterval(10), model: "gpt-5.3-codex-spark"),
            "spark": LocalQuotaBucket(id: "spark", windows: [quota("spark", used: 50)],
                                      recordedAt: date.addingTimeInterval(5), model: "gpt-5.3-codex-spark")
        ])!
        var state = QuotaDisplayState()
        state.apply(QuotaRefresh(snapshot: network))
        state.updateLocal(local)
        XCTAssertEqual(state.snapshot?.windows, [quota("codex", used: 100),
                                                 quota("codex", used: 7).rebucketed(to: "codex_bengalfox", name: "GPT-5.3-Codex-Spark")])
        XCTAssertEqual(state.snapshot?.recordedAt(for: "codex_bengalfox"), date.addingTimeInterval(10))
        XCTAssertEqual(state.snapshot?.source(for: "codex_bengalfox"), .local)
    }

    func testForwardQuotaEventsCarryTurnContextModelIntoSnapshot() {
        var state = RolloutState()
        RolloutEvent.apply(Data(#"{"type":"turn_context","payload":{"model":"gpt-5.3-codex-spark"}}"#.utf8), to: &state)
        RolloutEvent.apply(event(), to: &state)
        RolloutEvent.apply(event(bucket: "spark", used: 90), to: &state)
        let snapshot = LocalQuotaBucket.snapshot(state.quotaBuckets)
        XCTAssertEqual(snapshot?.bucketModels, ["codex": "gpt-5.3-codex-spark", "spark": "gpt-5.3-codex-spark"])
        RolloutEvent.apply(Data(#"{"type":"turn_context","payload":{"model":"gpt-6-astra"}}"#.utf8), to: &state)
        RolloutEvent.apply(event(used: 40, date: "2026-09-03T01:02:00Z"), to: &state)
        XCTAssertEqual(LocalQuotaBucket.snapshot(state.quotaBuckets)?.bucketModels["codex"], "gpt-6-astra")
    }
    func testCalibrationCooldownBackoffAndStructuredRetryAfter() throws {
        var policy = QuotaCalibrationPolicy()
        policy.began(at: date)
        XCTAssertFalse(policy.allowsRequest(at: date.addingTimeInterval(59)))
        policy.finished(QuotaRefresh(error: .missingExecutable), startedAt: date, now: date)
        XCTAssertTrue(policy.allowsRequest(at: date))
        for delay: TimeInterval in [300, 900, 1800, 1800] {
            policy.began(at: date)
            policy.finished(QuotaRefresh(error: .rpcFailed, didRequestQuota: true), startedAt: date, now: date)
            XCTAssertEqual(policy.nextAllowedAt, date.addingTimeInterval(delay))
        }
        let raw = try JSONValue.decode(Data(#"{"code":-32000,"message":"SECRET","data":{"status":429,"retryAfterSeconds":7200,"credential":"SECRET"}}"#.utf8))
        let details = QuotaFailureDetails(rpcError: raw)
        XCTAssertEqual(details.category, .rateLimited)
        XCTAssertEqual(details.httpStatus, 429)
        XCTAssertEqual(details.rpcCode, -32000)
        policy.finished(QuotaRefresh(error: .rateLimited, failureDetails: details, didRequestQuota: true), startedAt: date, now: date)
        XCTAssertEqual(policy.nextAllowedAt, date.addingTimeInterval(7200))
        policy.finished(QuotaRefresh(didRequestQuota: true), startedAt: date, now: date.addingTimeInterval(2))
        XCTAssertEqual(policy.failures, 0)
        XCTAssertEqual(policy.nextAllowedAt, date.addingTimeInterval(60))
    }
    func testKnownPlanDisplayNamesPreserveRawValues() {
        let cases = [
            ("free", "FREE"), ("free_workspace", "FREE"), ("guest", "FREE"),
            ("go", "GO"), ("plus", "PLUS"), ("pro", "PRO"), ("prolite", "PRO"),
            ("team", "BUSINESS"), ("self_serve_business_prolite", "BUSINESS"),
            ("self_serve_business_usage_based", "BUSINESS"), ("business", "ENTERPRISE"),
            ("enterprise", "ENTERPRISE"), ("enterprise_cbp_automation", "ENTERPRISE"),
            ("enterprise_cbp_usage_based", "ENTERPRISE"), ("ent26", "ENTERPRISE")
        ]
        for (raw, expected) in cases {
            for input in [raw, " \t\(raw.uppercased())\n"] {
                let account = AccountSnapshot(json: .object(["planType": .string(input)]))
                XCTAssertEqual(account.planDisplayName, expected, input)
                XCTAssertEqual(account.plan, input)
            }
        }
    }

    func testUnmappedPlanDisplayNamesDoNotInventProductMappings() {
        let cases = [
            ("education", "EDUCATION"), ("edu_plus", "EDU PLUS"), ("edu_pro", "EDU PRO"),
            ("edu", "EDU"), ("deprecated_edu", "DEPRECATED EDU"), ("k12", "K12"),
            ("deprecated_enterprise", "DEPRECATED ENTERPRISE"),
            ("enterprise_cbp_trial", "ENTERPRISE CBP TRIAL"), ("hc", "HC"),
            ("finserv", "FINSERV"), ("sci", "SCI"), ("quorum", "QUORUM"), ("unknown", "UNKNOWN"),
            ("future_enterprise_tier", "FUTURE ENTERPRISE TIER"),
            (" \tfuture--pro__tier\n edition ", "FUTURE PRO TIER EDITION"), ("__--", "__--")
        ]
        for (raw, expected) in cases {
            let account = AccountSnapshot(json: .object(["planType": .string(raw)]))
            XCTAssertEqual(account.planDisplayName, expected, raw)
            XCTAssertEqual(account.plan, raw)
        }
    }

    func testMissingOrBlankPlanDisplayNameIsAbsent() {
        for value in [JSONValue.null, .string(""), .string(" \t\n")] {
            XCTAssertNil(AccountSnapshot(json: .object(["planType": value])).planDisplayName)
        }
        XCTAssertNil(AccountSnapshot(json: .object([:])).planDisplayName)
    }

    func testProDisplayNamePreservesDistinctAccountTiers() throws {
        let lite = AccountSnapshot(json: try JSONValue.decode(Data(
            #"{"type":"chatgpt","email":"fixture@example.invalid","planType":"prolite"}"#.utf8)))
        let pro = AccountSnapshot(json: try JSONValue.decode(Data(
            #"{"type":"chatgpt","email":"fixture@example.invalid","planType":"pro"}"#.utf8)))
        XCTAssertEqual(lite.planDisplayName, "PRO")
        XCTAssertEqual(pro.planDisplayName, "PRO")
        XCTAssertEqual(lite.plan, "prolite")
        XCTAssertNotEqual(lite.identity, pro.identity)
        XCTAssertFalse(lite.matches(pro))
    }

    func testFreshSidecarFailureRetainsVerifiedSnapshotWithoutReplacingAccountIdentity() throws {
        let raw = try JSONValue.decode(Data(#"{"type":"chatgpt","email":"fixture@example.invalid","planType":"pro"}"#.utf8))
        let verified = AccountSnapshot(json: raw, accountID: "verified-id")
        let snapshot = QuotaSnapshot(windows: [], fetchedAt: date, accountID: verified.accountID)
        var state = QuotaDisplayState()
        state.apply(QuotaRefresh(account: verified, snapshot: snapshot))
        state.apply(QuotaRefresh(account: AccountSnapshot(json: raw), error: .rpcFailed, didRequestQuota: true))
        XCTAssertEqual(state.snapshot, snapshot)
        XCTAssertEqual(state.account, verified)
        state.apply(QuotaRefresh(account: AccountSnapshot(json: raw, accountID: "different-id"), error: .rpcFailed))
        XCTAssertNil(state.snapshot)
        XCTAssertNil(state.account)
    }
    func testBoundedQuotaTailCachesAbsenceAndSharesTaskCursor() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("log.jsonl")
        let filler = Data(String(repeating: "{\"type\":\"ignored\"}\n", count: 30_000).utf8)
        var data = event(); data.append(10); data.append(filler)
        try data.write(to: url)
        var reader = RolloutReader()
        XCTAssertTrue(try reader.read(url, quotaOnly: true).quotaBuckets.isEmpty)
        XCTAssertEqual(reader.lastReadByteCount, 256 * 1024)
        _ = try reader.read(url, quotaOnly: true)
        XCTAssertEqual(reader.lastReadByteCount, 0)
        XCTAssertEqual(reader.lastOpenCount, 0)
        let file = try FileHandle(forWritingTo: url)
        try file.seekToEnd()
        let line = event(bucket: "spark")
        try file.write(contentsOf: line.prefix(line.count / 2))
        XCTAssertTrue(try reader.read(url, quotaOnly: true).quotaBuckets.isEmpty)
        var rest = Data(line.dropFirst(line.count / 2)); rest.append(10)
        try file.write(contentsOf: rest); try file.close()
        XCTAssertEqual(try reader.read(url, quotaOnly: true).quotaBuckets["spark"]?.windows.first?.remainingPercent, 80)
        // Upgrading the shared cursor still reads the task's older lifecycle/model fields.
        _ = try reader.read(url)
        XCTAssertNotNil(try reader.read(url, quotaOnly: true).quotaBuckets["codex"])
        XCTAssertEqual(reader.lastReadByteCount, 0)
        try Data("{}\n".utf8).write(to: url, options: .atomic)
        XCTAssertTrue(try reader.read(url, quotaOnly: true).quotaBuckets.isEmpty)
    }
}

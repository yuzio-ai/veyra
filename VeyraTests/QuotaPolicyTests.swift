import XCTest
import Foundation

final class QuotaPolicyTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_788_410_400)

    func testOnlineSnapshotReplacesRemovedBucketsAndEmptyResponseClearsQuota() throws {
        let first = QuotaSnapshot.parse(try JSONValue.decode(Data(#"{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":80}},"additional-limit":{"primary":{"usedPercent":30}}}}"#.utf8)), at: date)
        let next = QuotaSnapshot.parse(try JSONValue.decode(Data(#"{"rateLimitsByLimitId":{"codex":{"secondary":{"usedPercent":50,"windowDurationMins":10080}}}}"#.utf8)), at: date.addingTimeInterval(60))
        var state = QuotaDisplayState()
        state.apply(QuotaRefresh(snapshot: first))
        XCTAssertEqual(state.snapshot?.windows.count, 2)
        state.apply(QuotaRefresh(snapshot: next))
        XCTAssertEqual(state.snapshot, next)
        XCTAssertEqual(state.snapshot?.menuWindow?.remainingPercent, 50)
        let empty = QuotaSnapshot.parse(.object(["rateLimitsByLimitId": .object([:])]), at: date.addingTimeInterval(120))
        state.apply(QuotaRefresh(snapshot: empty, error: .noQuotaWindows))
        XCTAssertEqual(state.snapshot, empty)
        XCTAssertNil(state.snapshot?.menuWindow)
    }

    func testAccountWithoutQuotaRemainsUnverifiedUntilSuccessfulSync() {
        let account = AccountSnapshot(json: .object(["type": .string("chatgpt"), "email": .string("fixture@example.invalid")]))
        var state = QuotaDisplayState()
        state.apply(QuotaRefresh(account: account, error: .timeout))
        XCTAssertNil(state.account)
        XCTAssertNil(state.snapshot)
        let snapshot = QuotaSnapshot(windows: [], fetchedAt: date, accountID: nil)
        state.apply(QuotaRefresh(account: account, snapshot: snapshot))
        XCTAssertEqual(state.account, account)
        XCTAssertEqual(state.snapshot, snapshot)
        state.apply(QuotaRefresh(error: .disconnected))
        XCTAssertEqual(state.account, account)
        XCTAssertEqual(state.snapshot, snapshot)
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
}

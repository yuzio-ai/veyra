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
    func testSourceSwitchingNeverLeaksNetworkAccountIntoLocalSnapshot() throws {
        let account = AccountSnapshot(json: try JSONValue.decode(Data(#"{"type":"chatgpt","email":"test@example.invalid"}"#.utf8)))
        let network = QuotaSnapshot(windows: [], fetchedAt: date, accountID: "a")
        var state = QuotaDisplayState()
        state.updateLocal(QuotaSnapshot(windows: [], fetchedAt: date.addingTimeInterval(-10), accountID: nil, source: .local))
        state.apply(QuotaRefresh(account: account, snapshot: network))
        XCTAssertEqual(state.snapshot?.source, .network)
        XCTAssertEqual(state.account, account)
        let local = QuotaSnapshot(windows: [], fetchedAt: date.addingTimeInterval(1), accountID: nil, source: .local)
        state.updateLocal(local)
        XCTAssertEqual(state.snapshot, local)
        XCTAssertNil(state.account)
        state.invalidateAccount()
        state.updateLocal(nil)
        XCTAssertNil(state.snapshot)
        XCTAssertNil(state.account)
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

import XCTest
import Foundation

final class ResetCreditsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 100)

    private func parse(_ text: String) throws -> ResetCreditsSnapshot {
        ResetCreditsSnapshot.parse(try JSONValue.decode(Data(text.utf8)), at: now)
    }

    func testGroupsByExactExpiryAndSortsUnknownLast() throws {
        let snapshot = try parse(#"{"availableCount":5,"credits":[{"status":"available","expiresAt":201},{"status":"available","expiresAt":200},{"status":"available","expiresAt":200},{"status":"available","expiresAt":null},{"status":"available"}]}"#)
        XCTAssertEqual(snapshot.availableCount, 5)
        XCTAssertEqual(snapshot.expiryGroups.map(\.count), [2, 1, 2])
        XCTAssertEqual(snapshot.expiryGroups.map { $0.expiresAt?.timeIntervalSince1970 }, [200, 201, nil])
        XCTAssertEqual(snapshot.fetchedAt, now)
        XCTAssertTrue(snapshot.hasIncompleteDetails)
    }

    func testOnlyAvailableCreditsCountAndDuplicateIDsDoNotInflateGroups() throws {
        let snapshot = try parse(#"{"availableCount":1,"credits":[{"id":"a","status":"available","expiresAt":200},{"id":"a","status":"available","expiresAt":200},{"status":"redeemed","expiresAt":200},{"status":"expired","expiresAt":0},{"status":"redeeming","expiresAt":200},{"status":"future-status","expiresAt":200}]}"#)
        XCTAssertEqual(snapshot.expiryGroups.map(\.count), [1])
        XCTAssertFalse(snapshot.hasExpiredCredits(at: now))
        XCTAssertTrue(snapshot.hasIncompleteDetails)
    }

    func testMissingDetailsAndMismatchedTotalsRemainAuthoritative() throws {
        for text in [
            #"{"availableCount":3}"#,
            #"{"availableCount":3,"credits":null}"#,
            #"{"availableCount":3,"credits":{}}"#,
            #"{"availableCount":3,"credits":[{"status":"available","expiresAt":200}]}"#,
            #"{"availableCount":3,"credits":[null,{},5]}"#
        ] {
            let snapshot = try parse(text)
            XCTAssertEqual(snapshot.totalLabel(at: now), L10n.resetCount(3))
            XCTAssertTrue(snapshot.hasIncompleteDetails)
        }
        let excess = try parse(#"{"availableCount":0,"credits":[{"status":"available","expiresAt":200}]}"#)
        XCTAssertEqual(excess.totalLabel(at: now), L10n.resetCount(0))
        XCTAssertTrue(excess.hasIncompleteDetails)
    }

    func testZeroAndUnsupportedResponsesAreDistinct() throws {
        for text in [#"{"availableCount":0,"credits":[]}"#, #"{"availableCount":0}"#] {
            let snapshot = try parse(text)
            XCTAssertEqual(snapshot.totalLabel(at: now), L10n.resetCount(0))
            XCTAssertTrue(snapshot.expiryGroups.isEmpty)
            XCTAssertFalse(snapshot.hasIncompleteDetails)
        }
        for text in ["{}", "null", #"{"availableCount":null}"#] {
            let snapshot = try parse(text)
            XCTAssertNil(snapshot.availableCount)
            XCTAssertEqual(snapshot.totalLabel(at: now), "—")
        }
    }

    func testInvalidCountsAreUnavailableAndInvalidDatesAreUnknown() throws {
        for value in ["-1", "1.5", "1e100", "9223372036854775808", "true", #""2""#] {
            XCTAssertNil(try parse("{\"availableCount\":\(value)}").availableCount, value)
        }
        for value in ["-1", "200.5", "1e100", "253402300800", "true", #""200""#, "null"] {
            let snapshot = try parse("{\"availableCount\":1,\"credits\":[{\"status\":\"available\",\"expiresAt\":\(value)}]}")
            XCTAssertEqual(snapshot.credits.count, 1)
            XCTAssertNil(snapshot.credits.first?.expiresAt, value)
            XCTAssertTrue(snapshot.hasIncompleteDetails)
            XCTAssertFalse(snapshot.hasExpiredCredits(at: now))
        }
    }

    func testExpiryBoundaryUpdatesWithoutChangingTheNetworkSnapshot() throws {
        let snapshot = try parse(#"{"availableCount":2,"credits":[{"status":"available","expiresAt":200},{"status":"available","expiresAt":300}]}"#)
        XCTAssertFalse(snapshot.hasIncompleteDetails)
        XCTAssertEqual(snapshot.totalLabel(at: Date(timeIntervalSince1970: 199.999)), L10n.resetCount(2))
        XCTAssertEqual(snapshot.totalLabel(at: Date(timeIntervalSince1970: 200)), L10n.text("Sync needed"))
        XCTAssertTrue(snapshot.expiryGroups[0].isExpired(at: Date(timeIntervalSince1970: 200)))
        XCTAssertFalse(snapshot.expiryGroups[1].isExpired(at: Date(timeIntervalSince1970: 200)))
        XCTAssertEqual(snapshot.availableCount, 2)
        XCTAssertEqual(snapshot.fetchedAt, now)
    }

    func testNetworkSnapshotKeepsCreditsWithoutQuotaWindows() throws {
        let value = try JSONValue.decode(Data(#"{"rateLimitsByLimitId":{},"rateLimitResetCredits":{"availableCount":1,"credits":[{"status":"available","expiresAt":200}]}}"#.utf8))
        let snapshot = QuotaSnapshot.parse(value, at: now)
        XCTAssertTrue(snapshot.windows.isEmpty)
        XCTAssertEqual(snapshot.resetCredits?.availableCount, 1)
        var state = QuotaDisplayState()
        state.apply(QuotaRefresh(snapshot: snapshot, error: .noQuotaWindows))
        XCTAssertEqual(state.resetCredits, snapshot.resetCredits)
    }

    func testLocalUpdatesAndFailuresPreserveCreditsButSuccessfulMissingFieldClearsThem() throws {
        var state = QuotaDisplayState()
        XCTAssertNil(state.resetCredits)
        let account = AccountSnapshot(json: .object(["type": .string("chatgpt"), "email": .string("fixture@example.invalid")]))
        let credits = try parse(#"{"availableCount":1,"credits":[{"status":"available","expiresAt":200}]}"#)
        let network = QuotaSnapshot(windows: [], fetchedAt: now, accountID: nil, resetCredits: credits)
        state.apply(QuotaRefresh(account: account, snapshot: network))
        let local = QuotaSnapshot(windows: [], fetchedAt: now.addingTimeInterval(10), accountID: nil, source: .local)
        state.updateLocal(local)
        XCTAssertEqual(state.snapshot, network)
        XCTAssertEqual(state.resetCredits, credits)
        state.apply(QuotaRefresh(account: account, error: .timeout))
        XCTAssertEqual(state.resetCredits, credits)
        state.apply(QuotaRefresh(account: account, snapshot: QuotaSnapshot.parse(.object([:]), at: now)))
        XCTAssertNotNil(state.resetCredits)
        XCTAssertNil(state.resetCredits?.availableCount)
        XCTAssertTrue(state.resetCredits?.credits.isEmpty == true)
    }

    func testAccountInvalidationClearsCreditsEvenWhenShowingLocalQuota() throws {
        let credits = try parse(#"{"availableCount":1}"#)
        let first = AccountSnapshot(json: .object(["type": .string("chatgpt")]), accountID: "first")
        let second = AccountSnapshot(json: .object(["type": .string("chatgpt")]), accountID: "second")
        let local = QuotaSnapshot(windows: [], fetchedAt: now.addingTimeInterval(10), accountID: nil, source: .local)
        for explicitInvalidation in [true, false] {
            var state = QuotaDisplayState()
            state.apply(QuotaRefresh(account: first, snapshot: QuotaSnapshot(windows: [], fetchedAt: now,
                accountID: "first", resetCredits: credits)))
            state.updateLocal(local)
            if explicitInvalidation { state.invalidateAccount() }
            else { state.apply(QuotaRefresh(account: second, error: .timeout)) }
            XCTAssertEqual(state.snapshot, local)
            XCTAssertNil(state.resetCredits)
        }
    }
}

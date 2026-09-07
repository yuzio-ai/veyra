import Foundation

/// Account-wide network data; local quota events do not contain reset credits.
struct ResetCreditsSnapshot: Equatable, Sendable {
    struct Credit: Equatable, Sendable {
        let expiresAt: Date?
    }

    struct ExpiryGroup: Identifiable, Equatable, Sendable {
        var id: Date? { expiresAt }
        let expiresAt: Date?
        let count: Int

        func isExpired(at now: Date) -> Bool { expiresAt.map { $0 <= now } ?? false }
    }

    let availableCount: Int64?
    let credits: [Credit]
    let fetchedAt: Date
    let hasIncompleteDetails: Bool

    var expiryGroups: [ExpiryGroup] {
        Dictionary(grouping: credits, by: \.expiresAt).map {
            ExpiryGroup(expiresAt: $0.key, count: $0.value.count)
        }.sorted {
            guard let first = $0.expiresAt else { return false }
            guard let second = $1.expiresAt else { return true }
            return first < second
        }
    }

    func hasExpiredCredits(at now: Date) -> Bool {
        credits.contains { $0.expiresAt.map { $0 <= now } ?? false }
    }

    func totalLabel(at now: Date) -> String {
        if hasExpiredCredits(at: now) { return L10n.text("Sync needed") }
        return availableCount.map(L10n.resetCount) ?? "—"
    }

    static func parse(_ value: JSONValue, at date: Date) -> ResetCreditsSnapshot {
        func nonnegativeInteger(_ value: JSONValue) -> Int64? {
            guard let number = value.double, number >= 0, number.rounded(.towardZero) == number else { return nil }
            return value.integer
        }
        let count = nonnegativeInteger(value["availableCount"])
        let entries = value["credits"].array
        var incomplete = entries == nil && count != 0
        var seenIDs = Set<String>()
        let credits = (entries ?? []).compactMap { entry -> Credit? in
            guard let status = entry["status"].string else { incomplete = true; return nil }
            guard status == "available" else { return nil }
            if let id = entry["id"].string, !seenIDs.insert(id).inserted {
                incomplete = true
                return nil
            }
            // Unix seconds through year 9999; malformed dates must never reach a formatter.
            let expiry = nonnegativeInteger(entry["expiresAt"]).flatMap { seconds -> Date? in
                guard seconds <= 253_402_300_799 else { return nil }
                return Date(timeIntervalSince1970: Double(seconds))
            }
            if expiry == nil { incomplete = true }
            return Credit(expiresAt: expiry)
        }
        if let count, count != Int64(credits.count) { incomplete = true }
        return ResetCreditsSnapshot(availableCount: count, credits: credits, fetchedAt: date,
                                    hasIncompleteDetails: incomplete)
    }
}

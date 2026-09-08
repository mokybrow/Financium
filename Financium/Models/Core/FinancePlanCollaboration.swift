import Foundation

/// Shared progress contains participant totals, never their private account IDs
/// or transaction history. A future share zone owns one contribution per member.
nonisolated struct FinancePlanCollaboration: Codable, Hashable, Sendable {
    var ownerID: String
    var acceptedParticipantIDs: Set<String>
    var contributions: [Contribution]

    struct Contribution: Codable, Hashable, Sendable {
        var participantID: String
        /// Empty for a goal balance; YYYY-MM for a budget's monthly spending.
        var monthKey: String
        var amount: FinanceMoney
        var revision: Int64
    }

    var isShared: Bool { !ownerID.isEmpty && acceptedParticipantIDs.contains { !$0.isEmpty && $0 != ownerID } }

    /// Latest absolute totals replace earlier revisions; retries never add twice.
    /// Currency conversion must happen explicitly before publishing a contribution.
    func total(currency: String, monthKey: String) -> FinanceMoney {
        var latest: [String: Contribution] = [:]
        for contribution in contributions {
            guard !contribution.participantID.isEmpty,
                  contribution.participantID == ownerID || acceptedParticipantIDs.contains(contribution.participantID),
                  contribution.monthKey == monthKey else { continue }
            if let previous = latest[contribution.participantID], previous.revision >= contribution.revision { continue }
            latest[contribution.participantID] = contribution
        }
        let total = latest.values.filter { $0.amount.currencyCode == currency }.reduce(Decimal.zero) {
            $0 + max(0, Decimal($1.amount.minorUnits) / 100)
        }
        var result = FinanceMoney()
        result.currencyCode = currency
        // Decimal aggregation prevents integer overflow while folding remote snapshots.
        let minor = NSDecimalNumber(decimal: total * 100)
        result.minorUnits = minor.compare(NSDecimalNumber(value: Int64.max)) == .orderedDescending ? Int64.max : minor.int64Value
        return result
    }

    static func decode(_ json: String) -> Self? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

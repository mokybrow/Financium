import Foundation

/// Shared progress contains participant totals, never their private account IDs
/// or transaction history. Each share zone owns one contribution per member.
nonisolated struct FinancePlanCollaboration: Codable, Hashable, Sendable {
    var ownerID: String
    var acceptedParticipantIDs: Set<String>
    var contributions: [Contribution]
    var planKey: String?
    var zoneName: String?
    var localParticipantID: String?

    struct Contribution: Codable, Hashable, Sendable {
        var participantID: String
        /// Empty for a goal balance; YYYY-MM for a budget's monthly spending.
        var monthKey: String
        var amount: FinanceMoney
        var revision: Int64
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(ownerID, forKey: .ownerID)
        try values.encode(acceptedParticipantIDs.sorted(), forKey: .acceptedParticipantIDs)
        try values.encode(contributions, forKey: .contributions)
        try values.encodeIfPresent(planKey, forKey: .planKey)
        try values.encodeIfPresent(zoneName, forKey: .zoneName)
        try values.encodeIfPresent(localParticipantID, forKey: .localParticipantID)
    }

    var isShared: Bool { !ownerID.isEmpty && acceptedParticipantIDs.contains { !$0.isEmpty && $0 != ownerID } }

    /// Latest absolute totals replace earlier revisions; retries never add twice.
    /// Currency conversion must happen explicitly before publishing a contribution.
    ///
    /// `excluding` drops one participant — pass the reader's own id so their live
    /// ledger figure is used for themselves and only the others' published
    /// snapshots are folded in.
    func total(currency: String, monthKey: String, excluding excludedID: String? = nil) -> FinanceMoney {
        var latest: [String: Contribution] = [:]
        for contribution in contributions {
            guard !contribution.participantID.isEmpty,
                  contribution.participantID != excludedID,
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

    /// The combined published contribution of every *other* participant, for
    /// folding into the reader's own local figure.
    func othersTotal(currency: String, monthKey: String, excluding selfID: String) -> FinanceMoney {
        total(currency: currency, monthKey: monthKey, excluding: selfID)
    }

    static func decode(_ json: String) -> Self? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

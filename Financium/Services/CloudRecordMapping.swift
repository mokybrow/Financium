import CloudKit
import Foundation

/// Turns native ledger values into `CKRecord`s and back.
///
/// One record type per entity. The compatibility codec preserves the legacy
/// wire format in a single `payload` field, while the local file uses native
/// versioned JSON. This keeps existing shared accounts readable by older app
/// versions. A few fields are lifted out alongside the
/// payload only where CloudKit needs them queryable or sortable.
///
/// `nonisolated` because the sync engine calls this from its own background
/// executor — the target otherwise defaults every declaration to the main
/// actor, and a hop there mid-merge would deadlock or, under strict
/// concurrency, trap.
nonisolated enum CloudRecordMapping {
    static let accountType = "Account"
    static let transactionType = "Transaction"
    static let budgetType = "Budget"
    static let goalType = "Goal"
    static let settingsType = "Settings"

    /// The fixed record name for the one settings record in a database.
    static let settingsRecordName = "settings"

    // MARK: - Record names

    static func recordName(accountID: String) -> String { "account_\(accountID)" }
    static func recordName(transactionID: String) -> String { "tx_\(transactionID)" }
    static func recordName(budgetID: String) -> String { "budget_\(budgetID)" }
    static func recordName(goalID: String) -> String { "goal_\(goalID)" }

    /// The entity id carried by a record name, or nil if it is not one of ours.
    static func entityID(fromRecordName name: String) -> (kind: Kind, id: String)? {
        if name == settingsRecordName { return (.settings, "") }
        for kind in Kind.allCases where kind.prefix != nil {
            if let prefix = kind.prefix, name.hasPrefix(prefix) {
                return (kind, String(name.dropFirst(prefix.count)))
            }
        }
        return nil
    }

    enum Kind: CaseIterable {
        case account, transaction, budget, goal, settings

        var recordType: String {
            switch self {
            case .account: accountType
            case .transaction: transactionType
            case .budget: budgetType
            case .goal: goalType
            case .settings: settingsType
            }
        }

        var prefix: String? {
            switch self {
            case .account: "account_"
            case .transaction: "tx_"
            case .budget: "budget_"
            case .goal: "goal_"
            case .settings: nil
            }
        }
    }

    // MARK: - Encoding

    static func apply(account: FinanceAccount, updatedAt: Date, to record: CKRecord) {
        record["payload"] = LegacyFinanceCodec.encode(account) as CKRecordValue?
        record["updatedAt"] = updatedAt as CKRecordValue
    }

    static func apply(transaction: FinanceTransaction, updatedAt: Date, to record: CKRecord) {
        record["payload"] = LegacyFinanceCodec.encode(transaction) as CKRecordValue?
        record["occurredAt"] = (transaction.hasOccurredAt ? transaction.occurredAt.date : Date()) as CKRecordValue
        record["updatedAt"] = updatedAt as CKRecordValue
    }

    static func apply(budget: FinanceBudget, month: String, updatedAt: Date, to record: CKRecord) {
        record["payload"] = LegacyFinanceCodec.encode(budget) as CKRecordValue?
        record["month"] = month as CKRecordValue
        record["updatedAt"] = updatedAt as CKRecordValue
    }

    static func apply(goal: FinanceGoal, updatedAt: Date, to record: CKRecord) {
        record["payload"] = LegacyFinanceCodec.encode(goal) as CKRecordValue?
        record["updatedAt"] = updatedAt as CKRecordValue
    }

    static func apply(settings: FinanceSettings, updatedAt: Date, to record: CKRecord) {
        record["payload"] = LegacyFinanceCodec.encode(settings) as CKRecordValue?
        record["updatedAt"] = updatedAt as CKRecordValue
    }

    // MARK: - Decoding

    static func account(from record: CKRecord) -> FinanceAccount? {
        guard let data = record["payload"] as? Data else { return nil }
        return try? LegacyFinanceCodec.decode(FinanceAccount.self, from: data)
    }

    static func transaction(from record: CKRecord) -> FinanceTransaction? {
        guard let data = record["payload"] as? Data else { return nil }
        return try? LegacyFinanceCodec.decode(FinanceTransaction.self, from: data)
    }

    static func budget(from record: CKRecord) -> (month: String, budget: FinanceBudget)? {
        guard let data = record["payload"] as? Data,
              let budget = try? LegacyFinanceCodec.decode(FinanceBudget.self, from: data) else { return nil }
        let month = record["month"] as? String ?? ""
        return (month, budget)
    }

    static func goal(from record: CKRecord) -> FinanceGoal? {
        guard let data = record["payload"] as? Data else { return nil }
        return try? LegacyFinanceCodec.decode(FinanceGoal.self, from: data)
    }

    static func settings(from record: CKRecord) -> FinanceSettings? {
        guard let data = record["payload"] as? Data else { return nil }
        return try? LegacyFinanceCodec.decode(FinanceSettings.self, from: data)
    }
}

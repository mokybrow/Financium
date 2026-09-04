import CloudKit
import Foundation
import SwiftProtobuf

/// Turns the ledger's protobuf messages into `CKRecord`s and back.
///
/// One record type per kind of thing. The message travels whole, in protobuf's
/// wire format, in a single `payload` field — the same bytes the on-device file
/// already stores — so there is one definition of the model, not a CloudKit
/// mirror of it to keep in step. A few fields are lifted out alongside the
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

    static func apply(account: Finance_Account, updatedAt: Date, to record: CKRecord) {
        record["payload"] = (try? account.serializedData()) as CKRecordValue?
        record["updatedAt"] = updatedAt as CKRecordValue
    }

    static func apply(transaction: Finance_Transaction, updatedAt: Date, to record: CKRecord) {
        record["payload"] = (try? transaction.serializedData()) as CKRecordValue?
        record["occurredAt"] = (transaction.hasOccurredAt ? transaction.occurredAt.date : Date()) as CKRecordValue
        record["updatedAt"] = updatedAt as CKRecordValue
    }

    static func apply(budget: Finance_Budget, month: String, updatedAt: Date, to record: CKRecord) {
        record["payload"] = (try? budget.serializedData()) as CKRecordValue?
        record["month"] = month as CKRecordValue
        record["updatedAt"] = updatedAt as CKRecordValue
    }

    static func apply(goal: Finance_Goal, updatedAt: Date, to record: CKRecord) {
        record["payload"] = (try? goal.serializedData()) as CKRecordValue?
        record["updatedAt"] = updatedAt as CKRecordValue
    }

    static func apply(settings: Finance_FinanceSettings, updatedAt: Date, to record: CKRecord) {
        record["payload"] = (try? settings.serializedData()) as CKRecordValue?
        record["updatedAt"] = updatedAt as CKRecordValue
    }

    // MARK: - Decoding

    static func account(from record: CKRecord) -> Finance_Account? {
        guard let data = record["payload"] as? Data else { return nil }
        return try? Finance_Account(serializedBytes: data)
    }

    static func transaction(from record: CKRecord) -> Finance_Transaction? {
        guard let data = record["payload"] as? Data else { return nil }
        return try? Finance_Transaction(serializedBytes: data)
    }

    static func budget(from record: CKRecord) -> (month: String, budget: Finance_Budget)? {
        guard let data = record["payload"] as? Data,
              let budget = try? Finance_Budget(serializedBytes: data) else { return nil }
        let month = record["month"] as? String ?? ""
        return (month, budget)
    }

    static func goal(from record: CKRecord) -> Finance_Goal? {
        guard let data = record["payload"] as? Data else { return nil }
        return try? Finance_Goal(serializedBytes: data)
    }

    static func settings(from record: CKRecord) -> Finance_FinanceSettings? {
        guard let data = record["payload"] as? Data else { return nil }
        return try? Finance_FinanceSettings(serializedBytes: data)
    }
}

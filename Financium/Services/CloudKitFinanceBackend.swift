import Foundation

/// The `FinanceBackend` the store writes through when iCloud sync is on.
///
/// Every read and every write still goes to the on-device file — that is what
/// keeps the app instant and working offline. The only thing added on top is a
/// nudge to `CloudKitSyncCoordinator` after each write, which queues the
/// changed records and lets `CKSyncEngine` push them when it can. Fetched
/// changes come back the other way, straight into the same file.
actor CloudKitFinanceBackend: FinanceBackend {
    private let local: LocalFinanceBackend
    private weak var coordinator: CloudKitSyncCoordinator?

    init(local: LocalFinanceBackend) {
        self.local = local
    }

    func attach(coordinator: CloudKitSyncCoordinator) {
        self.coordinator = coordinator
    }

    private func synced<T>(_ body: () async throws -> T) async rethrows -> T {
        let result = try await body()
        await coordinator?.reconcile()
        return result
    }

    // MARK: Reading

    func load(period: FinancePeriod, monthKey: String) async throws -> FinanceSnapshot {
        try await local.load(period: period, monthKey: monthKey)
    }

    // MARK: Accounts

    func createAccount(name: String, symbol: String, opening: Decimal, currency: String) async throws {
        try await synced { try await local.createAccount(name: name, symbol: symbol, opening: opening, currency: currency) }
    }

    func updateAccount(
        id: String, name: String, symbol: String,
        balance: Decimal?, currency: String, isArchived: Bool
    ) async throws {
        try await synced {
            try await local.updateAccount(
                id: id, name: name, symbol: symbol,
                balance: balance, currency: currency, isArchived: isArchived
            )
        }
    }

    func deleteAccount(id: String, cascade: Bool) async throws {
        try await synced { try await local.deleteAccount(id: id, cascade: cascade) }
    }

    // MARK: Sharing

    func shareAccount(id: String) async throws -> AccountInvite {
        guard let coordinator else { throw FinanceLedger.Failure.invalidArgument }
        return try await coordinator.shareAccount(id: id)
    }

    func joinAccount(code: String) async throws -> Finance_Account {
        // Shared accounts are joined by tapping the iCloud link, which the
        // system routes to the app delegate — not by pasting a code here.
        throw FinanceLedger.Failure.notFound
    }

    func stopSharingAccount(id: String, memberID: String) async throws {
        guard let coordinator else { throw FinanceLedger.Failure.invalidArgument }
        try await coordinator.stopSharingAccount(id: id, memberID: memberID)
    }

    // MARK: Transactions

    func saveTransaction(
        id: String, kind: TransactionEditorKind,
        accountID: String, destinationID: String,
        title: String, category: String,
        amount: Decimal, destinationAmount: Decimal?,
        currency: String, note: String, date: Date
    ) async throws {
        try await synced {
            try await local.saveTransaction(
                id: id, kind: kind, accountID: accountID, destinationID: destinationID,
                title: title, category: category, amount: amount,
                destinationAmount: destinationAmount, currency: currency, note: note, date: date
            )
        }
    }

    func deleteTransaction(id: String) async throws {
        try await synced { try await local.deleteTransaction(id: id) }
    }

    // MARK: Budgets

    func upsertBudget(
        id: String, monthKey: String, title: String, category: String,
        limit: Decimal, currency: String,
        reminder: Bool, paymentDate: Date, recurrence: Finance_BudgetRecurrence
    ) async throws {
        try await synced {
            try await local.upsertBudget(
                id: id, monthKey: monthKey, title: title, category: category,
                limit: limit, currency: currency,
                reminder: reminder, paymentDate: paymentDate, recurrence: recurrence
            )
        }
    }

    func deleteBudget(id: String) async throws {
        try await synced { try await local.deleteBudget(id: id) }
    }

    // MARK: Goals

    func upsertGoal(
        id: String, title: String, accountID: String,
        category: String, target: Decimal, currency: String
    ) async throws {
        try await synced {
            try await local.upsertGoal(
                id: id, title: title, accountID: accountID,
                category: category, target: target, currency: currency
            )
        }
    }

    func deleteGoal(id: String) async throws {
        try await synced { try await local.deleteGoal(id: id) }
    }

    // MARK: Settings

    func updateSettings(
        currency: String, monthlyReminders: Bool, promoEmail: Bool, promoPush: Bool
    ) async throws {
        try await synced {
            try await local.updateSettings(
                currency: currency, monthlyReminders: monthlyReminders,
                promoEmail: promoEmail, promoPush: promoPush
            )
        }
    }
}

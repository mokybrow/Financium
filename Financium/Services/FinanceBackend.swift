import Foundation
import SwiftProtobuf

/// Everything the app reads in one go.
///
/// The screens want a consistent picture — balances that agree with the
/// transactions that produced them — so the backends hand one over rather than
/// letting each screen assemble its own from separate calls.
/// What the owner passes to whoever they are sharing with.
nonisolated struct AccountInvite: Sendable, Equatable {
    /// The code on its own, for reading out or pasting where a link would not
    /// survive.
    let code: String
    /// The same code as something tappable.
    let url: URL?
}

nonisolated struct FinanceSnapshot: Sendable {
    var overview = Finance_GetOverviewResponse()
    var accounts: [Finance_Account] = []
    var transactions: [Finance_Transaction] = []
    var budgets: [Finance_Budget] = []
    var goals: [Finance_Goal] = []
    var settings = Finance_FinanceSettings()
}

/// What the app can do with money, independent of where it is kept.
///
/// The remote implementation talks to `money-service`; the local one keeps a
/// file on the device. `FinanceStore` owns screen state and knows only this
/// protocol, so no view changes between the two modes.
nonisolated protocol FinanceBackend: Sendable {
    func load(period: FinancePeriod, monthKey: String) async throws -> FinanceSnapshot

    func createAccount(name: String, symbol: String, opening: Decimal, currency: String) async throws
    func updateAccount(
        id: String, name: String, symbol: String,
        balance: Decimal?, currency: String, isArchived: Bool
    ) async throws
    func deleteAccount(id: String) async throws

    /// Turns an account into a shared one and returns the invite to pass on.
    ///
    /// Idempotent: asking twice hands back the same invite rather than minting a
    /// second link that also still works.
    func shareAccount(id: String) async throws -> AccountInvite
    /// Redeems an invite, returning the account that was joined.
    func joinAccount(code: String) async throws -> Finance_Account
    /// Empty `memberID` makes the account private again — the owner's to send.
    /// A member id removes that person; a member may pass their own to leave.
    func stopSharingAccount(id: String, memberID: String) async throws

    func saveTransaction(
        id: String, kind: TransactionEditorKind,
        accountID: String, destinationID: String,
        title: String, category: String,
        amount: Decimal, destinationAmount: Decimal?,
        currency: String, note: String, date: Date
    ) async throws
    func deleteTransaction(id: String) async throws

    func upsertBudget(
        id: String, monthKey: String, title: String, category: String,
        limit: Decimal, currency: String,
        reminder: Bool, paymentDate: Date, recurrence: Finance_BudgetRecurrence
    ) async throws
    func deleteBudget(id: String) async throws

    func upsertGoal(
        id: String, title: String, accountID: String,
        category: String, target: Decimal, currency: String
    ) async throws
    func deleteGoal(id: String) async throws

    func updateSettings(
        currency: String, monthlyReminders: Bool, promoEmail: Bool, promoPush: Bool
    ) async throws
}

// MARK: - Local storage

/// The local database, as it sits on disk.
///
/// Messages are stored in protobuf's binary encoding rather than as a bespoke
/// `Codable` mirror: the wire format is already the app's model, and it tolerates
/// fields being added and removed, so a file written by an older build still
/// opens. `Data` encodes as base64 inside the JSON envelope.
private nonisolated struct LocalFinanceFile: Codable {
    var accounts: [Data] = []
    var transactions: [Data] = []
    var budgets: [StoredBudget] = []
    var goals: [Data] = []
    var settings: Data?
}

/// A budget and the month it belongs to.
///
/// `Finance_Budget` carries no month — the service keys budgets by month in the
/// *request*, not on the message — so the local file has to remember it. Kept
/// beside the payload rather than bolted onto the proto, which would change a
/// contract for one side's convenience.
private nonisolated struct StoredBudget: Codable {
    var month: String
    var payload: Data
}

/// The whole local ledger, handed out for migration.
nonisolated struct LocalExport {
    nonisolated struct Budget {
        var month: String
        var budget: Finance_Budget
    }

    var accounts: [Finance_Account] = []
    var transactions: [Finance_Transaction] = []
    var budgets: [Budget] = []
    var goals: [Finance_Goal] = []
    var settings = Finance_FinanceSettings()
}

/// Money kept on the device, with no account and no network.
///
/// An actor because the file is shared mutable state: two screens saving at once
/// must not interleave a read-modify-write and lose one of the writes.
actor LocalFinanceBackend: FinanceBackend {
    private let url: URL

    private var accounts: [Finance_Account] = []
    private var transactions: [Finance_Transaction] = []
    /// Paired with the month each belongs to, which the message itself lacks.
    private var budgets: [(month: String, budget: Finance_Budget)] = []
    private var goals: [Finance_Goal] = []
    private var settings = Finance_FinanceSettings()
    private var loaded = false

    init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL()
    }

    private static func defaultURL() -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("financium-local.json")
    }

    /// True when there is anything worth offering to move to an account.
    var hasData: Bool {
        get async {
            await ensureLoaded()
            return !accounts.isEmpty || !transactions.isEmpty || !budgets.isEmpty || !goals.isEmpty
        }
    }

    /// Everything on the device, for the migration to replay onto an account.
    ///
    /// Budgets come with their months, which `FinanceSnapshot` cannot carry
    /// because `Finance_Budget` has no month of its own.
    func exportAll() async -> LocalExport {
        await ensureLoaded()
        var export = LocalExport()
        export.accounts = accounts
        export.transactions = transactions
        export.budgets = budgets.map { LocalExport.Budget(month: $0.month, budget: $0.budget) }
        export.goals = goals
        export.settings = settings
        return export
    }

    func removeAll() {
        accounts = []
        transactions = []
        budgets = []
        goals = []
        settings = Finance_FinanceSettings()
        // Reset rather than "loaded and empty", so the next read re-applies the
        // device-currency default instead of silently falling back to roubles.
        loaded = false
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Reading

    func load(period: FinancePeriod, monthKey: String) async throws -> FinanceSnapshot {
        await ensureLoaded()

        let interval = period.interval
        var snapshot = FinanceSnapshot()
        snapshot.accounts = accounts.filter { !$0.isArchived }
        snapshot.settings = settings
        snapshot.transactions = transactions
            .filter { transaction in
                guard transaction.hasOccurredAt else { return false }
                let date = transaction.occurredAt.date
                return date >= interval.start && date < interval.end
            }
            .sorted { lhs, rhs in
                lhs.occurredAt.date > rhs.occurredAt.date
            }

        let month = period.anchorMonth
        snapshot.budgets = budgets
            .filter { $0.month == monthKey }
            .map { stored in
                let budget = stored.budget
                var filled = budget
                filled.spent = Finance_Money(
                    minorUnits: FinanceLedger.spent(
                        onCategory: budget.category,
                        month: month,
                        currency: budget.limit.currencyCode,
                        transactions: transactions
                    ),
                    currencyCode: budget.limit.currencyCode
                )
                return filled
            }

        var progressed = goals
        FinanceLedger.applyGoalProgress(to: &progressed, accounts: accounts)
        snapshot.goals = progressed

        let totals = FinanceLedger.currencyTotals(
            mainCurrency: mainCurrency,
            accounts: snapshot.accounts,
            transactions: transactions,
            interval: interval
        )
        var overview = Finance_GetOverviewResponse()
        overview.accounts = snapshot.accounts
        overview.recentTransactions = Array(snapshot.transactions.prefix(50))
        overview.currencies = totals
        if let main = totals.first(where: { $0.currencyCode == mainCurrency }) {
            overview.totalBalance = main.balance
            overview.spent = main.spent
            overview.earned = main.earned
        }
        snapshot.overview = overview
        return snapshot
    }

    // MARK: Accounts

    func createAccount(name: String, symbol: String, opening: Decimal, currency: String) async throws {
        await ensureLoaded()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, FinanceLedger.isISOCurrency(currency.uppercased()) else {
            throw FinanceLedger.Failure.invalidArgument
        }

        var account = Finance_Account()
        account.id = UUID().uuidString
        account.name = trimmed
        account.symbolName = symbol.isEmpty ? "creditcard.fill" : symbol
        account.balance = Finance_Money(decimal: opening, currencyCode: currency)
        accounts.append(account)
        try persist()
    }

    func updateAccount(
        id: String, name: String, symbol: String,
        balance: Decimal?, currency: String, isArchived: Bool
    ) async throws {
        await ensureLoaded()
        guard let index = accounts.firstIndex(where: { $0.id == id }) else {
            throw FinanceLedger.Failure.notFound
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FinanceLedger.Failure.invalidArgument }

        accounts[index].name = trimmed
        accounts[index].symbolName = symbol.isEmpty ? "creditcard.fill" : symbol
        accounts[index].isArchived = isArchived
        // An unset balance means "leave the money alone", matching the service:
        // a rename must not be able to reset a balance to zero.
        if let balance {
            guard FinanceLedger.isISOCurrency(currency.uppercased()) else {
                throw FinanceLedger.Failure.invalidArgument
            }
            accounts[index].balance = Finance_Money(decimal: balance, currencyCode: currency)
        }
        try persist()
    }

    func deleteAccount(id: String) async throws {
        await ensureLoaded()
        guard accounts.contains(where: { $0.id == id }) else { throw FinanceLedger.Failure.notFound }
        guard !transactions.contains(where: { $0.fromAccountID == id || $0.toAccountID == id }) else {
            throw FinanceLedger.Failure.accountHasTransactions
        }
        accounts.removeAll { $0.id == id }
        try persist()
    }

    // MARK: Sharing

    /// Refused, not faked.
    ///
    /// A shared account is two people looking at one ledger, and the local mode
    /// has no second person and nowhere to put them. Returning an invite that
    /// could never be redeemed would be a worse answer than saying no.
    func shareAccount(id: String) async throws -> AccountInvite {
        throw FinanceLedger.Failure.invalidArgument
    }

    func joinAccount(code: String) async throws -> Finance_Account {
        throw FinanceLedger.Failure.invalidArgument
    }

    func stopSharingAccount(id: String, memberID: String) async throws {
        throw FinanceLedger.Failure.invalidArgument
    }

    // MARK: Transactions

    func saveTransaction(
        id: String, kind: TransactionEditorKind,
        accountID: String, destinationID: String,
        title: String, category: String,
        amount: Decimal, destinationAmount: Decimal?,
        currency: String, note: String, date: Date
    ) async throws {
        await ensureLoaded()

        var transaction = Finance_Transaction()
        transaction.id = id.isEmpty ? UUID().uuidString : id
        transaction.kind = kind.proto
        if kind == .income {
            transaction.toAccountID = accountID
        } else {
            transaction.fromAccountID = accountID
        }
        if kind == .transfer { transaction.toAccountID = destinationID }
        transaction.title = title
        transaction.category = category
        transaction.note = note
        transaction.amount = Finance_Money(decimal: amount, currencyCode: currency)
        let destinationCurrency = accounts.first { $0.id == destinationID }?.balance.currencyCode ?? currency
        transaction.destinationAmount = Finance_Money(
            decimal: destinationAmount ?? amount,
            currencyCode: destinationCurrency
        )
        transaction.occurredAt = Google_Protobuf_Timestamp(date: date)

        try FinanceLedger.validate(transaction)

        // Editing is "take back the old, post the new" — the same two steps the
        // service runs in one database transaction, so an edited amount is not
        // counted twice.
        if let index = transactions.firstIndex(where: { $0.id == transaction.id }) {
            FinanceLedger.applyBalance(of: transactions[index], direction: -1, to: &accounts)
            transactions[index] = transaction
        } else {
            transactions.append(transaction)
        }
        FinanceLedger.applyBalance(of: transaction, direction: 1, to: &accounts)
        try persist()
    }

    func deleteTransaction(id: String) async throws {
        await ensureLoaded()
        guard let index = transactions.firstIndex(where: { $0.id == id }) else {
            throw FinanceLedger.Failure.notFound
        }
        FinanceLedger.applyBalance(of: transactions[index], direction: -1, to: &accounts)
        transactions.remove(at: index)
        try persist()
    }

    // MARK: Budgets

    func upsertBudget(
        id: String, monthKey: String, title: String, category: String,
        limit: Decimal, currency: String,
        reminder: Bool, paymentDate: Date, recurrence: Finance_BudgetRecurrence
    ) async throws {
        await ensureLoaded()
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !category.isEmpty, limit > 0 else {
            throw FinanceLedger.Failure.invalidArgument
        }

        // One budget per category per month, refused rather than folded into the
        // existing row — spend is attributed by category, so two budgets on one
        // category would track the same money.
        let clash = budgets.contains {
            $0.budget.id != id && $0.month == monthKey && $0.budget.category == category
        }
        guard !clash else { throw FinanceLedger.Failure.conflict }

        var budget = Finance_Budget()
        budget.id = id.isEmpty ? UUID().uuidString : id
        budget.title = trimmedTitle
        budget.category = category
        budget.limit = Finance_Money(decimal: limit, currencyCode: currency)
        budget.reminderEnabled = reminder
        if reminder {
            budget.paymentDate = Self.dateKey(paymentDate)
            budget.recurrence = recurrence
        } else {
            budget.recurrence = .once
        }

        if let index = budgets.firstIndex(where: { $0.budget.id == budget.id }) {
            budgets[index] = (month: monthKey, budget: budget)
        } else {
            budgets.append((month: monthKey, budget: budget))
        }
        try persist()
    }

    func deleteBudget(id: String) async throws {
        await ensureLoaded()
        budgets.removeAll { $0.budget.id == id }
        try persist()
    }

    // MARK: Goals

    func upsertGoal(
        id: String, title: String, accountID: String,
        category: String, target: Decimal, currency: String
    ) async throws {
        await ensureLoaded()
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, target > 0 else { throw FinanceLedger.Failure.invalidArgument }
        guard let account = accounts.first(where: { $0.id == accountID }) else {
            throw FinanceLedger.Failure.notFound
        }

        var goal = Finance_Goal()
        goal.id = id.isEmpty ? UUID().uuidString : id
        goal.title = trimmedTitle
        goal.accountID = accountID
        goal.category = category
        // The account decides the currency, as it does on the service: a goal is
        // denominated in the account it is saved into.
        goal.target = Finance_Money(decimal: target, currencyCode: account.balance.currencyCode)

        if let index = goals.firstIndex(where: { $0.id == goal.id }) {
            goals[index] = goal
        } else {
            goals.append(goal)
        }
        try persist()
    }

    func deleteGoal(id: String) async throws {
        await ensureLoaded()
        goals.removeAll { $0.id == id }
        try persist()
    }

    // MARK: Settings

    func updateSettings(
        currency: String, monthlyReminders: Bool, promoEmail: Bool, promoPush: Bool
    ) async throws {
        await ensureLoaded()
        let code = currency.uppercased()
        guard FinanceLedger.isISOCurrency(code) else { throw FinanceLedger.Failure.invalidArgument }
        settings.mainCurrencyCode = code
        settings.monthlyRemindersEnabled = monthlyReminders
        settings.promoEmailEnabled = promoEmail
        settings.promoPushEnabled = promoPush
        try persist()
    }

    // MARK: Persistence

    private var mainCurrency: String {
        settings.mainCurrencyCode.isEmpty ? "RUB" : settings.mainCurrencyCode
    }

    private static func dateKey(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private func ensureLoaded() async {
        guard !loaded else { return }
        loaded = true

        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(LocalFinanceFile.self, from: data) else {
            settings.mainCurrencyCode = Self.deviceCurrency()
            return
        }
        accounts = file.accounts.compactMap { try? Finance_Account(serializedBytes: $0) }
        transactions = file.transactions.compactMap { try? Finance_Transaction(serializedBytes: $0) }
        budgets = file.budgets.compactMap { stored in
            guard let budget = try? Finance_Budget(serializedBytes: stored.payload) else { return nil }
            return (month: stored.month, budget: budget)
        }
        goals = file.goals.compactMap { try? Finance_Goal(serializedBytes: $0) }
        if let raw = file.settings, let stored = try? Finance_FinanceSettings(serializedBytes: raw) {
            settings = stored
        }
        if settings.mainCurrencyCode.isEmpty {
            settings.mainCurrencyCode = Self.deviceCurrency()
        }
    }

    /// A first-run default worth having: the phone's own currency beats making
    /// everyone change it from roubles.
    private static func deviceCurrency() -> String {
        let code = Locale.current.currency?.identifier.uppercased() ?? "RUB"
        return FinanceLedger.isISOCurrency(code) ? code : "RUB"
    }

    private func persist() throws {
        var file = LocalFinanceFile()
        file.accounts = accounts.compactMap { try? $0.serializedData() }
        file.transactions = transactions.compactMap { try? $0.serializedData() }
        file.budgets = budgets.compactMap { stored in
            guard let payload = try? stored.budget.serializedData() else { return nil }
            return StoredBudget(month: stored.month, payload: payload)
        }
        file.goals = goals.compactMap { try? $0.serializedData() }
        file.settings = try? settings.serializedData()

        let data = try JSONEncoder().encode(file)
        // Atomic: a crash mid-write must not leave a half-written ledger.
        try data.write(to: url, options: .atomic)
    }
}

import Foundation
import os

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
    var overview = FinanceOverview()
    var accounts: [FinanceAccount] = []
    var transactions: [FinanceTransaction] = []
    var budgets: [FinanceBudget] = []
    var goals: [FinanceGoal] = []
    var settings = FinanceSettings()
}

/// What the app can do with money, independent of where it is kept.
///
/// The iCloud implementation mirrors the same local file to CloudKit.
/// `FinanceStore` owns screen state and knows only this protocol, so no view
/// changes between the two modes.
nonisolated protocol FinanceBackend: Sendable {
    func load(period: FinancePeriod, monthKey: String) async throws -> FinanceSnapshot

    func createAccount(name: String, symbol: String, opening: Decimal, currency: String, appearance: FinanceAccountAppearance?) async throws
    func updateAccount(
        id: String, name: String, symbol: String,
        balance: Decimal?, currency: String, isArchived: Bool, appearance: FinanceAccountAppearance?
    ) async throws
    /// `cascade` also removes every transaction touching the account instead of
    /// refusing the delete — for an account whose history nobody needs kept,
    /// chiefly one left behind by the retired backend.
    func deleteAccount(id: String, cascade: Bool) async throws

    /// Turns an account into a shared one and returns the invite to pass on.
    ///
    /// Idempotent: asking twice hands back the same invite rather than minting a
    /// second link that also still works.
    func shareAccount(id: String) async throws -> AccountInvite
    /// Redeems an invite, returning the account that was joined.
    func joinAccount(code: String) async throws -> FinanceAccount
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
        reminder: Bool, paymentDate: Date, recurrence: FinanceBudgetRecurrence, accountID: String, coverJSON: String?
    ) async throws
    func deleteBudget(id: String) async throws

    func upsertGoal(
        id: String, title: String, accountID: String,
        category: String, target: Decimal, currency: String, coverJSON: String?
    ) async throws
    func deleteGoal(id: String) async throws

    func updateSettings(
        currency: String, monthlyReminders: Bool, promoEmail: Bool, promoPush: Bool
    ) async throws
}

// MARK: - Local storage

/// Every entity in the ledger, unfiltered, for the CloudKit sync engine to
/// mirror and merge. Unlike `FinanceSnapshot` this is not scoped to a period
/// and keeps budgets paired with their months.
nonisolated struct RawLedger: Sendable {
    var accounts: [FinanceAccount] = []
    var transactions: [FinanceTransaction] = []
    var budgets: [(month: String, budget: FinanceBudget)] = []
    var goals: [FinanceGoal] = []
    var settings = FinanceSettings()
}

/// The whole local ledger, handed out for migration.
nonisolated struct LocalExport {
    nonisolated struct Budget {
        var month: String
        var budget: FinanceBudget
    }

    var accounts: [FinanceAccount] = []
    var transactions: [FinanceTransaction] = []
    var budgets: [Budget] = []
    var goals: [FinanceGoal] = []
    var settings = FinanceSettings()
}

/// Money kept on the device, with no account and no network.
///
/// An actor because the file is shared mutable state: two screens saving at once
/// must not interleave a read-modify-write and lose one of the writes.
actor LocalFinanceBackend: FinanceBackend {
    private let url: URL

    private var accounts: [FinanceAccount] = []
    private var transactions: [FinanceTransaction] = []
    /// Paired with the month each belongs to, which the message itself lacks.
    private var budgets: [(month: String, budget: FinanceBudget)] = []
    private var goals: [FinanceGoal] = []
    private var settings = FinanceSettings()
    private var loaded = false
    /// The reader's own iCloud user-record name, for folding shared-plan
    /// contributions. Empty until an iCloud account is known.
    private var selfUserID = ""

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
        get async throws {
            try await ensureLoaded()
            return !accounts.isEmpty || !transactions.isEmpty || !budgets.isEmpty || !goals.isEmpty
        }
    }

    /// Everything on the device, for the migration to replay onto an account.
    ///
    /// Budgets come with their months, which `FinanceSnapshot` cannot carry
    /// because `FinanceBudget` has no month of its own.
    func exportAll() async throws -> LocalExport {
        try await ensureLoaded()
        var export = LocalExport()
        export.accounts = accounts
        export.transactions = transactions
        export.budgets = budgets.map { LocalExport.Budget(month: $0.month, budget: $0.budget) }
        export.goals = goals
        export.settings = settings
        return export
    }

    // MARK: CloudKit sync bridge

    /// Every entity as it sits in the file, for the sync engine to turn into
    /// records.
    func rawLedger() async throws -> RawLedger {
        try await ensureLoaded()
        var raw = RawLedger()
        raw.accounts = accounts
        raw.transactions = transactions
        raw.budgets = budgets
        raw.goals = goals
        raw.settings = settings
        return raw
    }

    /// Merges what CloudKit fetched into the file.
    ///
    /// Entities are replaced whole by id — the record from the server is
    /// authoritative, balances included, so nothing is recomputed here. Ids in
    /// `deleted` are removed. This never enqueues anything back to the sync
    /// engine; the caller reconciles after applying.
    func applyRemote(
        accounts remoteAccounts: [FinanceAccount],
        transactions remoteTransactions: [FinanceTransaction],
        budgets remoteBudgets: [(month: String, budget: FinanceBudget)],
        goals remoteGoals: [FinanceGoal],
        settings remoteSettings: FinanceSettings?,
        deleted: Set<String>
    ) async {
        do { try await ensureLoaded() }
        catch {
            FinanceLog.store.error("local ledger load failed: \(FinanceLog.describe(error), privacy: .public)")
            return
        }

        func upsert<T>(_ list: inout [T], _ incoming: [T], id: (T) -> String) {
            for item in incoming {
                if let index = list.firstIndex(where: { id($0) == id(item) }) {
                    list[index] = item
                } else {
                    list.append(item)
                }
            }
        }

        upsert(&accounts, remoteAccounts) { $0.id }
        upsert(&transactions, remoteTransactions) { $0.id }
        upsert(&goals, remoteGoals) { $0.id }
        for incoming in remoteBudgets {
            if let index = budgets.firstIndex(where: { $0.budget.id == incoming.budget.id }) {
                budgets[index] = incoming
            } else {
                budgets.append(incoming)
            }
        }
        if let remoteSettings { settings = remoteSettings }

        if !deleted.isEmpty {
            accounts.removeAll { deleted.contains($0.id) }
            transactions.removeAll { deleted.contains($0.id) }
            budgets.removeAll { deleted.contains($0.budget.id) }
            goals.removeAll { deleted.contains($0.id) }
        }

        try? persist()
    }

    /// Stamps sharing state onto an account record so the existing badge and
    /// owner checks keep working. Set by the sync coordinator when a `CKShare`
    /// is created, accepted, or removed — not something a screen calls.
    func setSharing(accountID: String, ownerUserID: String, memberCount: Int32) async {
        do { try await ensureLoaded() }
        catch {
            FinanceLog.store.error("local ledger load failed: \(FinanceLog.describe(error), privacy: .public)")
            return
        }
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        accounts[index].ownerUserID = ownerUserID
        accounts[index].memberCount = memberCount
        try? persist()
    }

    func removeAll() {
        accounts = []
        transactions = []
        budgets = []
        goals = []
        settings = FinanceSettings()
        // Reset rather than "loaded and empty", so the next read re-applies the
        // device-currency default instead of silently falling back to roubles.
        loaded = false
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Reading

    func load(period: FinancePeriod, monthKey: String) async throws -> FinanceSnapshot {
        try await ensureLoaded()
        return FinanceLedger.snapshot(
            period: period,
            monthKey: monthKey,
            accounts: accounts,
            transactions: transactions,
            budgets: budgets,
            goals: goals,
            settings: settings,
            selfUserID: selfUserID
        )
    }

    func installSharedPlan(budget: FinanceBudget?, month: String, goal: FinanceGoal?) async throws {
        try await ensureLoaded()
        if let budget {
            if let index = budgets.firstIndex(where: { $0.budget.id == budget.id }) {
                if budgets[index].month == month && budgets[index].budget == budget { return }
                budgets[index] = (month, budget)
            }
            else { budgets.append((month, budget)) }
        }
        if let goal {
            if let index = goals.firstIndex(where: { $0.id == goal.id }) {
                if goals[index] == goal { return }
                goals[index] = goal
            }
            else { goals.append(goal) }
        }
        try persist()
    }

    func clearSharedPlan(key: String, remove: Bool) async throws {
        try await ensureLoaded()
        let id = String(key.dropFirst(key.hasPrefix("budget:") ? 7 : 5))
        if key.hasPrefix("budget:") {
            if remove { budgets.removeAll { $0.budget.id == id } }
            else if let index = budgets.firstIndex(where: { $0.budget.id == id }) { budgets[index].budget.collaborationJSON = "" }
        } else {
            if remove { goals.removeAll { $0.id == id } }
            else if let index = goals.firstIndex(where: { $0.id == id }) { goals[index].collaborationJSON = "" }
        }
        try persist()
    }

    func bindSharedPlan(key: String, accountID: String, category: String?) async throws {
        try await ensureLoaded()
        let id = String(key.dropFirst(key.hasPrefix("budget:") ? 7 : 5))
        let account = accounts.first { $0.id == accountID && !$0.isArchived }
        if key.hasPrefix("budget:") {
            guard let index = budgets.firstIndex(where: { $0.budget.id == id }),
                  let account, account.balance.currencyCode == budgets[index].budget.limit.currencyCode else { throw FinanceLedger.Failure.invalidArgument }
            budgets[index].budget.accountID = accountID
            if let category, !category.isEmpty { budgets[index].budget.category = category }
        } else {
            guard let index = goals.firstIndex(where: { $0.id == id }),
                  let account, account.balance.currencyCode == goals[index].target.currencyCode else { throw FinanceLedger.Failure.invalidArgument }
            goals[index].accountID = accountID
        }
        try persist()
    }

    /// Set by `FinanceStore` once the iCloud account resolves.
    func setSelfUserID(_ id: String) { selfUserID = id }

    // MARK: Accounts

    func createAccount(name: String, symbol: String, opening: Decimal, currency: String, appearance: FinanceAccountAppearance?) async throws {
        try await ensureLoaded()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, FinanceLedger.isISOCurrency(currency.uppercased()) else {
            throw FinanceLedger.Failure.invalidArgument
        }

        var account = FinanceAccount()
        account.id = UUID().uuidString
        account.name = trimmed
        account.symbolName = symbol.isEmpty ? "creditcard.fill" : symbol
        account.balance = FinanceMoney(decimal: opening, currencyCode: currency)
        if let appearance {
            account.colorID = appearance.colorID
            account.accountType = appearance.accountType
            account.annualRateBasisPoints = appearance.annualRateBasisPoints
        }
        accounts.append(account)
        try persist()
    }

    func updateAccount(
        id: String, name: String, symbol: String,
        balance: Decimal?, currency: String, isArchived: Bool, appearance: FinanceAccountAppearance?
    ) async throws {
        try await ensureLoaded()
        guard let index = accounts.firstIndex(where: { $0.id == id }) else {
            throw FinanceLedger.Failure.notFound
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FinanceLedger.Failure.invalidArgument }

        accounts[index].name = trimmed
        accounts[index].symbolName = symbol.isEmpty ? "creditcard.fill" : symbol
        accounts[index].isArchived = isArchived
        if let appearance {
            accounts[index].colorID = appearance.colorID
            accounts[index].accountType = appearance.accountType
            accounts[index].annualRateBasisPoints = appearance.annualRateBasisPoints
        }
        // An unset balance means "leave the money alone", matching the service:
        // a rename must not be able to reset a balance to zero.
        if let balance {
            guard FinanceLedger.isISOCurrency(currency.uppercased()) else {
                throw FinanceLedger.Failure.invalidArgument
            }
            accounts[index].balance = FinanceMoney(decimal: balance, currencyCode: currency)
        }
        try persist()
    }

    func deleteAccount(id: String, cascade: Bool) async throws {
        try await ensureLoaded()
        guard accounts.contains(where: { $0.id == id }) else { throw FinanceLedger.Failure.notFound }
        let touching = transactions.filter { $0.fromAccountID == id || $0.toAccountID == id }
        guard touching.isEmpty || cascade else { throw FinanceLedger.Failure.accountHasTransactions }

        // Reverse each transaction's effect before dropping it — a transfer out
        // of this account also touches whatever it went to, and that other
        // account's balance must not be left holding money that arrived from a
        // transaction which no longer exists.
        for transaction in touching {
            FinanceLedger.applyBalance(of: transaction, direction: -1, to: &accounts)
        }
        transactions.removeAll { $0.fromAccountID == id || $0.toAccountID == id }
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

    func joinAccount(code: String) async throws -> FinanceAccount {
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
        try await ensureLoaded()

        var transaction = FinanceTransaction()
        transaction.id = id.isEmpty ? UUID().uuidString : id
        transaction.kind = kind.transactionKind
        if kind == .income {
            transaction.toAccountID = accountID
        } else {
            transaction.fromAccountID = accountID
        }
        if kind == .transfer { transaction.toAccountID = destinationID }
        transaction.title = title
        transaction.category = category
        transaction.note = note
        transaction.amount = FinanceMoney(decimal: amount, currencyCode: currency)
        let destinationCurrency = accounts.first { $0.id == destinationID }?.balance.currencyCode ?? currency
        transaction.destinationAmount = FinanceMoney(
            decimal: destinationAmount ?? amount,
            currencyCode: destinationCurrency
        )
        transaction.occurredAt = FinanceTimestamp(date: date)

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
        try await ensureLoaded()
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
        reminder: Bool, paymentDate: Date, recurrence: FinanceBudgetRecurrence, accountID: String, coverJSON: String? = nil
    ) async throws {
        try await ensureLoaded()
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !category.isEmpty, limit > 0 else {
            throw FinanceLedger.Failure.invalidArgument
        }

        // Budgets are independent by id, even within the same category and
        // month. Each compares that category's spend against its own limit.
        var budget = budgets.first(where: { $0.budget.id == id })?.budget ?? FinanceBudget()
        budget.id = id.isEmpty ? UUID().uuidString : id
        if let coverJSON { budget.coverJSON = coverJSON }
        budget.title = trimmedTitle
        guard accountID.isEmpty || accounts.contains(where: { $0.id == accountID }) else {
            throw FinanceLedger.Failure.notFound
        }
        budget.accountID = accountID
        budget.category = category
        budget.limit = FinanceMoney(decimal: limit, currencyCode: currency)
        budget.reminderEnabled = reminder
        if reminder {
            budget.paymentDate = Self.dateKey(paymentDate)
            budget.recurrence = recurrence
        } else {
            budget.paymentDate = ""
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
        try await ensureLoaded()
        budgets.removeAll { $0.budget.id == id }
        try persist()
    }

    // MARK: Goals

    func upsertGoal(
        id: String, title: String, accountID: String,
        category: String, target: Decimal, currency: String, coverJSON: String? = nil
    ) async throws {
        try await ensureLoaded()
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, target > 0 else { throw FinanceLedger.Failure.invalidArgument }
        let account = accounts.first(where: { $0.id == accountID })
        guard accountID.isEmpty || account != nil else { throw FinanceLedger.Failure.notFound }
        guard FinanceLedger.isISOCurrency(currency) else { throw FinanceLedger.Failure.invalidArgument }

        var goal = goals.first(where: { $0.id == id }) ?? FinanceGoal()
        goal.id = id.isEmpty ? UUID().uuidString : id
        if let coverJSON { goal.coverJSON = coverJSON }
        goal.title = trimmedTitle
        goal.accountID = accountID
        goal.category = category
        // A linked account determines the currency. An all-account goal keeps
        // the explicitly selected currency and sums only matching accounts.
        goal.target = FinanceMoney(decimal: target, currencyCode: account?.balance.currencyCode ?? currency)

        if let index = goals.firstIndex(where: { $0.id == goal.id }) {
            goals[index] = goal
        } else {
            goals.append(goal)
        }
        try persist()
    }

    func deleteGoal(id: String) async throws {
        try await ensureLoaded()
        goals.removeAll { $0.id == id }
        try persist()
    }

    // MARK: Settings

    func updateSettings(
        currency: String, monthlyReminders: Bool, promoEmail: Bool, promoPush: Bool
    ) async throws {
        try await ensureLoaded()
        let code = currency.uppercased()
        guard FinanceLedger.isISOCurrency(code) else { throw FinanceLedger.Failure.invalidArgument }
        settings.mainCurrencyCode = code
        settings.monthlyRemindersEnabled = monthlyReminders
        settings.promoEmailEnabled = promoEmail
        settings.promoPushEnabled = promoPush
        try persist()
    }

    // MARK: Persistence

    private static func dateKey(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private func ensureLoaded() async throws {
        guard !loaded else { return }
        let archive: FinanceArchive
        if let saved = try FinanceArchive.load(from: url) {
            archive = saved
        } else {
            let cacheURL = url.deletingLastPathComponent().appendingPathComponent("finance-cache-v1.json")
            if let recovered = try FinanceArchive.recoverCache(from: cacheURL) {
                // The old cache remains intact; only the new local archive is written.
                try recovered.encoded().write(to: url, options: .atomic)
                archive = recovered
            } else {
                archive = FinanceArchive()
            }
        }
        accounts = archive.accounts
        transactions = archive.transactions
        budgets = archive.budgets.map { (month: $0.month, budget: $0.budget) }
        goals = archive.goals
        settings = archive.settings
        if settings.mainCurrencyCode.isEmpty { settings.mainCurrencyCode = Self.deviceCurrency() }
        loaded = true
    }

    /// A first-run default worth having: the phone's own currency beats making
    /// everyone change it from roubles.
    private static func deviceCurrency() -> String {
        let code = Locale.current.currency?.identifier.uppercased() ?? "RUB"
        return FinanceLedger.isISOCurrency(code) ? code : "RUB"
    }

    private func persist() throws {
        var archive = FinanceArchive()
        archive.accounts = accounts
        archive.transactions = transactions
        archive.budgets = budgets.map { FinanceArchive.Budget(month: $0.month, budget: $0.budget) }
        archive.goals = goals
        archive.settings = settings
        try archive.encoded().write(to: url, options: .atomic)
    }
}

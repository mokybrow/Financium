import Combine
import Foundation
import os
import GRPCCore
import SwiftProtobuf

/// How the app is being used.
///
/// Local mode is not a degraded account: everything works, it is just kept on
/// the device and computed there. The distinction the app cares about is which
/// backend to talk to and what Profile should offer.
enum FinanceMode: Equatable {
    case account
    case local
}

/// Screen state, and one backend behind it.
///
/// The store used to make the gRPC calls itself. Splitting the calls out means
/// working without an account changed one line here instead of every screen.
@MainActor
final class FinanceStore: ObservableObject {
    @Published private(set) var overview = Finance_GetOverviewResponse()
    @Published private(set) var accounts: [Finance_Account] = []
    @Published private(set) var transactions: [Finance_Transaction] = []
    @Published private(set) var budgets: [Finance_Budget] = []
    @Published private(set) var goals: [Finance_Goal] = []
    @Published private(set) var settings = Finance_FinanceSettings()
    @Published private(set) var isLoading = false

    /// Whether the backend has answered at least once this session.
    ///
    /// "No accounts yet" is an answer, and screens should not give it before one
    /// is known. `isLoading` cannot stand in for this: it also goes up on
    /// pull-to-refresh and after every edit, which would make an empty state
    /// blink out and back for a reader who genuinely has no accounts.
    @Published private(set) var hasLoaded = false
    @Published var errorMessage: String?

    /// Why the last load failed, or nil.
    ///
    /// Separate from `errorMessage` because that one belongs to the alert and
    /// is cleared the moment it is dismissed. A screen that has nothing to show
    /// still needs to know why after the alert has gone, or it goes back to
    /// looking like an empty account.
    @Published private(set) var loadFailure: String?

    /// The window every screen is looking at.
    ///
    /// A period rather than a month, because the picker offers an arbitrary
    /// range. Budgets stay monthly — there is no such thing as a budget for
    /// "3–17 April" — so they follow `period.anchorMonth`.
    @Published var period: FinancePeriod = .currentMonth

    /// Which currency's figures the Money screen is showing.
    ///
    /// A view filter, not a setting: picking one here changes what is on screen
    /// and nothing else. An earlier version of this control wrote straight to
    /// `mainCurrencyCode`, so glancing at another currency silently
    /// re-denominated the whole app.
    @Published var displayCurrency = ""

    @Published private(set) var mode: FinanceMode = .local

    private let auth: AuthSession
    private let local: LocalFinanceBackend
    private var backend: any FinanceBackend
    private let reminders = BudgetReminders()
    private let cache: FinanceCache
    private var cacheWrite: Task<Void, Never>?

    /// The read currently in flight, so overlapping callers share it.
    private var refreshTask: Task<Void, Never>?

    init(
        auth: AuthSession,
        local: LocalFinanceBackend = LocalFinanceBackend(),
        cache: FinanceCache = FinanceCache()
    ) {
        self.auth = auth
        self.local = local
        self.cache = cache
        self.mode = auth.isAuthenticated ? .account : .local
        self.backend = auth.isAuthenticated
            ? RemoteFinanceBackend(auth: auth)
            : local

        // Read here rather than in a task, so the first frame the reader sees
        // already has their accounts on it instead of an empty screen that
        // fills in a moment later.
        if auth.isAuthenticated { restoreCache() }
    }

    /// Puts the last known figures on screen while the real ones are fetched.
    ///
    /// Whole months only. `monthKey` collapses any window to the month it starts
    /// in, so a snapshot taken while the reader had narrowed the period to 3–17
    /// April would be restored as though it were the whole of April — real
    /// figures answering a question nobody asked.
    private func restoreCache() {
        guard case .month = period, let snapshot = cache.load(monthKey: monthKey) else { return }
        apply(snapshot)
    }

    private func apply(_ snapshot: FinanceSnapshot) {
        overview = snapshot.overview
        accounts = snapshot.accounts
        transactions = snapshot.transactions
        budgets = snapshot.budgets
        goals = snapshot.goals
        settings = snapshot.settings
    }

    /// Points the store at the backend the session now calls for, and clears
    /// what the previous one had loaded so no figure from the old mode survives
    /// into the new one.
    func adopt(mode: FinanceMode) {
        guard mode != self.mode else { return }
        self.mode = mode
        backend = mode == .account ? RemoteFinanceBackend(auth: auth) : local

        overview = Finance_GetOverviewResponse()
        accounts = []
        transactions = []
        budgets = []
        goals = []
        settings = Finance_FinanceSettings()
        displayCurrency = ""

        // Leaving the account's balances on disk would put them back on screen
        // for whoever opens the app next. The in-flight write goes first, or it
        // would land after the file was removed and write them out again.
        if mode == .local {
            cacheWrite?.cancel()
            cacheWrite = nil
            cache.clear()
        }
        hasLoaded = false
        loadFailure = nil
    }

    /// The local ledger, for the sign-in migration to read and clear.
    var localBackend: LocalFinanceBackend { local }

    // MARK: - Derived state

    /// The one currency the app works in, set in Profile.
    var mainCurrencyCode: String {
        let code = settings.mainCurrencyCode.trimmingCharacters(in: .whitespaces)
        return code.isEmpty ? "RUB" : code.uppercased()
    }

    /// Falls back to the main currency when the chosen one is no longer on
    /// offer — deleting the last account in it would otherwise leave the screen
    /// showing zeros, with the picker hidden because only one choice remains.
    var effectiveDisplayCurrency: String {
        displayCurrencyChoices.contains(displayCurrency) ? displayCurrency : mainCurrencyCode
    }

    /// The currencies worth offering: the main one, plus whatever the user
    /// actually holds an account in. Not the full ISO list — this picks between
    /// figures that exist, and a currency with no account has none.
    var displayCurrencyChoices: [String] {
        var codes = Set(accounts.map { $0.balance.currencyCode.uppercased() })
        codes.remove("")
        codes.insert(mainCurrencyCode)
        return codes.sorted { lhs, rhs in
            if (lhs == mainCurrencyCode) != (rhs == mainCurrencyCode) { return lhs == mainCurrencyCode }
            return lhs < rhs
        }
    }

    /// This period's totals in one currency, zeroed rather than absent when the
    /// user has moved nothing in it — a blank row reads as a fault, "0" reads
    /// as an answer.
    func totals(for code: String) -> Finance_CurrencyTotal {
        if let match = overview.currencies.first(where: { $0.currencyCode.caseInsensitiveCompare(code) == .orderedSame }) {
            return match
        }
        var empty = Finance_CurrencyTotal()
        empty.currencyCode = code
        empty.balance = Finance_Money(decimal: 0, currencyCode: code)
        empty.spent = Finance_Money(decimal: 0, currencyCode: code)
        empty.earned = Finance_Money(decimal: 0, currencyCode: code)
        return empty
    }

    /// The month budgets are read and written for: the one the period starts in.
    var monthKey: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: period.anchorMonth)
    }

    // MARK: - Reading

    /// Re-reads everything, one refresh at a time.
    ///
    /// Four separate things ask for this — the screen appearing, the scene
    /// becoming active, the shared-account poll, and the end of every write —
    /// and they routinely overlap. Overlapping was not merely wasteful: when
    /// one of those callers went away its task was cancelled, `withGRPCClient`
    /// tore its connection down, and the request in flight came back
    /// `clientIsStopped`. Joining the one already running answers every caller
    /// from a single read and removes the overlap that produced it.
    func refresh() async {
        if let inFlight = refreshTask {
            await inFlight.value
            return
        }
        let task = Task { await performRefresh() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh() async {
        if mode == .account, !auth.isAuthenticated { return }
        isLoading = true
        defer { isLoading = false }
        do {
            // Both read before the await, so a period changed mid-flight cannot
            // file the answer under the wrong window.
            let key = monthKey
            let isWholeMonth: Bool = if case .month = period { true } else { false }

            let snapshot = try await backend.load(period: period, monthKey: key)
            apply(snapshot)
            hasLoaded = true
            errorMessage = nil
            loadFailure = nil

            // Only the account mode is cached: local mode's file is the ledger
            // itself, so a copy of it would be a copy of the original. And only
            // whole months, because that is all the key can describe.
            //
            // Off the main actor: serialising a month of transactions and
            // writing them is a synchronous stretch of work, and `refresh()` is
            // what every edit ends with — so on the main actor it would be a
            // hitch after every add, edit and delete.
            if mode == .account, isWholeMonth {
                let cache = cache
                // Held so signing out can cancel it. Without that, a write still
                // queued when the session ends puts the previous account's
                // balances back on disk after they were cleared.
                cacheWrite?.cancel()
                cacheWrite = Task.detached(priority: .utility) {
                    guard !Task.isCancelled else { return }
                    cache.save(snapshot, monthKey: key)
                }
            }

            // Rescheduled from whatever was just loaded, so a budget edited on
            // another device — or deleted — cannot leave a reminder behind.
            await reminders.reschedule(
                budgets: snapshot.budgets,
                enabled: snapshot.settings.monthlyRemindersEnabled
            )
        } catch {
            // Logged before it is translated. What the reader is shown is a
            // sentence they can act on; what is kept here is the thing that
            // says why, including the cases the mapping collapses into
            // "something went wrong".
            let detail = FinanceLog.describe(error)

            // A refresh that was called off is not a refresh that failed.
            // Cancellation happens constantly and by design — leaving a screen,
            // backgrounding the app, stopping the shared-account poll — and the
            // gRPC client reports it as `clientIsStopped`, which reads like a
            // fault and was being shown as one. Nothing is wrong, and the state
            // from the last real answer stays as it was.
            guard !Self.wasCancelled(error) else {
                FinanceLog.store.debug("refresh cancelled: \(detail, privacy: .public)")
                return
            }

            FinanceLog.store.error("refresh failed: \(detail, privacy: .public)")
            let message = Self.message(for: error)
            errorMessage = message
            loadFailure = message
        }
    }

    /// Whether an error means "nobody is waiting for this any more".
    ///
    /// `clientIsStopped` is matched on its text because grpc-swift reports a
    /// cancelled call that way: the surrounding task is cancelled, the client
    /// it was using shuts down, and the request that was in flight is told the
    /// client is gone. There is no typed case to check for, and mistaking it
    /// for a real failure is what put "something went wrong" on screen after
    /// an ordinary screen change.
    private static func wasCancelled(_ error: Error) -> Bool {
        if Task.isCancelled || error is CancellationError { return true }
        return String(reflecting: error).contains("clientIsStopped")
    }

    // MARK: - Writing

    func createAccount(name: String, symbol: String, opening: Decimal, currency: String) async -> Bool {
        await mutation { try await $0.createAccount(name: name, symbol: symbol, opening: opening, currency: currency) }
    }

    /// Saves an edit to an existing account.
    ///
    /// `balance` is optional on purpose: it only travels when the user touched
    /// the amount or the currency, so renaming an account cannot zero out its
    /// money.
    func updateAccount(
        id: String, name: String, symbol: String,
        balance: Decimal?, currency: String, isArchived: Bool = false
    ) async -> Bool {
        await mutation {
            try await $0.updateAccount(
                id: id, name: name, symbol: symbol,
                balance: balance, currency: currency, isArchived: isArchived
            )
        }
    }

    func deleteAccount(_ account: Finance_Account) async {
        _ = await mutation { try await $0.deleteAccount(id: account.id) }
    }

    func saveTransaction(
        id: String = "", kind: TransactionEditorKind,
        accountID: String, destinationID: String,
        title: String, category: String,
        amount: Decimal, destinationAmount: Decimal? = nil,
        currency: String, note: String, date: Date
    ) async -> Bool {
        await mutation {
            try await $0.saveTransaction(
                id: id, kind: kind, accountID: accountID, destinationID: destinationID,
                title: title, category: category, amount: amount,
                destinationAmount: destinationAmount, currency: currency, note: note, date: date
            )
        }
    }

    func deleteTransaction(_ transaction: Finance_Transaction) async {
        _ = await mutation { try await $0.deleteTransaction(id: transaction.id) }
    }

    func upsertBudget(
        id: String = "", title: String, category: String, limit: Decimal,
        reminder: Bool, paymentDate: Date, recurrence: Finance_BudgetRecurrence
    ) async -> Bool {
        // An existing budget keeps the currency it was written in. Stamping the
        // main currency on every save silently re-denominated a budget the user
        // had set up in another one.
        let existing = budgets.first { $0.id == id }?.limit.currencyCode
        let currency = existing?.isEmpty == false ? existing! : mainCurrencyCode
        let month = monthKey

        return await mutation {
            try await $0.upsertBudget(
                id: id, monthKey: month, title: title, category: category,
                limit: limit, currency: currency,
                reminder: reminder, paymentDate: paymentDate, recurrence: recurrence
            )
        }
    }

    func deleteBudget(_ budget: Finance_Budget) async {
        _ = await mutation { try await $0.deleteBudget(id: budget.id) }
    }

    func upsertGoal(
        id: String = "", title: String, accountID: String,
        category: String, target: Decimal, currency: String
    ) async -> Bool {
        await mutation {
            try await $0.upsertGoal(
                id: id, title: title, accountID: accountID,
                category: category, target: target, currency: currency
            )
        }
    }

    func deleteGoal(_ goal: Finance_Goal) async {
        _ = await mutation { try await $0.deleteGoal(id: goal.id) }
    }

    /// Asks for notification permission before turning reminders on.
    ///
    /// Asked here rather than at launch: the prompt lands next to the switch
    /// that needs it, and a refusal is answered by leaving the switch off
    /// instead of storing a setting the system will not honour.
    func requestReminderAuthorization() async -> Bool {
        await reminders.requestAuthorization()
    }

    func updateSettings(currency: String, monthlyReminders: Bool, promoEmail: Bool, promoPush: Bool) async -> Bool {
        await mutation {
            try await $0.updateSettings(
                currency: currency, monthlyReminders: monthlyReminders,
                promoEmail: promoEmail, promoPush: promoPush
            )
        }
    }

    // MARK: - Plumbing

    // MARK: - Live updates

    /// How often a shared account is re-read while the app is in front.
    ///
    /// A poll, not a subscription. Financium has no push registration and no
    /// streaming RPC, and inventing either for this would be a larger change
    /// than the feature. Fifteen seconds is short enough that a partner's
    /// spending appears while you are still looking at the screen, and long
    /// enough to be unnoticeable on a phone bill.
    private static let liveRefreshInterval = Duration.seconds(15)

    private var liveUpdates: Task<Void, Never>?

    /// True when anything on screen belongs to more than one person.
    ///
    /// Polling a ledger only you can write to would be asking the server to
    /// confirm what this device already knows.
    var hasSharedAccounts: Bool {
        accounts.contains { Self.isShared($0) }
    }

    /// Starts re-reading while the app is in front and something is shared.
    func startLiveUpdates() {
        stopLiveUpdates()
        guard mode == .account, hasSharedAccounts else { return }

        liveUpdates = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.liveRefreshInterval)
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    func stopLiveUpdates() {
        liveUpdates?.cancel()
        liveUpdates = nil
    }

    // MARK: - Sharing

    /// Whether an account is shared with anyone, for the badge on its row.
    nonisolated static func isShared(_ account: Finance_Account) -> Bool {
        account.memberCount > 1
    }

    /// Who is looking, for the calls that need to name them — leaving a shared
    /// account is "remove me", and the server needs the id to know who that is.
    var currentUserID: String { auth.user?.userID ?? "" }

    /// Whether this reader may invite others or make the account private again.
    func isOwner(of account: Finance_Account) -> Bool {
        // An account with no owner recorded is one from before sharing existed,
        // and it belongs to whoever is looking at it.
        account.ownerUserID.isEmpty || account.ownerUserID == auth.user?.userID
    }

    /// Shares an account and returns the invite to pass on.
    func shareAccount(_ account: Finance_Account) async -> AccountInvite? {
        do {
            let invite = try await backend.shareAccount(id: account.id)
            await refresh()
            return invite
        } catch {
            guard !Self.wasCancelled(error) else { return nil }
            errorMessage = Self.message(for: error)
            return nil
        }
    }

    /// Redeems an invite. Returns the account joined, so the screen can say which.
    func joinAccount(code: String) async -> Finance_Account? {
        do {
            let account = try await backend.joinAccount(code: code)
            await refresh()
            return account
        } catch {
            let detail = FinanceLog.describe(error)
            guard !Self.wasCancelled(error) else {
                FinanceLog.store.debug("joinAccount cancelled: \(detail, privacy: .public)")
                return nil
            }
            FinanceLog.store.error("joinAccount failed: \(detail, privacy: .public)")
            errorMessage = Self.message(for: error)
            return nil
        }
    }

    /// Makes an account private again, or removes one member from it.
    func stopSharingAccount(_ account: Finance_Account, memberID: String = "") async -> Bool {
        await mutation { try await $0.stopSharingAccount(id: account.id, memberID: memberID) }
    }

    private func mutation(_ operation: (any FinanceBackend) async throws -> Void) async -> Bool {
        do {
            try await operation(backend)
            await refresh()
            return true
        } catch {
            let detail = FinanceLog.describe(error)
            guard !Self.wasCancelled(error) else {
                FinanceLog.store.debug("write cancelled: \(detail, privacy: .public)")
                return false
            }
            FinanceLog.store.error("write failed: \(detail, privacy: .public)")
            errorMessage = Self.message(for: error)
            return false
        }
    }

    /// Turns a failed write into something worth reading.
    ///
    /// The two backends fail differently — one returns a gRPC status, the other
    /// throws a `FinanceLedger.Failure` — but the user is looking at the same
    /// screen either way, so both are mapped to the same sentences.
    static func message(for error: Error) -> String {
        if let failure = error as? FinanceLedger.Failure {
            switch failure {
            case .conflict:
                return NSLocalizedString("error.budget.duplicate_category", comment: "Category already budgeted")
            case .accountHasTransactions:
                return NSLocalizedString("error.account.has_transactions", comment: "Account still has transactions")
            case .invalidArgument, .notFound:
                return NSLocalizedString("error.invalid", comment: "Write refused")
            }
        }
        guard let rpc = error as? RPCError else {
            return NSLocalizedString("error.generic", comment: "Something went wrong")
        }
        switch rpc.code {
        case .alreadyExists:
            return NSLocalizedString("error.budget.duplicate_category", comment: "Category already budgeted")
        case .failedPrecondition:
            return NSLocalizedString("error.account.has_transactions", comment: "Account still has transactions")
        case .unavailable, .deadlineExceeded, .cancelled:
            return NSLocalizedString("error.unreachable", comment: "Server unreachable")
        case .unauthenticated:
            return NSLocalizedString("error.unauthorized", comment: "Session no longer valid")
        case .permissionDenied:
            // Not the same thing as an expired session, and saying so sent
            // readers to sign in again over a call the server was never going
            // to allow — which signing in again does not change.
            return NSLocalizedString("error.forbidden", comment: "Call refused")
        case .invalidArgument, .notFound, .outOfRange:
            return NSLocalizedString("error.invalid", comment: "Write refused")
        default:
            // Never `localizedDescription`. On an error that is not a
            // `LocalizedError` — which `RPCError` is not — Foundation falls
            // back to the numeric form, and the reader is told their accounts
            // could not be loaded because of "runtime error 1".
            return NSLocalizedString("error.generic", comment: "Something went wrong")
        }
    }
}

import CloudKit
import Combine
import Foundation
import WidgetKit
import os

/// How the app is being used.
///
/// Local mode is not a degraded account: everything works, it is just kept on
/// the device and computed there. The distinction the app cares about is which
/// backend to talk to and what Profile should offer.
enum FinanceMode: Equatable {
    /// Kept on the device and synced to the user's private iCloud database;
    /// shared accounts live in the shared database. Chosen when the device has
    /// an iCloud account.
    case icloud
    /// Kept on the device alone. Chosen when there is no iCloud account.
    case local
}

/// Screen state, and one backend behind it.
///
/// The store used to make the gRPC calls itself. Splitting the calls out means
/// working without an account changed one line here instead of every screen.
@MainActor
final class FinanceStore: ObservableObject {
    @Published private(set) var overview = FinanceOverview()
    @Published private(set) var accounts: [FinanceAccount] = []
    @Published private(set) var transactions: [FinanceTransaction] = []
    @Published private(set) var budgets: [FinanceBudget] = []
    @Published private(set) var goals: [FinanceGoal] = []
    @Published private(set) var settings = FinanceSettings()
    @Published private(set) var isLoading = false

    /// Whether the backend has answered at least once this session.
    ///
    /// "No accounts yet" is an answer, and screens should not give it before one
    /// is known. `isLoading` cannot stand in for this: it also goes up on
    /// pull-to-refresh and after every edit, which would make an empty state
    /// blink out and back for a reader who genuinely has no accounts.
    @Published private(set) var hasLoaded = false
    @Published var errorMessage: String?
    /// Invitation errors belong to the app root, including the sign-in screen,
    /// and must survive background ledger refreshes.
    @Published var shareAcceptanceError: String?

    /// Why the last load failed, or nil.
    ///
    /// Separate from `errorMessage` because that one belongs to the alert and
    /// is cleared the moment it is dismissed. A screen that has nothing to show
    /// still needs to know why after the alert has gone, or it goes back to
    /// looking like an empty account.
    @Published private(set) var loadFailure: String?

    /// A transaction editor a widget asked for.
    ///
    /// Parked here rather than passed down: the tile is tapped before the Money
    /// screen exists, and the screen that must open the editor is two levels
    /// below the view that receives the link. A published value both can see is
    /// shorter than threading a binding through the middle.
    @Published var pendingQuickAdd: TransactionEditorKind?

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

    private let account: iCloudAccount
    private let local: LocalFinanceBackend
    private var backend: any FinanceBackend
    private let reminders = BudgetReminders()

    /// The CloudKit-backed store and the engine behind it, once sync is on.
    ///
    /// Nil until `enableCloudSync()` is called. While it is nil the app runs in
    /// `.local` mode whatever the iCloud account status is — there is nowhere
    /// for `.icloud` mode to read or write.
    private var cloud: (any FinanceBackend)?
    private var coordinator: CloudKitSyncCoordinator?

    /// Accounts shared *with* this device by someone else. Anything not in here
    /// is the local user's to make private again.
    @Published private(set) var participantAccountIDs: Set<String> = []

    /// Saved CloudKit shares ready for the system collaboration UI. Keeping the
    /// actual share, not merely its URL, makes repeat taps fully synchronous.
    @Published private(set) var accountShares: [String: CKShare] = [:]


    /// The read currently in flight, so overlapping callers share it.
    private var refreshTask: Task<Void, Never>?

    /// The live store, for the app delegate — which SwiftUI does not inject
    /// environment objects into — to reach the sync coordinator.
    static weak var current: FinanceStore?
    private static var pendingShareInvitations: [CKShare.Metadata] = []
    private var acceptingShareInvitations = false

    init(
        account: iCloudAccount,
        local: LocalFinanceBackend = LocalFinanceBackend()
    ) {
        self.account = account
        self.local = local
        self.backend = local
        Self.current = self
        Task { await acceptPendingShareInvitations() }
    }

    /// Keep cold-launch metadata until SwiftUI has created the store. Repeated
    /// delivery of the same invitation while it is being accepted is a no-op.
    static func receiveShareInvitation(_ metadata: CKShare.Metadata) {
        guard !pendingShareInvitations.contains(where: {
            $0.containerIdentifier == metadata.containerIdentifier
                && $0.share.recordID == metadata.share.recordID
        }) else { return }
        pendingShareInvitations.append(metadata)
        Task { await current?.acceptPendingShareInvitations() }
    }

    private func acceptPendingShareInvitations() async {
        guard !acceptingShareInvitations else { return }
        acceptingShareInvitations = true
        defer { acceptingShareInvitations = false }

        while let metadata = Self.pendingShareInvitations.first {
            do {
                await account.refresh()
                guard account.isAvailable else { throw CKError(.notAuthenticated) }
                enableCloudSync()
                guard let coordinator else { throw CKError(.internalError) }
                try await coordinator.acceptShare(metadata)
                await refresh(force: true)
            } catch {
                if !Self.wasCancelled(error) {
                    FinanceLog.store.error("accepting share failed: \(FinanceLog.describe(error), privacy: .public)")
                    shareAcceptanceError = Self.message(for: error)
                }
            }
            Self.pendingShareInvitations.removeFirst()
        }
    }

    /// Stands up the CloudKit sync engine and switches to it when the device
    /// has an iCloud account. Safe to call more than once — the second call is
    /// a no-op.
    func enableCloudSync() {
        guard coordinator == nil else { return }
        let coordinator = CloudKitSyncCoordinator(local: local) { [weak self] in
            await self?.refresh(force: true)
        }
        self.coordinator = coordinator
        self.cloud = coordinator.backend
        adopt(mode: resolvedMode())
        Task { await coordinator.start() }
    }

    /// The sync coordinator, for the app delegate to forward CloudKit pushes
    /// and share-acceptance to.
    var syncCoordinator: CloudKitSyncCoordinator? { coordinator }

    /// Which mode the current iCloud account status and wiring imply.
    func resolvedMode() -> FinanceMode {
        (cloud != nil && account.isAvailable) ? .icloud : .local
    }

    private func apply(_ snapshot: FinanceSnapshot) {
        overview = snapshot.overview
        accounts = snapshot.accounts
        transactions = snapshot.transactions
        budgets = snapshot.budgets
        goals = snapshot.goals
        settings = snapshot.settings
    }

    /// Leaves the figures the Home Screen tiles draw in the shared container.
    ///
    /// Written here rather than after every write, because this is the one
    /// place every path ends: a refresh, a restored cache, a mode change. The
    /// widgets have no session of their own and cannot ask the backend
    /// anything, so what the app last saw is all they will ever have.
    ///
    /// Budgets are sorted by how used they are, most first, and all of them
    /// travel. The order is the tile's default — the one about to be overspent
    /// is the one worth a place on the Home Screen — but the widget also lets
    /// the reader pick, and it can only offer what was sent. Capping the list
    /// at four made the other budgets unpickable.
    private func publishWidgetSnapshot(_ monthly: FinanceSnapshot, monthStart: Date) {
        let overview = monthly.overview
        let budgets = monthly.budgets
        guard Self.sharedContainerIsAvailable else { return }

        let ranked = budgets
            .filter { $0.limit.minorUnits > 0 }
            .sorted { lhs, rhs in
                let left = Double(lhs.spent.minorUnits) / Double(lhs.limit.minorUnits)
                let right = Double(rhs.spent.minorUnits) / Double(rhs.limit.minorUnits)
                return left > right
            }
            .map { budget in
                WidgetBudget(
                    id: budget.id,
                    title: budget.title.isEmpty ? budget.category : budget.title,
                    spentMinor: budget.spent.minorUnits,
                    limitMinor: budget.limit.minorUnits,
                    currencyCode: budget.limit.currencyCode
                )
            }

        let snapshot = WidgetSnapshot(
            totalBalanceMinor: overview.totalBalance.minorUnits,
            spentMinor: overview.spent.minorUnits,
            earnedMinor: overview.earned.minorUnits,
            currencyCode: mainCurrencyCode,
            budgets: Array(ranked),
            updatedAt: Date(),
            monthStart: monthStart
        )

        guard let defaults = Self.sharedDefaults,
              let data = try? JSONEncoder().encode(snapshot) else { return }
        // Only when it changed. `reloadAllTimelines` is a request the system
        // keeps count of, and an app that asks after every refresh — several of
        // which happen on one launch — has its later requests ignored,
        // including the one that mattered.
        if let previousData = defaults.data(forKey: Self.widgetSnapshotKey),
           var previous = try? JSONDecoder().decode(WidgetSnapshot.self, from: previousData) {
            previous.updatedAt = snapshot.updatedAt
            if previous == snapshot { return }
        }
        defaults.set(data, forKey: Self.widgetSnapshotKey)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private static let widgetAppGroupID = "group.com.gofinancium.Financium.shared"
    private static let widgetSnapshotKey = "Financium.widget.snapshot"

    private static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: widgetAppGroupID)
    }

    /// Whether the shared container is actually usable, checked once.
    ///
    /// `UserDefaults(suiteName:)` hands back an object whether or not the app
    /// is entitled to that group, and then quietly fails to read or write —
    /// the only sign being a line from `cfprefsd` about "kCFPreferencesAnyUser
    /// with a container", which says nothing about which app group or why.
    /// Writing a value and reading it back is the only reliable test, and it
    /// turns a silent misconfiguration into one sentence naming the group.
    ///
    /// The usual cause is not code: the group has to exist in the developer
    /// account and be ticked for both targets, and until it is, the container
    /// is never created.
    private static let sharedContainerIsAvailable: Bool = {
        guard let defaults = sharedDefaults else {
            FinanceLog.store.error("app group \(widgetAppGroupID, privacy: .public) is unavailable")
            return false
        }
        let probe = "Financium.widget.probe"
        defaults.set(true, forKey: probe)
        let readable = defaults.bool(forKey: probe)
        defaults.removeObject(forKey: probe)
        if !readable {
            FinanceLog.store.error(
                """
                app group \(widgetAppGroupID, privacy: .public) is not writable —                 widgets will stay empty. Check that the group exists in the                 developer account and is enabled for both targets.
                """
            )
        }
        return readable
    }()

    /// The app's half of the contract in `FinanciumWidgets/WidgetSnapshot.swift`.
    ///
    /// Mirrored rather than shared: the widget folder is synchronised into the
    /// extension target alone, so one declaration cannot serve both without
    /// editing target membership by hand. The field names are what hold the two
    /// together — rename one here and the tile silently loses that figure.
    private struct WidgetSnapshot: Codable, Equatable {
        let totalBalanceMinor: Int64
        let spentMinor: Int64
        let earnedMinor: Int64
        let currencyCode: String
        let budgets: [WidgetBudget]
        var updatedAt: Date
        let monthStart: Date
    }

    private struct WidgetBudget: Codable, Equatable {
        let id: String
        let title: String
        let spentMinor: Int64
        let limitMinor: Int64
        let currencyCode: String
    }

    /// Points the store at the backend the session now writes through.
    ///
    /// The on-device ledger is the same file in both modes — `.icloud` just
    /// adds a sync engine that mirrors it to CloudKit and pulls shared
    /// accounts in — so nothing on screen is cleared here. A refresh follows to
    /// pick up anything the newly attached backend can see.
    func adopt(mode: FinanceMode) {
        guard mode != self.mode else { return }
        self.mode = mode
        backend = (mode == .icloud ? cloud : nil) ?? local
        hasLoaded = false
        loadFailure = nil
    }

    /// The on-device ledger, for the "reset" action in Profile.
    var localBackend: LocalFinanceBackend { local }

    /// Wipes the ledger everywhere — the device file and, if sync is on, every
    /// zone this device owns in iCloud. For "delete account".
    func deleteEverything() async {
        await coordinator?.deleteAllData()
        await local.removeAll()
        adopt(mode: .local)
        cloud = nil
        coordinator = nil
        await refresh(force: true)
    }

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
    func totals(for code: String) -> FinanceCurrencyTotal {
        if let match = overview.currencies.first(where: { $0.currencyCode.caseInsensitiveCompare(code) == .orderedSame }) {
            return match
        }
        var empty = FinanceCurrencyTotal()
        empty.currencyCode = code
        empty.balance = FinanceMoney(decimal: 0, currencyCode: code)
        empty.spent = FinanceMoney(decimal: 0, currencyCode: code)
        empty.earned = FinanceMoney(decimal: 0, currencyCode: code)
        return empty
    }

    /// The month budgets are read and written for: the one the period starts in.
    var monthKey: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: period.anchorMonth)
    }

    /// Read-only history for plan charts; never changes the global period or UI snapshot.
    func transactionsForPlan(from start: Date, through end: Date) async throws -> [FinanceTransaction] {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM"
        let snapshot = try await backend.load(period: .range(start: start, end: end), monthKey: formatter.string(from: start))
        return snapshot.transactions
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
    /// - Parameter force: start a new read even if one is already running.
    ///   Required after a write: a read that was issued *before* the write
    ///   cannot contain it. Joining one made a deletion look as though it had
    ///   not happened — the row was gone from the database and still on screen,
    ///   because the answer that redrew the screen had been asked for a moment
    ///   too early. Trying again only repeated it.
    func refresh(force: Bool = false) async {
        if let inFlight = refreshTask {
            await inFlight.value
            guard force else { return }
        }
        // Another caller may have started one while the line above was waiting.
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
        isLoading = true
        defer { isLoading = false }
        do {
            // Both read before the await, so a period changed mid-flight cannot
            // file the answer under the wrong window.
            let key = monthKey

            let selectedPeriod = period
            let snapshot = try await backend.load(period: selectedPeriod, monthKey: key)
            apply(snapshot)
            let currentMonth = FinancePeriod.currentMonth
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM"
            let widgetMonth = formatter.string(from: currentMonth.anchorMonth)
            // Widgets always describe this month, independently of the UI picker.
            do {
                let monthly: FinanceSnapshot
                if selectedPeriod == currentMonth {
                    monthly = snapshot
                } else {
                    monthly = try await backend.load(period: currentMonth, monthKey: widgetMonth)
                }
                publishWidgetSnapshot(monthly, monthStart: currentMonth.anchorMonth)
            } catch {
                FinanceLog.store.error("widget snapshot failed: \(FinanceLog.describe(error), privacy: .public)")
            }
            hasLoaded = true
            errorMessage = nil
            loadFailure = nil

            if let coordinator {
                participantAccountIDs = await coordinator.participantAccountIDs()
                sharedAccountIDs = await coordinator.sharedAccountIDs()
                accountShares = await coordinator.cachedShares()
            } else {
                participantAccountIDs = []
                sharedAccountIDs = []
                accountShares = [:]
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
    /// A `CKError.operationCancelled` is reported when the enclosing task is
    /// cancelled, which happens constantly and by design — leaving a screen,
    /// backgrounding the app.
    private static func wasCancelled(_ error: Error) -> Bool {
        if Task.isCancelled || error is CancellationError { return true }
        return (error as? CKError)?.code == .operationCancelled
    }

    // MARK: - Writing

    func createAccount(name: String, symbol: String, opening: Decimal, currency: String, appearance: FinanceAccountAppearance? = nil) async -> Bool {
        await mutation { try await $0.createAccount(name: name, symbol: symbol, opening: opening, currency: currency, appearance: appearance) }
    }

    /// Saves an edit to an existing account.
    ///
    /// `balance` is optional on purpose: it only travels when the user touched
    /// the amount or the currency, so renaming an account cannot zero out its
    /// money.
    func updateAccount(
        id: String, name: String, symbol: String,
        balance: Decimal?, currency: String, isArchived: Bool = false, appearance: FinanceAccountAppearance? = nil
    ) async -> Bool {
        await mutation {
            try await $0.updateAccount(
                id: id, name: name, symbol: symbol,
                balance: balance, currency: currency, isArchived: isArchived, appearance: appearance
            )
        }
    }

    enum AccountDeletionOutcome: Equatable {
        case deleted
        /// Refused: the account still has transactions. Ask whether to delete
        /// it with them (`deleteAccount(_:cascade: true)`) before giving up.
        case hasTransactions
        case failed
    }

    @discardableResult
    func deleteAccount(_ account: FinanceAccount, cascade: Bool = false) async -> AccountDeletionOutcome {
        do {
            try await backend.deleteAccount(id: account.id, cascade: cascade)
            await refresh(force: true)
            return .deleted
        } catch FinanceLedger.Failure.accountHasTransactions {
            return .hasTransactions
        } catch {
            let detail = FinanceLog.describe(error)
            guard !Self.wasCancelled(error) else {
                FinanceLog.store.debug("delete account cancelled: \(detail, privacy: .public)")
                return .failed
            }
            FinanceLog.store.error("delete account failed: \(detail, privacy: .public)")
            errorMessage = Self.message(for: error)
            await refresh(force: true)
            return .failed
        }
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

    /// Removes a transaction, including one that is already gone.
    ///
    /// A row can be on screen without being in the ledger any more: a shared
    /// account changed on another device, and the pull that would take the row
    /// off screen has not landed yet. Deleting it then is a no-op the backend
    /// treats as success — the point of the tap was for the row to stop
    /// existing, and it does not exist.
    func deleteTransaction(_ transaction: FinanceTransaction) async {
        do {
            try await backend.deleteTransaction(id: transaction.id)
        } catch FinanceLedger.Failure.notFound {
            FinanceLog.store.debug("delete: transaction was already gone")
        } catch {
            let detail = FinanceLog.describe(error)
            guard !Self.wasCancelled(error) else {
                FinanceLog.store.debug("delete cancelled: \(detail, privacy: .public)")
                return
            }
            FinanceLog.store.error("delete failed: \(detail, privacy: .public)")
            errorMessage = Self.message(for: error)
        }
        await refresh(force: true)
    }

    func upsertBudget(
        id: String = "", title: String, category: String, limit: Decimal,
        reminder: Bool, paymentDate: Date, recurrence: FinanceBudgetRecurrence, accountID: String = "", coverJSON: String? = nil
    ) async -> Bool {
        // An existing budget keeps the currency it was written in. Stamping the
        // main currency on every save silently re-denominated a budget the user
        // had set up in another one.
        let existing = budgets.first { $0.id == id }?.limit.currencyCode
        let currency = accounts.first(where: { $0.id == accountID })?.balance.currencyCode
            ?? (existing?.isEmpty == false ? existing! : mainCurrencyCode)
        let month = monthKey

        return await mutation {
            try await $0.upsertBudget(
                id: id, monthKey: month, title: title, category: category,
                limit: limit, currency: currency,
                reminder: reminder, paymentDate: paymentDate, recurrence: recurrence, accountID: accountID, coverJSON: coverJSON
            )
        }
    }

    func deleteBudget(_ budget: FinanceBudget) async {
        _ = await mutation { try await $0.deleteBudget(id: budget.id) }
    }

    func upsertGoal(
        id: String = "", title: String, accountID: String,
        category: String, target: Decimal, currency: String, coverJSON: String? = nil
    ) async -> Bool {
        await mutation {
            try await $0.upsertGoal(
                id: id, title: title, accountID: accountID,
                category: category, target: target, currency: currency, coverJSON: coverJSON
            )
        }
    }

    func deleteGoal(_ goal: FinanceGoal) async {
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

    // MARK: - Live updates

    private var liveUpdates: Task<Void, Never>?

    /// True when any account on screen is shared.
    var hasSharedAccounts: Bool {
        accounts.contains { isShared($0) }
    }

    /// Kept for the scene-phase hooks in `ContentView`. Live updates for a
    /// shared account now arrive as CloudKit change pushes handled by
    /// `CloudKitSyncEngine`, which calls `refresh()` itself when a pull lands —
    /// there is nothing to poll. A single refresh still happens on activation,
    /// next to this call, as a backstop for a push that was missed while the
    /// app was not running.
    func startLiveUpdates() {}

    func stopLiveUpdates() {
        liveUpdates?.cancel()
        liveUpdates = nil
    }

    // MARK: - Sharing

    /// Supplies the URL to the toolbar's asynchronous `Transferable`. Existing
    /// shares come from local bookkeeping; only a brand-new invite touches the
    /// network, and that happens after the share menu has opened.
    func shareURL(forAccountID accountID: String) async throws -> URL {
        if let coordinator {
            let urls = await coordinator.inviteURLs()
            if let url = urls[accountID] { return url }
        }
        guard let account = accounts.first(where: { $0.id == accountID }) else {
            throw FinanceLedger.Failure.notFound
        }
        guard let invite = await shareAccount(account), let url = invite.url else {
            throw FinanceLedger.Failure.invalidArgument
        }
        return url
    }

    /// Supplies `CKShareTransferRepresentation` with either a cached share or
    /// a newly prepared one. The framework calls this only after it has opened
    /// the collaboration UI, so CloudKit latency no longer blocks presentation.
    func prepareShareRecord(forAccountID accountID: String) async throws -> CKShare {
        if let share = accountShares[accountID] { return share }
        guard let coordinator else { throw FinanceLedger.Failure.invalidArgument }
        do {
            let share = try await coordinator.shareRecord(forAccount: accountID)
            accountShares[accountID] = share
            sharedAccountIDs.insert(accountID)
            return share
        } catch {
            if !Self.wasCancelled(error) {
                FinanceLog.store.error("prepare share failed: \(FinanceLog.describe(error), privacy: .public)")
                shareAcceptanceError = Self.message(for: error)
            }
            throw error
        }
    }

    func cachedShare(for account: FinanceAccount) -> CKShare? {
        accountShares[account.id]
    }

    /// Accounts with a live `CKShare` — this device's own or one it joined.
    /// A share exists the moment the link is minted, before anyone accepts.
    @Published private(set) var sharedAccountIDs: Set<String> = []

    /// Whether this account has an active invite. Unlike `isShared`, this is
    /// true as soon as the owner creates the link, even before it is accepted.
    func hasShareInvite(_ account: FinanceAccount) -> Bool {
        sharedAccountIDs.contains(account.id)
    }

    /// A created invite alone does not make an account visibly collaborative.
    /// For the owner, CloudKit's accepted-participant count must also be above
    /// one. Accounts joined from another owner live in the shared database and
    /// are collaborative by definition.
    func isShared(_ account: FinanceAccount) -> Bool {
        participantAccountIDs.contains(account.id)
            || (hasShareInvite(account) && account.memberCount > 1)
    }

    /// Who is looking, as their iCloud user-record name — for "remove me" from
    /// a shared account.
    var currentUserID: String { account.userRecordID?.recordName ?? "" }

    /// Whether this reader may invite others or make the account private again.
    ///
    /// True for everything except an account shared *with* this device from
    /// someone else's iCloud. That covers a private account, one this device
    /// shared out, and a stale share left by the old backend whose recorded
    /// owner id no longer maps to anyone — all of which are this user's to
    /// close.
    func isOwner(of financeAccount: FinanceAccount) -> Bool {
        !participantAccountIDs.contains(financeAccount.id)
    }

    /// Turns a shared account back into a private one — the owner's action, and
    /// also the way to clear a share inherited from the retired backend.
    func makeAccountPrivate(_ financeAccount: FinanceAccount) async {
        if let coordinator {
            await coordinator.makePrivate(accountID: financeAccount.id)
        } else {
            await local.setSharing(accountID: financeAccount.id, ownerUserID: "", memberCount: 1)
        }
        await refresh(force: true)
    }

    /// Shares an account and returns the invite to pass on.
    func shareAccount(_ account: FinanceAccount) async -> AccountInvite? {
        do {
            let invite = try await backend.shareAccount(id: account.id)
            await refresh(force: true)
            return invite
        } catch {
            guard !Self.wasCancelled(error) else { return nil }
            errorMessage = Self.message(for: error)
            return nil
        }
    }

    /// The `CKShare` itself (existing or freshly minted) plus the container it
    /// lives in, for presenting Apple's own `UICloudSharingController` — the
    /// "Collaborate" screen with participant faces and the public-link toggle,
    /// rather than a bare-URL activity sheet.
    ///
    /// iCloud sync only: local mode has no CloudKit container to share through.
    func shareRecord(for account: FinanceAccount) async -> (share: CKShare, container: CKContainer)? {
        guard let coordinator else { return nil }
        do {
            let share = try await coordinator.shareRecord(forAccount: account.id)
            await refresh(force: true)
            return (share, coordinator.cloudContainer)
        } catch {
            guard !Self.wasCancelled(error) else { return nil }
            errorMessage = Self.message(for: error)
            return nil
        }
    }

    /// Called when the reader stops sharing from inside
    /// `UICloudSharingController` itself rather than through the app's own UI —
    /// the controller has already removed the share; this just brings our own
    /// bookkeeping in line with that.
    func handleStoppedSharingFromSystemUI(accountID: String) async {
        await coordinator?.handleStoppedSharingFromSystemUI(accountID: accountID)
        await refresh(force: true)
    }

    /// Redeems an invite. Returns the account joined, so the screen can say which.
    func joinAccount(code: String) async -> FinanceAccount? {
        do {
            let account = try await backend.joinAccount(code: code)
            await refresh(force: true)
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

    /// Makes an account private again (empty `memberID`), or removes one member
    /// from it.
    func stopSharingAccount(_ account: FinanceAccount, memberID: String = "") async -> Bool {
        // "Make it private" is the same operation whether the account is a real
        // CKShare or a leftover from the old backend — route both through the
        // coordinator, which handles the missing-share case.
        if memberID.isEmpty {
            await makeAccountPrivate(account)
            return true
        }
        return await mutation { try await $0.stopSharingAccount(id: account.id, memberID: memberID) }
    }

    private func mutation(_ operation: (any FinanceBackend) async throws -> Void) async -> Bool {
        do {
            try await operation(backend)
            await refresh(force: true)
            return true
        } catch {
            let detail = FinanceLog.describe(error)
            guard !Self.wasCancelled(error) else {
                FinanceLog.store.debug("write cancelled: \(detail, privacy: .public)")
                return false
            }
            FinanceLog.store.error("write failed: \(detail, privacy: .public)")
            let message = Self.message(for: error)
            // Re-read even though the write failed.
            //
            // A refused write means what is on screen and what is in the
            // database disagree, and the database is the one that is right —
            // which is exactly the moment a refresh is most worth doing.
            // Skipping it left a row the reader had just deleted sitting in the
            // list under an error saying it could not be found.
            await refresh(force: true)
            // A successful refresh clears errorMessage. Publish the refused
            // write afterwards so the editor can explain why it stayed open.
            errorMessage = message
            return false
        }
    }

    /// Turns a failed write into something worth reading.
    ///
    /// The ledger rules throw `FinanceLedger.Failure`; CloudKit throws
    /// `CKError`. The user is looking at the same screen either way, so both
    /// are mapped to the same sentences.
    static func message(for error: Error) -> String {
        if let failure = error as? FinanceLedger.Failure {
            switch failure {
            case .accountHasTransactions:
                return NSLocalizedString("error.account.has_transactions", comment: "Account still has transactions")
            case .invalidArgument, .notFound:
                return NSLocalizedString("error.invalid", comment: "Write refused")
            }
        }
        guard let ck = error as? CKError else {
            return NSLocalizedString("error.generic", comment: "Something went wrong")
        }
        switch ck.code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable,
             .requestRateLimited, .zoneBusy:
            return NSLocalizedString("error.unreachable", comment: "iCloud unreachable")
        case .notAuthenticated:
            return NSLocalizedString("error.unauthorized", comment: "Not signed in to iCloud")
        case .permissionFailure:
            return NSLocalizedString("error.forbidden", comment: "Call refused")
        case .quotaExceeded:
            return NSLocalizedString("error.icloud.quota", comment: "iCloud storage full")
        case .serverRejectedRequest, .badContainer, .missingEntitlement:
            return NSLocalizedString("error.icloud.configuration", comment: "CloudKit configuration failure")
        case .unknownItem, .zoneNotFound:
            return NSLocalizedString("error.icloud.missing_record", comment: "Account not uploaded")
        default:
            return NSLocalizedString("error.generic", comment: "Something went wrong")
        }
    }
}

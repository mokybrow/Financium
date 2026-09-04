import Foundation
import SwiftProtobuf

/// The accounting rules, as pure functions over the data.
///
/// These are a second copy of what `money-service` does in Go, which is the
/// price of working without an account. They live in one file, apart from any
/// view and any storage, so the two copies can be read side by side and so the
/// tests exercise the rules rather than the screens. Every function here has a
/// named counterpart in the Go service; if one changes, look for the other.
nonisolated enum FinanceLedger {

    // MARK: - Balances

    /// Applies a transaction to the accounts it touches.
    ///
    /// `direction` is `+1` to post a transaction and `-1` to take it back —
    /// editing is "take back the old, post the new", which is how the service
    /// keeps an edited amount from being counted twice.
    ///
    /// Counterpart: `applyBalanceChanges` in repository.go.
    static func applyBalance(
        of transaction: Finance_Transaction,
        direction: Int64,
        to accounts: inout [Finance_Account]
    ) {
        func adjust(_ accountID: String, _ delta: Int64) {
            guard !accountID.isEmpty,
                  let index = accounts.firstIndex(where: { $0.id == accountID }) else { return }
            accounts[index].balance.minorUnits += delta
        }

        let amount = transaction.amount.minorUnits
        switch transaction.kind {
        case .expense:
            adjust(transaction.fromAccountID, -amount * direction)
        case .income:
            adjust(transaction.toAccountID, amount * direction)
        case .transfer:
            adjust(transaction.fromAccountID, -amount * direction)
            // The destination gets its own amount: across currencies the money
            // that leaves and the money that lands are different numbers.
            let received = transaction.hasDestinationAmount && transaction.destinationAmount.minorUnits > 0
                ? transaction.destinationAmount.minorUnits
                : amount
            adjust(transaction.toAccountID, received * direction)
        default:
            break
        }
    }

    // MARK: - Budgets

    /// What has been spent against a budget's category in a month.
    ///
    /// Expenses only, and by category rather than by budget — which is why a
    /// month holds one budget per category.
    ///
    /// Counterpart: `SpentByCategory` in repository.go.
    static func spent(
        onCategory category: String,
        month: Date,
        currency: String,
        transactions: [Finance_Transaction]
    ) -> Int64 {
        // The caller hands over a *local* start-of-month, so the year and month
        // are read in the local calendar — reading them in UTC turns 1 March
        // 00:00 MSK into February and files a whole month's spend one month
        // early. The window itself is then built in UTC, which is how the
        // service parses "2006-01".
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        let parts = Calendar.current.dateComponents([.year, .month], from: month)
        let start = calendar.date(from: DateComponents(year: parts.year, month: parts.month)) ?? month
        let interval = DateInterval(
            start: start,
            end: calendar.date(byAdding: .month, value: 1, to: start) ?? start
        )
        return transactions.reduce(into: Int64(0)) { total, transaction in
            guard transaction.kind == .expense,
                  transaction.category == category,
                  transaction.amount.currencyCode == currency,
                  transaction.hasOccurredAt else { return }
            let date = transaction.occurredAt.date
            guard date >= interval.start, date < interval.end else { return }
            total += transaction.amount.minorUnits
        }
    }

    // MARK: - Goals

    /// A goal's progress is the balance of the account it is saved into, and its
    /// currency is that account's.
    ///
    /// Counterpart: `applyGoalAccountBalances` in repository.go.
    static func applyGoalProgress(to goals: inout [Finance_Goal], accounts: [Finance_Account]) {
        let byID = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in goals.indices {
            guard let account = byID[goals[index].accountID] else { continue }
            let currency = account.balance.currencyCode
            // Clamped at zero: an overdrawn account has saved nothing towards
            // the goal, and a negative "saved" would draw a bar running
            // backwards.
            goals[index].saved = Finance_Money(
                minorUnits: max(account.balance.minorUnits, 0),
                currencyCode: currency
            )
            goals[index].target = Finance_Money(
                minorUnits: goals[index].target.minorUnits,
                currencyCode: currency
            )
        }
    }

    // MARK: - Overview

    /// Balances and flow for one period, one row per currency.
    ///
    /// Nothing is converted here: each currency is totalled on its own terms,
    /// and conversion happens on screen where the rate can be dated and marked.
    ///
    /// Counterpart: `currencyTotals` in service.go.
    static func currencyTotals(
        mainCurrency: String,
        accounts: [Finance_Account],
        transactions: [Finance_Transaction],
        interval: DateInterval
    ) -> [Finance_CurrencyTotal] {
        var totals: [String: Finance_CurrencyTotal] = [:]

        @discardableResult
        func ensure(_ code: String) -> Bool {
            guard !code.isEmpty else { return false }
            if totals[code] == nil {
                var fresh = Finance_CurrencyTotal()
                fresh.currencyCode = code
                fresh.balance = Finance_Money(minorUnits: 0, currencyCode: code)
                fresh.spent = Finance_Money(minorUnits: 0, currencyCode: code)
                fresh.earned = Finance_Money(minorUnits: 0, currencyCode: code)
                totals[code] = fresh
            }
            return true
        }

        // The main currency is always present, so a fresh account still has
        // something to show rather than a blank row.
        ensure(mainCurrency)

        for account in accounts where ensure(account.balance.currencyCode) {
            totals[account.balance.currencyCode]?.balance.minorUnits += account.balance.minorUnits
        }

        for transaction in transactions {
            guard transaction.hasOccurredAt else { continue }
            let date = transaction.occurredAt.date
            guard date >= interval.start, date < interval.end else { continue }

            // Only after the window check: a currency the user moved nothing in
            // this period should not get an all-zero row of its own.
            let code = transaction.amount.currencyCode
            guard ensure(code) else { continue }

            switch transaction.kind {
            case .expense: totals[code]?.spent.minorUnits += transaction.amount.minorUnits
            case .income: totals[code]?.earned.minorUnits += transaction.amount.minorUnits
            // Transfers move money the user already had; counting them would
            // report a spend and an income for the same rouble.
            default: break
            }
        }

        return totals.values.sorted { lhs, rhs in
            if (lhs.currencyCode == mainCurrency) != (rhs.currencyCode == mainCurrency) {
                return lhs.currencyCode == mainCurrency
            }
            return lhs.currencyCode < rhs.currencyCode
        }
    }

    // MARK: - Snapshot

    /// Assembles the one consistent picture every screen reads, from ledger
    /// data already in memory.
    ///
    /// This is the whole of what an on-device backend does for a read: filter
    /// to the window, fill in budget spend, apply goal progress, total each
    /// currency, and derive the overview. `LocalFinanceBackend` and
    /// `CloudKitFinanceBackend` both keep their data in the same shape and hand
    /// it here rather than each computing a snapshot its own way.
    ///
    /// Counterpart: `GetOverview` + the list endpoints in service.go.
    static func snapshot(
        period: FinancePeriod,
        monthKey: String,
        accounts: [Finance_Account],
        transactions: [Finance_Transaction],
        budgets: [(month: String, budget: Finance_Budget)],
        goals: [Finance_Goal],
        settings: Finance_FinanceSettings
    ) -> FinanceSnapshot {
        let interval = period.interval
        let mainCurrency = settings.mainCurrencyCode.isEmpty ? "RUB" : settings.mainCurrencyCode

        var snapshot = FinanceSnapshot()
        snapshot.settings = settings
        snapshot.accounts = accounts.filter { !$0.isArchived }
        snapshot.transactions = transactions
            .filter { transaction in
                guard transaction.hasOccurredAt else { return false }
                let date = transaction.occurredAt.date
                return date >= interval.start && date < interval.end
            }
            .sorted { $0.occurredAt.date > $1.occurredAt.date }

        let month = period.anchorMonth
        snapshot.budgets = budgets
            .filter { $0.month == monthKey }
            .map { stored in
                var filled = stored.budget
                filled.spent = Finance_Money(
                    minorUnits: spent(
                        onCategory: stored.budget.category,
                        month: month,
                        currency: stored.budget.limit.currencyCode,
                        transactions: transactions
                    ),
                    currencyCode: stored.budget.limit.currencyCode
                )
                return filled
            }

        var progressed = goals
        applyGoalProgress(to: &progressed, accounts: accounts)
        snapshot.goals = progressed

        let totals = currencyTotals(
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

    // MARK: - Validation

    /// The reasons a write is refused, matching the gRPC statuses the service
    /// returns so both backends fail the same way.
    enum Failure: Error {
        case invalidArgument
        case notFound
        case conflict
        case accountHasTransactions
    }

    /// Counterpart: `SaveTransaction`'s validation in service.go.
    static func validate(_ transaction: Finance_Transaction) throws {
        guard transaction.amount.minorUnits > 0,
              isISOCurrency(transaction.amount.currencyCode) else {
            throw Failure.invalidArgument
        }
        switch transaction.kind {
        case .expense:
            guard !transaction.fromAccountID.isEmpty else { throw Failure.invalidArgument }
        case .income:
            guard !transaction.toAccountID.isEmpty else { throw Failure.invalidArgument }
        case .transfer:
            guard !transaction.fromAccountID.isEmpty,
                  !transaction.toAccountID.isEmpty,
                  transaction.fromAccountID != transaction.toAccountID else {
                throw Failure.invalidArgument
            }
        default:
            throw Failure.invalidArgument
        }
    }

    static func isISOCurrency(_ code: String) -> Bool {
        code.count == 3 && code.allSatisfy { $0.isUppercase && $0.isLetter }
    }
}

// Not MainActor: the target defaults every declaration to the main actor, and
// `LocalFinanceBackend` is an actor that builds money off it.
nonisolated extension Finance_Money {
    init(minorUnits: Int64, currencyCode: String) {
        self.init()
        self.minorUnits = minorUnits
        self.currencyCode = currencyCode.uppercased()
    }
}

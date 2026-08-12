import Foundation
import SwiftProtobuf

/// Moves a local ledger onto an account after signing in.
///
/// Everything goes through the ordinary RPCs rather than a bulk import: the
/// service's own validation, balance arithmetic and uniqueness rules then apply
/// to migrated data exactly as they do to anything typed in, and there is no
/// second write path to keep correct.
@MainActor
enum LocalDataMigration {

    struct Result {
        var accounts = 0
        var transactions = 0
        var budgets = 0
        var goals = 0
        /// What could not be moved. Reported rather than swallowed: a partial
        /// migration the user is not told about is worse than a failed one.
        var failures = 0

        var moved: Int { accounts + transactions + budgets + goals }
    }

    /// Uploads the local ledger, then clears it on success.
    ///
    /// Accounts go first because everything else refers to them, and their ids
    /// change on the way: the server assigns its own, so transactions, budgets
    /// and goals are rewritten to the new ones as they go.
    static func run(from local: LocalFinanceBackend, to backend: any FinanceBackend) async -> Result {
        var result = Result()
        let snapshot = await local.exportAll()

        // The ids the account already has, so a pre-existing "Cash" on the
        // server is never mistaken for the local one and handed its
        // transactions.
        let preexisting = Set(
            ((try? await backend.load(period: .currentMonth, monthKey: currentMonthKey()))?.accounts ?? [])
                .map(\.id)
        )

        // Settings first: the main currency decides how everything else reads.
        if !snapshot.settings.mainCurrencyCode.isEmpty {
            do {
                try await backend.updateSettings(
                    currency: snapshot.settings.mainCurrencyCode,
                    monthlyReminders: snapshot.settings.monthlyRemindersEnabled,
                    promoEmail: snapshot.settings.promoEmailEnabled,
                    promoPush: snapshot.settings.promoPushEnabled
                )
            } catch {
                // Counted, so the local file is not deleted having left the
                // user's main currency behind.
                result.failures += 1
            }
        }

        var accountIDs: [String: String] = [:]
        for account in snapshot.accounts {
            do {
                try await backend.createAccount(
                    name: account.name,
                    symbol: account.symbolName,
                    opening: 0,
                    currency: account.balance.currencyCode
                )
                result.accounts += 1
            } catch {
                result.failures += 1
            }
        }

        // Read back to learn the ids the server handed out. Matched by name,
        // which is what the user sees and what they picked; a duplicate name
        // would tie, so the first unclaimed one wins and the rest follow.
        let uploaded = ((try? await backend.load(period: .currentMonth, monthKey: currentMonthKey()))?.accounts ?? [])
            .filter { !preexisting.contains($0.id) }
        var claimed = Set<String>()
        for account in snapshot.accounts {
            guard let match = uploaded.first(where: {
                $0.name == account.name && !claimed.contains($0.id)
            }) else { continue }
            claimed.insert(match.id)
            accountIDs[account.id] = match.id
        }

        // Oldest first, so balances build up in the order they really did.
        let ordered = snapshot.transactions.sorted {
            $0.occurredAt.date < $1.occurredAt.date
        }
        for transaction in ordered {
            guard let kind = editorKind(for: transaction.kind) else { continue }
            let source = kind == .income ? transaction.toAccountID : transaction.fromAccountID
            guard let accountID = accountIDs[source] else {
                result.failures += 1
                continue
            }
            let destinationID = accountIDs[transaction.toAccountID] ?? ""

            do {
                try await backend.saveTransaction(
                    id: "",
                    kind: kind,
                    accountID: accountID,
                    destinationID: kind == .transfer ? destinationID : "",
                    title: transaction.title,
                    category: transaction.category,
                    amount: transaction.amount.decimalValue,
                    destinationAmount: transaction.hasDestinationAmount
                        ? transaction.destinationAmount.decimalValue
                        : nil,
                    currency: transaction.amount.currencyCode,
                    note: transaction.note,
                    date: transaction.hasOccurredAt ? transaction.occurredAt.date : Date()
                )
                result.transactions += 1
            } catch {
                result.failures += 1
            }
        }

        for stored in snapshot.budgets {
            do {
                try await backend.upsertBudget(
                    id: "",
                    monthKey: stored.month,
                    title: stored.budget.title,
                    category: stored.budget.category,
                    limit: stored.budget.limit.decimalValue,
                    currency: stored.budget.limit.currencyCode,
                    reminder: stored.budget.reminderEnabled,
                    paymentDate: date(fromKey: stored.budget.paymentDate) ?? Date(),
                    recurrence: stored.budget.recurrence
                )
                result.budgets += 1
            } catch {
                result.failures += 1
            }
        }

        for goal in snapshot.goals {
            guard let accountID = accountIDs[goal.accountID] else {
                result.failures += 1
                continue
            }
            do {
                try await backend.upsertGoal(
                    id: "",
                    title: goal.title,
                    accountID: accountID,
                    category: goal.category,
                    target: goal.target.decimalValue,
                    currency: goal.target.currencyCode
                )
                result.goals += 1
            } catch {
                result.failures += 1
            }
        }

        // Balances last, and set outright rather than accumulated. Accounts
        // were created empty and rebuilt by replaying transactions, which
        // reproduces neither an opening balance nor a balance the user edited by
        // hand — so the final figure is stated, and any transaction that failed
        // to migrate cannot leave the account short.
        for account in snapshot.accounts {
            guard let serverID = accountIDs[account.id] else { continue }
            do {
                try await backend.updateAccount(
                    id: serverID,
                    name: account.name,
                    symbol: account.symbolName,
                    balance: account.balance.decimalValue,
                    currency: account.balance.currencyCode,
                    isArchived: account.isArchived
                )
            } catch {
                result.failures += 1
            }
        }

        // The local file is only cleared when everything landed. Anything left
        // behind is still there to try again or to read, which is the whole
        // point of not deleting it optimistically.
        if result.failures == 0 {
            await local.removeAll()
        }
        return result
    }

    private static func editorKind(for kind: Finance_TransactionKind) -> TransactionEditorKind? {
        switch kind {
        case .expense: .expense
        case .income: .income
        case .transfer: .transfer
        default: nil
        }
    }

    private static func currentMonthKey() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: Date())
    }

    private static func date(fromKey value: String) -> Date? {
        guard value.count == 10 else { return nil }
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

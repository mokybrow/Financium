import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import SwiftProtobuf

/// Money kept by `money-service`, reached over gRPC.
///
/// This is the code that used to live inside `FinanceStore`; nothing about the
/// calls changed when it moved. The store now holds screen state and talks to
/// whichever backend the session is running on.
struct RemoteFinanceBackend: FinanceBackend {
    let auth: AuthSession
    private let endpoint = ServiceEndpoint.from(prefix: "FINANCIUM_FINANCE", defaultPort: 44044)

    // MARK: Reading

    func load(period: FinancePeriod, monthKey: String) async throws -> FinanceSnapshot {
        var snapshot = FinanceSnapshot()
        let interval = period.interval
        let explicitRange = period.explicitRange

        snapshot.overview = try await call { client, metadata in
            var request = Finance_GetOverviewRequest()
            request.month = monthKey
            // Only a real range travels; a month is left to the server so its
            // boundaries match the ones budgets are read with.
            if let explicitRange {
                request.from = Google_Protobuf_Timestamp(date: explicitRange.start)
                request.to = Google_Protobuf_Timestamp(date: explicitRange.end)
            }
            return try await client.getOverview(request, metadata: metadata)
        }
        snapshot.accounts = snapshot.overview.accounts

        snapshot.transactions = try await call { client, metadata in
            var request = Finance_ListTransactionsRequest()
            request.from = Google_Protobuf_Timestamp(date: interval.start)
            request.to = Google_Protobuf_Timestamp(date: interval.end)
            request.limit = 200
            return try await client.listTransactions(request, metadata: metadata).transactions
        }
        snapshot.budgets = try await call { client, metadata in
            var request = Finance_ListBudgetsRequest(); request.month = monthKey
            return try await client.listBudgets(request, metadata: metadata).budgets
        }
        snapshot.goals = try await call { client, metadata in
            try await client.listGoals(Finance_ListGoalsRequest(), metadata: metadata).goals
        }
        snapshot.settings = try await call { client, metadata in
            try await client.getSettings(Finance_GetSettingsRequest(), metadata: metadata)
        }
        return snapshot
    }

    // MARK: Accounts

    func createAccount(name: String, symbol: String, opening: Decimal, currency: String) async throws {
        _ = try await call { client, metadata in
            var request = Finance_CreateAccountRequest()
            request.name = name
            request.symbolName = symbol
            request.openingBalance = Finance_Money(decimal: opening, currencyCode: currency)
            return try await client.createAccount(request, metadata: metadata)
        }
    }

    func updateAccount(
        id: String, name: String, symbol: String,
        balance: Decimal?, currency: String, isArchived: Bool
    ) async throws {
        _ = try await call { client, metadata in
            var request = Finance_UpdateAccountRequest()
            request.id = id
            request.name = name
            request.symbolName = symbol
            request.isArchived = isArchived
            if let balance {
                request.balance = Finance_Money(decimal: balance, currencyCode: currency)
            }
            return try await client.updateAccount(request, metadata: metadata)
        }
    }

    func deleteAccount(id: String) async throws {
        _ = try await call { client, metadata in
            var request = Finance_DeleteAccountRequest(); request.id = id
            return try await client.deleteAccount(request, metadata: metadata)
        }
    }

    // MARK: Sharing

    func shareAccount(id: String) async throws -> AccountInvite {
        let response = try await call { client, metadata in
            var request = Finance_ShareAccountRequest(); request.accountID = id
            return try await client.shareAccount(request, metadata: metadata)
        }
        return AccountInvite(code: response.inviteCode, url: URL(string: response.inviteURL))
    }

    func joinAccount(code: String) async throws -> Finance_Account {
        let response = try await call { client, metadata in
            var request = Finance_JoinAccountRequest(); request.inviteCode = code
            return try await client.joinAccount(request, metadata: metadata)
        }
        return response.account
    }

    func stopSharingAccount(id: String, memberID: String) async throws {
        _ = try await call { client, metadata in
            var request = Finance_StopSharingAccountRequest()
            request.accountID = id
            request.memberUserID = memberID
            return try await client.stopSharingAccount(request, metadata: metadata)
        }
    }

    // MARK: Transactions

    func saveTransaction(
        id: String, kind: TransactionEditorKind,
        accountID: String, destinationID: String,
        title: String, category: String,
        amount: Decimal, destinationAmount: Decimal?,
        currency: String, note: String, date: Date
    ) async throws {
        // The destination account's currency has to come from somewhere; the
        // store passes the amount already converted, so only the code is needed.
        let accounts = try await call { client, metadata in
            try await client.listAccounts(Finance_ListAccountsRequest(), metadata: metadata).accounts
        }
        let destinationCurrency = accounts.first { $0.id == destinationID }?.balance.currencyCode ?? currency

        _ = try await call { client, metadata in
            var request = Finance_CreateTransactionRequest()
            request.kind = kind.proto
            if kind == .income { request.toAccountID = accountID } else { request.fromAccountID = accountID }
            if kind == .transfer { request.toAccountID = destinationID }
            request.title = title
            request.category = category
            request.note = note
            request.amount = Finance_Money(decimal: amount, currencyCode: currency)
            request.destinationAmount = Finance_Money(
                decimal: destinationAmount ?? amount,
                currencyCode: destinationCurrency
            )
            request.occurredAt = Google_Protobuf_Timestamp(date: date)

            if id.isEmpty {
                return try await client.createTransaction(request, metadata: metadata)
            }
            var update = Finance_UpdateTransactionRequest()
            update.id = id
            update.transaction = request
            return try await client.updateTransaction(update, metadata: metadata)
        }
    }

    func deleteTransaction(id: String) async throws {
        _ = try await call { client, metadata in
            var request = Finance_DeleteTransactionRequest(); request.id = id
            return try await client.deleteTransaction(request, metadata: metadata)
        }
    }

    // MARK: Budgets

    func upsertBudget(
        id: String, monthKey: String, title: String, category: String,
        limit: Decimal, currency: String,
        reminder: Bool, paymentDate: Date, recurrence: Finance_BudgetRecurrence
    ) async throws {
        _ = try await call { client, metadata in
            var request = Finance_UpsertBudgetRequest()
            request.id = id
            request.month = monthKey
            request.title = title
            request.category = category
            request.limit = Finance_Money(decimal: limit, currencyCode: currency)
            request.reminderEnabled = reminder
            if reminder {
                request.paymentDate = Self.dateKey(paymentDate)
                request.recurrence = recurrence
            } else {
                request.recurrence = .once
            }
            return try await client.upsertBudget(request, metadata: metadata)
        }
    }

    func deleteBudget(id: String) async throws {
        _ = try await call { client, metadata in
            var request = Finance_DeleteBudgetRequest(); request.id = id
            return try await client.deleteBudget(request, metadata: metadata)
        }
    }

    // MARK: Goals

    func upsertGoal(
        id: String, title: String, accountID: String,
        category: String, target: Decimal, currency: String
    ) async throws {
        _ = try await call { client, metadata in
            var request = Finance_UpsertGoalRequest()
            request.id = id
            request.title = title
            request.accountID = accountID
            request.category = category
            request.target = Finance_Money(decimal: target, currencyCode: currency)
            return try await client.upsertGoal(request, metadata: metadata)
        }
    }

    func deleteGoal(id: String) async throws {
        _ = try await call { client, metadata in
            var request = Finance_DeleteGoalRequest(); request.id = id
            return try await client.deleteGoal(request, metadata: metadata)
        }
    }

    // MARK: Settings

    func updateSettings(
        currency: String, monthlyReminders: Bool, promoEmail: Bool, promoPush: Bool
    ) async throws {
        _ = try await call { client, metadata in
            var request = Finance_UpdateSettingsRequest()
            request.mainCurrencyCode = currency.uppercased()
            request.monthlyRemindersEnabled = monthlyReminders
            request.promoEmailEnabled = promoEmail
            request.promoPushEnabled = promoPush
            return try await client.updateSettings(request, metadata: metadata)
        }
    }

    // MARK: Plumbing

    static func dateKey(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private func call<T: Sendable>(
        _ action: (Finance_FinanceService.Client<HTTP2ClientTransport.Posix>, Metadata) async throws -> T
    ) async throws -> T {
        try await auth.withAuthorizedMetadata { metadata in
            try await GRPCCore.withGRPCClient(
                transport: .http2NIOPosix(
                    target: .dns(host: self.endpoint.host, port: self.endpoint.port),
                    transportSecurity: self.endpoint.useTLS ? .tls : .plaintext
                )
            ) { grpc in
                try await action(Finance_FinanceService.Client(wrapping: grpc), metadata)
            }
        }
    }
}

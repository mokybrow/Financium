import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import os
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

    /// Everything the screens need, in one connection and one round trip's worth
    /// of waiting.
    ///
    /// This used to be five separate `call`s. Each one stands up its own
    /// transport — DNS, TCP, TLS handshake — runs a single request and tears it
    /// down again, so a refresh paid that price five times over, in series. On
    /// a phone that is most of the wait; it is also most of the wait after
    /// every save, because a write ends with a refresh.
    ///
    /// Now one connection carries all five, one after another. Four fewer
    /// handshakes is where nearly all of the saving was.
    ///
    /// They were briefly issued concurrently with `async let`, which is faster
    /// still on paper and did not work: every request came back
    /// `clientIsStopped`. `withGRPCClient` shuts its client down as soon as the
    /// closure it was given returns, and child tasks spawned inside that
    /// closure are not part of what it waits for — so the connection was being
    /// torn down underneath requests that had only just been issued. Sequential
    /// calls are inside the closure's own execution and cannot lose that race.
    func load(period: FinancePeriod, monthKey: String) async throws -> FinanceSnapshot {
        let interval = period.interval
        let explicitRange = period.explicitRange

        return try await call { client, metadata in
            // Built first and then left alone, so the requests are plain `let`s
            // rather than mutable state read further down.
            let overviewRequest: Finance_GetOverviewRequest = {
                var request = Finance_GetOverviewRequest()
                request.month = monthKey
                // Only a real range travels; a month is left to the server so
                // its boundaries match the ones budgets are read with.
                if let explicitRange {
                    request.from = Google_Protobuf_Timestamp(date: explicitRange.start)
                    request.to = Google_Protobuf_Timestamp(date: explicitRange.end)
                }
                return request
            }()

            let transactionsRequest: Finance_ListTransactionsRequest = {
                var request = Finance_ListTransactionsRequest()
                request.from = Google_Protobuf_Timestamp(date: interval.start)
                request.to = Google_Protobuf_Timestamp(date: interval.end)
                request.limit = 200
                return request
            }()

            let budgetsRequest: Finance_ListBudgetsRequest = {
                var request = Finance_ListBudgetsRequest()
                request.month = monthKey
                return request
            }()

            // Each one named, because they share a single `call` whose
            // `#function` label would only ever say "load". When a refresh
            // fails, which of the five refused is the entire question.
            var snapshot = FinanceSnapshot()
            snapshot.overview = try await Self.traced("getOverview") {
                try await client.getOverview(overviewRequest, metadata: metadata)
            }
            snapshot.accounts = snapshot.overview.accounts
            snapshot.transactions = try await Self.traced("listTransactions") {
                try await client.listTransactions(transactionsRequest, metadata: metadata).transactions
            }
            snapshot.budgets = try await Self.traced("listBudgets") {
                try await client.listBudgets(budgetsRequest, metadata: metadata).budgets
            }
            snapshot.goals = try await Self.traced("listGoals") {
                try await client.listGoals(Finance_ListGoalsRequest(), metadata: metadata).goals
            }
            snapshot.settings = try await Self.traced("getSettings") {
                try await client.getSettings(Finance_GetSettingsRequest(), metadata: metadata)
            }
            return snapshot
        }
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

    /// Runs one request against a fresh connection, and says so if it fails.
    ///
    /// `label` defaults to the calling method, so every site names itself
    /// without being told to. What is logged is the code and the server's own
    /// message — the half that `localizedDescription` discards and the only
    /// half that ever explains anything, since a refusal like "RPC method is
    /// not registered in RBAC" reaches the app as a bare status code.
    private func call<T: Sendable>(
        label: String = #function,
        _ action: (Finance_FinanceService.Client<HTTP2ClientTransport.Posix>, Metadata) async throws -> T
    ) async throws -> T {
        let started = ContinuousClock.now
        do {
            let value = try await connect(action)
            let elapsed = FinanceLog.milliseconds(since: started)
            FinanceLog.network.debug("\(label, privacy: .public) ok in \(elapsed, privacy: .public) ms")
            return value
        } catch {
            // `.public` on every part, deliberately. os.Logger redacts
            // interpolated values by default, and a diagnostic that prints
            // `<private> failed: <private>` is worse than none — it looks like
            // it is telling you something. None of this is anybody's data:
            // it is a method name, a duration and a status code.
            let elapsed = FinanceLog.milliseconds(since: started)
            let detail = FinanceLog.describe(error)
            FinanceLog.network.error(
                "\(label, privacy: .public) failed after \(elapsed, privacy: .public) ms: \(detail, privacy: .public)"
            )
            throw error
        }
    }

    /// Names a single request inside a shared connection.
    private static func traced<T: Sendable>(
        _ label: String,
        _ body: () async throws -> T
    ) async throws -> T {
        do {
            return try await body()
        } catch {
            let detail = FinanceLog.describe(error)
            FinanceLog.network.error("\(label, privacy: .public) failed: \(detail, privacy: .public)")
            throw error
        }
    }

    private func connect<T: Sendable>(
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

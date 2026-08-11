import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import Security
import SwiftProtobuf

private struct ServiceEndpoint {
    let host: String
    let port: Int
    let useTLS: Bool

    static func from(prefix: String, defaultPort: Int) -> Self {
        let info = Bundle.main.infoDictionary ?? [:]
        let host = (info["\(prefix)_HOST"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let portValue = info["\(prefix)_PORT"]
        let port = (portValue as? NSNumber)?.intValue ?? (portValue as? String).flatMap(Int.init)
        let tlsValue = info["\(prefix)_TLS"]
        let tls = (tlsValue as? NSNumber)?.boolValue ?? (tlsValue as? String).flatMap {
            switch $0.lowercased() {
            case "1", "true", "yes": true
            case "0", "false", "no": false
            default: nil
            }
        }
        return Self(host: host?.isEmpty == false ? host! : "127.0.0.1", port: port ?? defaultPort, useTLS: tls ?? false)
    }
}

private enum SecureTokens {
    static let service = "com.gofinancium.Financium.auth"

    static func read(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func write(_ value: String, key: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let data = Data(value.utf8)
        if SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess {
            return true
        }
        var insert = base
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    static func remove(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}

@MainActor
final class AuthSession: ObservableObject {
    static let appID = "financium-app"
    private static let accessKey = "access_token"
    private static let refreshKey = "refresh_token"

    @Published private(set) var isAuthenticated = false
    @Published private(set) var isWorking = false
    @Published private(set) var user: User_User?
    @Published var errorMessage: String?

    private let authEndpoint = ServiceEndpoint.from(prefix: "FINANCIUM_AUTH", defaultPort: 44044)
    private let userEndpoint = ServiceEndpoint.from(prefix: "FINANCIUM_USERS", defaultPort: 44044)
    private var refreshTask: Task<Bool, Never>?

    init() {
        isAuthenticated = SecureTokens.read(Self.accessKey) != nil || SecureTokens.read(Self.refreshKey) != nil
    }

    func bootstrap() async {
        guard isAuthenticated else { return }
        if await authorizedMetadata() != nil { await loadUser() }
    }

    static func makeAppleNonce(length: Int = 32) -> String? {
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var bytes = [UInt8](repeating: 0, count: length)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    static func appleNonceHash(_ nonce: String) -> String {
        SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func signIn(credential: ASAuthorizationAppleIDCredential, nonce: String) async {
        guard let data = credential.identityToken,
              let identityToken = String(data: data, encoding: .utf8),
              !nonce.isEmpty else {
            errorMessage = "Apple ID не вернул токен входа"
            return
        }
        let name = PersonNameComponentsFormatter.localizedString(
            from: credential.fullName ?? PersonNameComponents(), style: .default, options: []
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let pair = try await withAuthClient { client in
                var request = Auth_SignInWithAppleRequest()
                request.identityToken = identityToken
                request.name = name
                request.appID = Self.appID
                request.nonce = nonce
                return try await client.signInWithApple(request, metadata: self.publicMetadata())
            }
            guard SecureTokens.write(pair.accessToken, key: Self.accessKey),
                  SecureTokens.write(pair.refreshToken, key: Self.refreshKey) else {
                throw NSError(domain: "Financium", code: 1, userInfo: [NSLocalizedDescriptionKey: "Не удалось сохранить сессию"])
            }
            isAuthenticated = true
            await loadUser()
        } catch {
            errorMessage = "Не удалось войти через Apple ID. \(error.localizedDescription)"
        }
    }

    func loadUser() async {
        guard isAuthenticated else { return }
        do {
            user = try await withAuthorizedMetadata { metadata in
                try await self.withUserClient { client in
                    try await client.getCurrentUser(User_GetCurrentUserRequest(), metadata: metadata)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateName(_ name: String) async -> Bool {
        do {
            let response = try await withAuthorizedMetadata { metadata in
                try await self.withUserClient { client in
                    var request = User_UpdateNameRequest()
                    request.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    return try await client.updateName(request, metadata: metadata)
                }
            }
            if response.hasUser { user = response.user } else { await loadUser() }
            return response.success
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func initiateEmailChange(_ email: String) async -> Bool {
        await authMutation { client, metadata in
            var request = Auth_InitiateChangeEmailRequest()
            request.newEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
            return try await client.initiateChangeEmail(request, metadata: metadata).success
        }
    }

    func confirmEmailChange(_ code: String) async -> Bool {
        let success = await authMutation { client, metadata in
            var request = Auth_ConfirmChangeEmailRequest()
            request.code = code.trimmingCharacters(in: .whitespacesAndNewlines)
            return try await client.confirmChangeEmail(request, metadata: metadata).success
        }
        if success { await loadUser() }
        return success
    }

    func logout() {
        let refresh = SecureTokens.read(Self.refreshKey)
        SecureTokens.remove(Self.accessKey)
        SecureTokens.remove(Self.refreshKey)
        user = nil
        isAuthenticated = false
        if let refresh {
            Task {
                try? await withAuthClient { client in
                    var request = Auth_LogoutRequest()
                    request.refreshToken = refresh
                    _ = try await client.logout(request, metadata: self.publicMetadata())
                }
            }
        }
    }

    func withAuthorizedMetadata<T: Sendable>(_ action: (Metadata) async throws -> T) async throws -> T {
        guard let metadata = await authorizedMetadata() else {
            throw RPCError(code: .unauthenticated, message: "Authentication required")
        }
        do { return try await action(metadata) }
        catch {
            guard await refresh(), let retry = bearerMetadata else { throw error }
            return try await action(retry)
        }
    }

    private func authorizedMetadata() async -> Metadata? {
        if let access = SecureTokens.read(Self.accessKey), !tokenExpired(access) { return bearerMetadata }
        return await refresh() ? bearerMetadata : nil
    }

    private var bearerMetadata: Metadata? {
        guard let access = SecureTokens.read(Self.accessKey) else { return nil }
        var metadata: Metadata = [:]
        metadata.addString("Bearer \(access)", forKey: "authorization")
        return metadata
    }

    private func refresh() async -> Bool {
        if let refreshTask { return await refreshTask.value }
        let task = Task<Bool, Never> { [weak self] in
            guard let self, let token = SecureTokens.read(Self.refreshKey) else { return false }
            do {
                let pair = try await self.withAuthClient { client in
                    var request = Auth_RefreshRequest()
                    request.refreshToken = token
                    request.appID = Self.appID
                    return try await client.refresh(request, metadata: self.publicMetadata())
                }
                return SecureTokens.write(pair.accessToken, key: Self.accessKey)
                    && SecureTokens.write(pair.refreshToken, key: Self.refreshKey)
            } catch {
                return false
            }
        }
        refreshTask = task
        defer { refreshTask = nil }
        let success = await task.value
        if !success { logout() }
        return success
    }

    private func authMutation(
        _ action: (Auth_AuthService.Client<HTTP2ClientTransport.Posix>, Metadata) async throws -> Bool
    ) async -> Bool {
        do {
            return try await withAuthorizedMetadata { metadata in
                try await self.withAuthClient { client in try await action(client, metadata) }
            }
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func withAuthClient<T: Sendable>(
        _ action: (Auth_AuthService.Client<HTTP2ClientTransport.Posix>) async throws -> T
    ) async throws -> T {
        try await withClient(endpoint: authEndpoint) { client in
            try await action(Auth_AuthService.Client(wrapping: client))
        }
    }

    private func withUserClient<T: Sendable>(
        _ action: (User_UserService.Client<HTTP2ClientTransport.Posix>) async throws -> T
    ) async throws -> T {
        try await withClient(endpoint: userEndpoint) { client in
            try await action(User_UserService.Client(wrapping: client))
        }
    }

    private func withClient<T: Sendable>(endpoint: ServiceEndpoint, _ action: (GRPCClient<HTTP2ClientTransport.Posix>) async throws -> T) async throws -> T {
        try await GRPCCore.withGRPCClient(
            transport: .http2NIOPosix(
                target: .dns(host: endpoint.host, port: endpoint.port),
                transportSecurity: endpoint.useTLS ? .tls : .plaintext
            )
        ) { client in
            try await action(client)
        }
    }

    private func publicMetadata() -> Metadata {
        var metadata: Metadata = [:]
        metadata.addString(Self.appID, forKey: "x-app-id")
        return metadata
    }

    private func tokenExpired(_ token: String) -> Bool {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return true }
        var value = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let data = Data(base64Encoded: value),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let expiry = object["exp"] as? TimeInterval else { return true }
        return expiry <= Date().timeIntervalSince1970 + 300
    }
}

@MainActor
final class FinanceStore: ObservableObject {
    @Published private(set) var overview = Finance_GetOverviewResponse()
    @Published private(set) var accounts: [Finance_Account] = []
    @Published private(set) var transactions: [Finance_Transaction] = []
    @Published private(set) var budgets: [Finance_Budget] = []
    @Published private(set) var goals: [Finance_Goal] = []
    @Published private(set) var settings = Finance_FinanceSettings()
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var selectedMonth = Date()

    private let auth: AuthSession
    private let endpoint = ServiceEndpoint.from(prefix: "FINANCIUM_FINANCE", defaultPort: 50071)

    init(auth: AuthSession) { self.auth = auth }

    var monthKey: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: selectedMonth)
    }

    func refresh() async {
        guard auth.isAuthenticated else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            overview = try await call { client, metadata in
                var request = Finance_GetOverviewRequest(); request.month = self.monthKey
                return try await client.getOverview(request, metadata: metadata)
            }
            accounts = overview.accounts
            if let interval = Calendar(identifier: .gregorian).dateInterval(of: .month, for: selectedMonth) {
                transactions = try await call { client, metadata in
                    var request = Finance_ListTransactionsRequest()
                    request.from = Google_Protobuf_Timestamp(date: interval.start)
                    request.to = Google_Protobuf_Timestamp(date: interval.end)
                    request.limit = 200
                    return try await client.listTransactions(request, metadata: metadata).transactions
                }
            } else {
                transactions = overview.recentTransactions
            }
            budgets = try await call { client, metadata in
                var request = Finance_ListBudgetsRequest(); request.month = self.monthKey
                return try await client.listBudgets(request, metadata: metadata).budgets
            }
            goals = try await call { client, metadata in
                try await client.listGoals(Finance_ListGoalsRequest(), metadata: metadata).goals
            }
            settings = try await call { client, metadata in
                try await client.getSettings(Finance_GetSettingsRequest(), metadata: metadata)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createAccount(name: String, symbol: String, opening: Decimal, currency: String) async -> Bool {
        await mutation {
            _ = try await self.call { client, metadata in
                var request = Finance_CreateAccountRequest()
                request.name = name; request.symbolName = symbol
                request.openingBalance = Finance_Money(decimal: opening, currencyCode: currency)
                return try await client.createAccount(request, metadata: metadata)
            }
        }
    }

    func deleteAccount(_ account: Finance_Account) async {
        _ = await mutation {
            _ = try await self.call { client, metadata in
                var request = Finance_DeleteAccountRequest(); request.id = account.id
                return try await client.deleteAccount(request, metadata: metadata)
            }
        }
    }

    func saveTransaction(id: String = "", kind: TransactionEditorKind, accountID: String, destinationID: String, title: String, category: String, amount: Decimal, currency: String, note: String, date: Date) async -> Bool {
        await mutation {
            _ = try await self.call { client, metadata in
                var request = Finance_CreateTransactionRequest()
                request.kind = kind.proto
                if kind == .income { request.toAccountID = accountID } else { request.fromAccountID = accountID }
                if kind == .transfer { request.toAccountID = destinationID }
                request.title = title; request.category = category; request.note = note
                request.amount = Finance_Money(decimal: amount, currencyCode: currency)
                let destinationCurrency = self.accounts.first { $0.id == destinationID }?.balance.currencyCode ?? currency
                request.destinationAmount = Finance_Money(decimal: amount, currencyCode: destinationCurrency)
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
    }

    func deleteTransaction(_ transaction: Finance_Transaction) async {
        _ = await mutation {
            _ = try await self.call { client, metadata in
                var request = Finance_DeleteTransactionRequest(); request.id = transaction.id
                return try await client.deleteTransaction(request, metadata: metadata)
            }
        }
    }

    func upsertBudget(id: String = "", category: String, limit: Decimal, reminder: Bool, paymentDay: Int) async -> Bool {
        await mutation {
            _ = try await self.call { client, metadata in
                var request = Finance_UpsertBudgetRequest()
                request.id = id; request.month = self.monthKey; request.category = category
                request.limit = Finance_Money(decimal: limit, currencyCode: self.settings.mainCurrencyCode.isEmpty ? "RUB" : self.settings.mainCurrencyCode)
                request.reminderEnabled = reminder; request.paymentDay = Int32(paymentDay)
                return try await client.upsertBudget(request, metadata: metadata)
            }
        }
    }

    func deleteBudget(_ budget: Finance_Budget) async {
        _ = await mutation {
            _ = try await self.call { client, metadata in
                var request = Finance_DeleteBudgetRequest(); request.id = budget.id
                return try await client.deleteBudget(request, metadata: metadata)
            }
        }
    }

    func upsertGoal(id: String = "", title: String, accountID: String, category: String, target: Decimal, saved: Decimal) async -> Bool {
        await mutation {
            _ = try await self.call { client, metadata in
                var request = Finance_UpsertGoalRequest()
                request.id = id; request.title = title; request.accountID = accountID; request.category = category
                let currency = self.settings.mainCurrencyCode.isEmpty ? "RUB" : self.settings.mainCurrencyCode
                request.target = Finance_Money(decimal: target, currencyCode: currency)
                request.saved = Finance_Money(decimal: saved, currencyCode: currency)
                return try await client.upsertGoal(request, metadata: metadata)
            }
        }
    }

    func deleteGoal(_ goal: Finance_Goal) async {
        _ = await mutation {
            _ = try await self.call { client, metadata in
                var request = Finance_DeleteGoalRequest(); request.id = goal.id
                return try await client.deleteGoal(request, metadata: metadata)
            }
        }
    }

    func updateSettings(currency: String, monthlyReminders: Bool, promoEmail: Bool, promoPush: Bool) async -> Bool {
        await mutation {
            self.settings = try await self.call { client, metadata in
                var request = Finance_UpdateSettingsRequest()
                request.mainCurrencyCode = currency.uppercased()
                request.monthlyRemindersEnabled = monthlyReminders
                request.promoEmailEnabled = promoEmail
                request.promoPushEnabled = promoPush
                return try await client.updateSettings(request, metadata: metadata)
            }
        }
    }

    private func mutation(_ operation: () async throws -> Void) async -> Bool {
        do {
            try await operation()
            await refresh()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
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

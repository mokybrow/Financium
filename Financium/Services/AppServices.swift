import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import Security
import SwiftProtobuf

/// Where a service lives, read from the app's Info.plist.
///
/// Not private: the remote backend needs it too, now that the gRPC calls live
/// beside it rather than inside the store.
struct ServiceEndpoint {
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
    private var refreshTask: Task<RefreshOutcome, Never>?

    init() {
        isAuthenticated = SecureTokens.read(Self.accessKey) != nil || SecureTokens.read(Self.refreshKey) != nil
    }

    func bootstrap() async {
        guard isAuthenticated else { return }
        // Optional again here on purpose: a launch with no connection is not a
        // failure worth reporting, and whichever error came back, the answer is
        // the same — carry on with what is cached and try later.
        if (try? await authorizedMetadata()) != nil { await loadUser() }
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
        let metadata = try await authorizedMetadata()
        do { return try await action(metadata) }
        catch {
            guard await refresh(), let retry = bearerMetadata else { throw error }
            return try await action(retry)
        }
    }

    /// Credentials for a call, or an error saying why there are none.
    ///
    /// The distinction is carried out rather than flattened to nil. "Sign in
    /// again" and "no connection" are different problems with different
    /// answers, and reporting the second as the first told an offline reader
    /// their session had ended when it had not.
    private func authorizedMetadata() async throws -> Metadata {
        if let access = SecureTokens.read(Self.accessKey), !tokenExpired(access), let metadata = bearerMetadata {
            return metadata
        }

        switch await refreshOutcome() {
        case .renewed:
            guard let metadata = bearerMetadata else {
                throw RPCError(code: .unauthenticated, message: "Authentication required")
            }
            return metadata
        case .rejected:
            throw RPCError(code: .unauthenticated, message: "Authentication required")
        case .unreachable:
            throw RPCError(code: .unavailable, message: "Could not reach the server")
        }
    }

    private var bearerMetadata: Metadata? {
        guard let access = SecureTokens.read(Self.accessKey) else { return nil }
        var metadata: Metadata = [:]
        metadata.addString("Bearer \(access)", forKey: "authorization")
        return metadata
    }

    /// Why a token refresh did not produce a new token.
    ///
    /// The distinction matters because only one of these means the session is
    /// over. Collapsing both to `false` — which is what this used to do — meant
    /// that opening the app on a train logged the reader out and threw away
    /// everything cached for them, for no reason other than that the server
    /// could not be reached.
    private enum RefreshOutcome {
        case renewed
        /// The server answered, and the answer was no.
        case rejected
        /// The server did not answer. Nothing is known about the session.
        case unreachable
    }

    private func refresh() async -> Bool {
        await refreshOutcome() == .renewed
    }

    private func refreshOutcome() async -> RefreshOutcome {
        if let refreshTask { return await refreshTask.value }

        let task = Task<RefreshOutcome, Never> { [weak self] in
            guard let self, let token = SecureTokens.read(Self.refreshKey) else { return .rejected }
            do {
                let pair = try await self.withAuthClient { client in
                    var request = Auth_RefreshRequest()
                    request.refreshToken = token
                    request.appID = Self.appID
                    return try await client.refresh(request, metadata: self.publicMetadata())
                }
                let stored = SecureTokens.write(pair.accessToken, key: Self.accessKey)
                    && SecureTokens.write(pair.refreshToken, key: Self.refreshKey)
                return stored ? .renewed : .rejected
            } catch let error as RPCError {
                return Self.endsSession(error) ? .rejected : .unreachable
            } catch {
                return .unreachable
            }
        }

        refreshTask = task
        defer { refreshTask = nil }
        let outcome = await task.value
        if outcome == .rejected { logout() }
        return outcome
    }

    /// True when the server has told us this session is finished.
    ///
    /// Anything else — no network, a timeout, a service that is down — leaves
    /// the tokens alone. They may well still be good, and the reader can try
    /// again when there is a connection.
    ///
    /// `permissionDenied` used to count and no longer does. The two codes say
    /// different things: `unauthenticated` is "I do not know who you are",
    /// which a stored token cannot answer, while `permissionDenied` is "I know
    /// who you are and the answer is no". Signing out over the second throws
    /// away a session that was working — and the gateway returns exactly that
    /// for any RPC missing from its role table, so a new endpoint could log
    /// people out of an app that was otherwise fine.
    private static func endsSession(_ error: RPCError) -> Bool {
        error.code == .unauthenticated
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

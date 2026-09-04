import AuthenticationServices
import Combine
import Foundation
import Security

/// Sign in with Apple, kept entirely on the device.
///
/// There is no server to hand the credential to, so nothing is verified against
/// one — the app reads the name and email Apple returns, remembers the stable
/// user id in the keychain, and that is the whole of "being signed in". Signing
/// in is required: it is what the shared-account and sync features hang their
/// identity on.
@MainActor
final class AppleAuth: ObservableObject {
    @Published private(set) var userID: String?
    @Published private(set) var fullName: String
    @Published private(set) var email: String
    @Published var errorMessage: String?

    /// Whether the app should show its main content rather than the sign-in
    /// screen.
    var isAuthenticated: Bool { userID != nil }

    private static let service = "com.gofinancium.Financium.apple-auth"
    private static let userIDKey = "apple_user_id"
    private static let nameKey = "finance.apple.name"
    private static let emailKey = "finance.apple.email"

    init() {
        userID = Self.keychainRead(Self.userIDKey)
        fullName = UserDefaults.standard.string(forKey: Self.nameKey) ?? ""
        email = UserDefaults.standard.string(forKey: Self.emailKey) ?? ""
    }

    /// Confirms with Apple that the stored credential is still good. A user who
    /// removed the app from their Apple ID should land back on the sign-in
    /// screen.
    func revalidate() async {
        guard let userID else { return }
        let provider = ASAuthorizationAppleIDProvider()
        let state = try? await provider.credentialState(forUserID: userID)
        if state == .revoked || state == .notFound {
            signOut()
        }
    }

    func signIn(credential: ASAuthorizationAppleIDCredential) {
        let id = credential.user
        guard !id.isEmpty else {
            errorMessage = NSLocalizedString("auth.apple.invalid_response", comment: "Apple ID response could not be read")
            return
        }
        Self.keychainWrite(id, key: Self.userIDKey)
        userID = id

        // Apple only sends the name and email on the *first* authorization for
        // an app; a later sign-in on a reinstall returns nil for both. Keep
        // whatever was there rather than blanking it.
        let name = PersonNameComponentsFormatter.localizedString(
            from: credential.fullName ?? PersonNameComponents(), style: .default, options: []
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            fullName = name
            UserDefaults.standard.set(name, forKey: Self.nameKey)
        }
        if let credentialEmail = credential.email, !credentialEmail.isEmpty {
            email = credentialEmail
            UserDefaults.standard.set(credentialEmail, forKey: Self.emailKey)
        }

        errorMessage = nil
    }

    func signOut() {
        Self.keychainDelete(Self.userIDKey)
        UserDefaults.standard.removeObject(forKey: Self.nameKey)
        UserDefaults.standard.removeObject(forKey: Self.emailKey)
        userID = nil
        fullName = ""
        email = ""
    }

    // MARK: - Keychain

    private static func keychainRead(_ key: String) -> String? {
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

    private static func keychainWrite(_ value: String, key: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let data = Data(value.utf8)
        if SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess {
            return
        }
        var insert = base
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(insert as CFDictionary, nil)
    }

    private static func keychainDelete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}

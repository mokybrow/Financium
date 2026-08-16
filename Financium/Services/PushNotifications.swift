import Combine
import Foundation
import UIKit
import UserNotifications

/// Remote notifications: asking for them, and telling the backend where to send
/// them.
///
/// Ported from Eatometer's `PushNotificationService`, minus everything Financium
/// has no use for — the in-app inbox, the badge bookkeeping, the delivered-
/// notification merge. What is left is the part that was missing entirely: the
/// app never called `registerForRemoteNotifications()`, so it never received a
/// device token and `push_devices` had no row for it. push-service was accepting
/// jobs for people whose phones it had never been told about.
///
/// The registration endpoint is sso-service's, over HTTP rather than gRPC,
/// because that is where `/push/register` lives and Eatometer already speaks to
/// it that way.
@MainActor
final class PushNotifications: NSObject, ObservableObject {
    static let shared = PushNotifications()

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    /// A deep link from a tapped notification, waiting for the app to be ready.
    ///
    /// The tap can arrive before the session is restored — a cold start from a
    /// notification is exactly that case — so it is held rather than acted on.
    @Published private(set) var pendingDeepLink: URL?

    private let storedTokenKey = "apns_device_token"
    private let didAskKey = "apns_permission_requested"

    private struct RegisterRequest: Encodable {
        let token: String
        let environment: String
        let bundle_id: String
        let app_version: String
    }

    private struct UnregisterRequest: Encodable {
        let token: String
    }

    /// Constructible from anywhere, so `shared` can be a plain `static let` and
    /// a view can hold it in a property initialiser without hopping actors to
    /// build something that only sets two defaults.
    nonisolated override init() {
        super.init()
    }

    // MARK: - Lifecycle

    /// Called once at launch, before any notification can arrive.
    func configure() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Brings the device's registration up to date with the current session.
    ///
    /// Safe to call repeatedly: on every launch, and again whenever somebody
    /// signs in. A token issued while signed out cannot be registered against
    /// anybody, so it is kept and sent when there is finally an account to
    /// attach it to — which is the ordinary case on a second device, where the
    /// invite is opened before the person has signed in.
    func activate(auth: AuthSession) async {
        configure()

        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            registerForRemoteNotifications()
            await syncStoredToken(auth: auth)
        case .notDetermined:
            // Asked once, on the first launch that reaches a signed-in state.
            // Asking again after a refusal is not permitted by iOS anyway, and
            // the flag keeps the app from re-prompting on every cold start in
            // the window before the answer is recorded.
            guard !UserDefaults.standard.bool(forKey: didAskKey) else { return }
            await requestAuthorization(auth: auth)
        case .denied:
            break
        @unknown default:
            break
        }
    }

    /// Asks for permission, then registers if it was given.
    func requestAuthorization(auth: AuthSession) async {
        configure()
        UserDefaults.standard.set(true, forKey: didAskKey)

        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
            authorizationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            guard granted else { return }
            registerForRemoteNotifications()
            await syncStoredToken(auth: auth)
        } catch {
            // A refusal is not an error worth surfacing: the app works without
            // notifications, and there is nothing for the reader to do about it
            // from here.
            NSLog("Financium: push authorization failed: \(error.localizedDescription)")
        }
    }

    func consumePendingDeepLink(_ url: URL) {
        guard pendingDeepLink == url else { return }
        pendingDeepLink = nil
    }

    // MARK: - Token

    /// Called by the app delegate when APNs hands over a token.
    nonisolated func didRegister(deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in
            UserDefaults.standard.set(token, forKey: self.storedTokenKey)
        }
    }

    nonisolated func didFailToRegister(error: Error) {
        NSLog("Financium: APNs registration failed: \(error.localizedDescription)")
    }

    /// Sends the stored token to the backend, if there is one and somebody to
    /// attach it to.
    func syncStoredToken(auth: AuthSession) async {
        guard auth.isAuthenticated, let token = storedToken else { return }
        do {
            try await send(path: "/push/register", body: RegisterRequest(
                token: token,
                environment: Self.environment,
                bundle_id: Bundle.main.bundleIdentifier ?? "com.gofinancium.Financium",
                app_version: Self.appVersion
            ), auth: auth)
        } catch {
            NSLog("Financium: push token registration failed: \(error.localizedDescription)")
        }
    }

    /// Detaches this device before the session ends.
    ///
    /// Before, not after: the call needs the access token that signing out is
    /// about to throw away. Skipping it would leave the backend pushing one
    /// person's shared-account notifications to a phone somebody else is now
    /// signed in on.
    func unregisterCurrentDevice(auth: AuthSession) async {
        guard let token = storedToken else { return }
        do {
            try await send(path: "/push/unregister", body: UnregisterRequest(token: token), auth: auth)
        } catch {
            NSLog("Financium: push token unregistration failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Private

    private var storedToken: String? {
        UserDefaults.standard.string(forKey: storedTokenKey)
    }

    private func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    private func send(path: String, body: some Encodable, auth: AuthSession) async throws {
        guard let url = URL(string: Self.baseURL + path) else { throw URLError(.badURL) }
        guard let accessToken = await auth.currentAccessToken() else {
            throw URLError(.userAuthenticationRequired)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    /// Which APNs environment the token belongs to.
    ///
    /// Has to match `aps-environment` in the entitlements, and push-service
    /// stores it per device: a sandbox token filed as production is a
    /// notification that is accepted and then never delivered.
    private static var environment: String {
        #if DEBUG
        return "development"
        #else
        return "production"
        #endif
    }

    private static var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return short.isEmpty ? build : "\(short) (\(build))"
    }

    /// sso-service, which serves the two push endpoints over plain HTTP.
    private static var baseURL: String {
        let configured = Bundle.main.object(forInfoDictionaryKey: "FINANCIUM_AUTH_BASE_URL") as? String
        let trimmed = configured?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty, !trimmed.hasPrefix("$(") {
            return trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        }
        return "http://127.0.0.1:8080"
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension PushNotifications: UNUserNotificationCenterDelegate {
    /// Shown even while the app is open.
    ///
    /// A shared account is the one case where a notification arriving on screen
    /// is worth interrupting for: it means the figures being looked at have
    /// just been changed by somebody else.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let link = info["deep_link"] as? String, let url = URL(string: link) else { return }
        await MainActor.run { self.pendingDeepLink = url }
    }
}

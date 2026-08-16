import UIKit

/// Exists for two callbacks.
///
/// APNs hands the device token to the application delegate and nowhere else —
/// SwiftUI has no equivalent — so a delegate is required however little else it
/// does. Everything it receives is passed straight to `PushNotifications`.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Set here rather than on first use: a notification tapped to launch
        // the app is delivered to the delegate before any view exists, and a
        // centre with no delegate drops it.
        PushNotifications.shared.configure()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        PushNotifications.shared.didRegister(deviceToken: deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        PushNotifications.shared.didFailToRegister(error: error)
    }
}

import CloudKit
import UIKit

/// Handles the callbacks SwiftUI has no hook for: launch, remote notifications
/// (CloudKit's silent pushes), and scene configuration for shared-account links.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        PushNotifications.shared.configure()
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        guard let coordinator = FinanceStore.current?.syncCoordinator else { return .noData }
        await coordinator.handlePush()
        return .newData
    }

    func application(_ application: UIApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        FinanceStore.receiveShareInvitation(metadata)
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = connectingSceneSession.configuration
        configuration.delegateClass = ShareSceneDelegate.self
        return configuration
    }
}

/// SwiftUI still owns the window. UIKit delivers CloudKit invitations through
/// the scene delegate, including connection options when the app was closed.
@MainActor
final class ShareSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        if let metadata = connectionOptions.cloudKitShareMetadata {
            FinanceStore.receiveShareInvitation(metadata)
        }
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        userDidAcceptCloudKitShareWith metadata: CKShare.Metadata
    ) {
        FinanceStore.receiveShareInvitation(metadata)
    }
}

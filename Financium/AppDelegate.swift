import CloudKit
import UIKit

/// Handles the callbacks SwiftUI has no hook for: launch, remote notifications
/// (CloudKit's silent pushes), and the tap on a shared-account link.
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

    func application(
        _ application: UIApplication,
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        Task { await FinanceStore.current?.syncCoordinator?.acceptShare(cloudKitShareMetadata) }
    }
}

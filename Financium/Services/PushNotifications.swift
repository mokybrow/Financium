import Combine
import Foundation
import os
import UIKit
import UserNotifications

/// Notifications the app itself schedules, and the taps that come back.
///
/// There is no server any more, so nothing is registered against a backend and
/// no device token is sent anywhere. What is left is the local side: the
/// permission prompt for budget reminders (`BudgetReminders` schedules those),
/// showing a banner while the app is open, and turning a tapped notification
/// into a deep link the app can act on.
///
/// CloudKit's own change notifications are handled separately by
/// `CloudKitSyncEngine`, which owns its subscription and receives the silent
/// pushes directly.
@MainActor
final class PushNotifications: NSObject, ObservableObject {
    static let shared = PushNotifications()

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    /// A deep link from a tapped notification, waiting for the app to be ready.
    @Published private(set) var pendingDeepLink: URL?

    /// Constructible from anywhere, so `shared` can be a plain `static let`.
    nonisolated override init() {
        super.init()
    }

    /// Called once at launch, before any notification can arrive.
    func configure() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Brings `authorizationStatus` up to date. Safe to call on every launch.
    func activate() async {
        configure()
        authorizationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func consumePendingDeepLink(_ url: URL) {
        guard pendingDeepLink == url else { return }
        pendingDeepLink = nil
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension PushNotifications: UNUserNotificationCenterDelegate {
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

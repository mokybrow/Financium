import CloudKit
import Combine
import os

/// Whether this device can sync, and who it belongs to.
///
/// Replaces `AuthSession`. There is no sign-in any more: the identity is the
/// device's iCloud account, and the only question the app asks is whether one
/// is present. When it is, `FinanceStore` runs in `.icloud` mode and the
/// CloudKit sync engine mirrors the local ledger to the private database and
/// pulls shared accounts in. When it is not — no iCloud account on the device,
/// or the user has signed out of it — everything still works, kept on the
/// device alone.
@MainActor
final class iCloudAccount: ObservableObject {
    /// Whether CloudKit is usable right now.
    @Published private(set) var status: CKAccountStatus = .couldNotDetermine

    /// The current user's record id in the app's container, used to tell the
    /// owner of a shared account from a participant. Nil until the first
    /// successful lookup, and whenever there is no account.
    @Published private(set) var userRecordID: CKRecord.ID?

    /// True once `refresh()` has produced an answer, so the UI can hold a
    /// launch screen rather than flashing the "no sync" state before the
    /// account status is known.
    @Published private(set) var hasResolved = false

    var isAvailable: Bool { status == .available }

    private let container: CKContainer
    private var accountObserver: (any NSObjectProtocol)?

    init(container: CKContainer = .default()) {
        self.container = container
        accountObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    deinit {
        if let accountObserver { NotificationCenter.default.removeObserver(accountObserver) }
    }

    /// Re-reads the account status and, when there is one, the user's record id.
    func refresh() async {
        do {
            let status = try await container.accountStatus()
            self.status = status
            if status == .available {
                userRecordID = try? await container.userRecordID()
            } else {
                userRecordID = nil
            }
        } catch {
            FinanceLog.store.error("iCloud account status failed: \(String(describing: error), privacy: .public)")
            status = .couldNotDetermine
            userRecordID = nil
        }
        hasResolved = true
    }
}

import CloudKit
import CoreTransferable
import SwiftUI

/// Uses CloudKit's collaboration representation rather than exporting a URL
/// through an asynchronous data provider. The system can present its sharing
/// UI immediately and prepare a first-time share inside that UI.
nonisolated struct AccountShareItem: Transferable, Sendable {
    let accountID: String
    let existingShare: CKShare?

    static var transferRepresentation: some TransferRepresentation {
        CKShareTransferRepresentation { item in
            let container = CKContainer.default()
            if let share = item.existingShare {
                return .existing(share, container: container)
            }
            return .prepareShare(container: container) {
                guard let store = await FinanceStore.current else {
                    throw FinanceLedger.Failure.notFound
                }
                return try await store.prepareShareRecord(forAccountID: item.accountID)
            }
        }
    }
}

/// A real SwiftUI `ShareLink`, so the system anchors the menu to the toolbar
/// control and chooses the correct compact presentation itself.
struct AccountShareLinkButton: View {
    let accountID: String
    let accountName: String
    let existingShare: CKShare?
    let accessibilityLabel: LocalizedStringKey

    var body: some View {
        CloudShareLinkButton(
            item: AccountShareItem(accountID: accountID, existingShare: existingShare),
            title: accountName,
            accessibilityLabel: accessibilityLabel
        )
    }
}

/// Both account and plan menus use the same native control and toolbar anchor.
private struct CloudShareLinkButton<Item: Transferable>: View {
    let item: Item
    let title: String
    let accessibilityLabel: LocalizedStringKey

    var body: some View {
        ShareLink(
            item: item,
            preview: SharePreview(title, image: Image("AppIconPreview"), icon: Image("AppIconPreview"))
        ) {
            Label {
                Text(accessibilityLabel)
            } icon: {
                Image(systemName: "square.and.arrow.up")
            }
        }
        .tint(.primary)
        .accessibilityLabel(Text(accessibilityLabel))
    }
}

nonisolated struct PlanShareItem: Transferable, Sendable {
    let key: String
    let existingShare: CKShare?

    static var transferRepresentation: some TransferRepresentation {
        CKShareTransferRepresentation { item in
            let container = CKContainer.default()
            let options = CKAllowedSharingOptions(allowedParticipantPermissionOptions: .readWrite,
                                                  allowedParticipantAccessOptions: .specifiedRecipientsOnly)
            if let share = item.existingShare { return .existing(share, container: container, allowedSharingOptions: options) }
            return .prepareShare(container: container, allowedSharingOptions: options) {
                guard let store = await FinanceStore.current else { throw FinanceLedger.Failure.notFound }
                return try await store.preparePlanShare(key: item.key)
            }
        }
    }
}

struct PlanShareLinkButton: View {
    let key: String
    let title: String
    let existingShare: CKShare?

    var body: some View {
        CloudShareLinkButton(
            item: PlanShareItem(key: key, existingShare: existingShare),
            title: title,
            accessibilityLabel: "plan.share"
        )
    }
}

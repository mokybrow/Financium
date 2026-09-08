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
        ShareLink(
            item: AccountShareItem(accountID: accountID, existingShare: existingShare),
            preview: SharePreview(
                accountName,
                image: Image("AppIconPreview"),
                icon: Image("AppIconPreview")
            )
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

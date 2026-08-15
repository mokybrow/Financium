import SwiftUI

/// Turning an account into a shared one, and back.
///
/// Reached from the account's context menu. Sharing is deliberately not a
/// toggle: it produces something — a link — that has to be passed on before
/// anything has happened, and a switch that flips with nobody on the other end
/// would claim more than it did.
struct SharedAccountView: View {
    @EnvironmentObject private var store: FinanceStore
    @Environment(\.dismiss) private var dismiss

    let account: Finance_Account

    @State private var invite: AccountInvite?
    @State private var isWorking = false
    @State private var confirmStop = false

    /// The account as the store now has it, not as it was when the sheet opened.
    ///
    /// Sharing changes the member count, and the sheet should say so without
    /// being closed and reopened.
    private var current: Finance_Account {
        store.accounts.first { $0.id == account.id } ?? account
    }

    private var isShared: Bool { FinanceStore.isShared(current) }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: FITheme.Metrics.sectionSpacing) {
                    header

                    if let invite {
                        inviteSection(invite)
                    } else if !isShared {
                        FISection("shared.start") {
                            FIInlineActionRow("shared.start.action") {
                                Task { await share() }
                            }
                            .disabled(isWorking)
                        }
                        FIFootnote("shared.start.hint")
                    }

                    if isShared {
                        FISection("shared.stop") {
                            FIInlineActionRow("shared.stop.action", tint: FITheme.Palette.destructive) {
                                confirmStop = true
                            }
                            .disabled(isWorking)
                        }
                        FIFootnote("shared.stop.hint")
                    }
                }
                .fiCardInsets()
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .fiPageBackground()
            .navigationTitle(Text("shared.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
            .alert(Text("shared.stop.confirm"), isPresented: $confirmStop) {
                Button("shared.stop.action", role: .destructive) {
                    Task { await stop() }
                }
                Button("common.cancel", role: .cancel) {}
            } message: {
                Text("shared.stop.message")
            }
        }
        // An account already shared has an invite waiting; asking for it again
        // returns the same one, so the link is on screen without a tap.
        .task {
            guard isShared, invite == nil else { return }
            await share()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: current.name)
                .font(FITheme.Typography.screenTitle)
            memberSummary
                .font(FITheme.Typography.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, FITheme.Metrics.cardInset)
    }

    private var memberSummary: Text {
        isShared
            ? Text(verbatim: String(
                format: NSLocalizedString("shared.members.count", comment: "How many people share this"),
                Int(current.memberCount)
            ))
            : Text("shared.members.private")
    }

    @ViewBuilder
    private func inviteSection(_ invite: AccountInvite) -> some View {
        FISection("shared.invite") {
            FIListRow(
                title: Text("shared.invite.code"),
                accessory: .value(Text(verbatim: invite.code))
            )
        }

        if let url = invite.url {
            // A ShareLink rather than a button raising a share sheet: this view
            // is a sheet, and SwiftUI presents one at a time.
            ShareLink(item: url, subject: Text(verbatim: current.name)) {
                Text("shared.invite.send")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, FITheme.Metrics.cardInset)
        }

        FIFootnote("shared.invite.hint")
    }

    private func share() async {
        isWorking = true
        defer { isWorking = false }
        invite = await store.shareAccount(current)
    }

    private func stop() async {
        isWorking = true
        defer { isWorking = false }
        if await store.stopSharingAccount(current) {
            invite = nil
            dismiss()
        }
    }
}

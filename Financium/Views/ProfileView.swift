import CloudKit
import StoreKit
import SwiftUI

/// The profile sheet, opened from the avatar in the toolbar.
///
/// Avatar with a pencil to the appearance workshop, an "edit" button to a name
/// sheet, then finance settings, information and account management.
struct ProfileView: View {
    @EnvironmentObject private var account: iCloudAccount
    @EnvironmentObject private var auth: AppleAuth
    @EnvironmentObject private var profile: ProfileStore
    @EnvironmentObject private var store: FinanceStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.requestReview) private var requestReview

    @State private var showNameSheet = false
    @State private var showDeleteAccount = false
    @State private var showSignOut = false
    @State private var monthlyRemind = true

    private static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    private static let supportEmail = "mikhailpanin@icloud.com"

    /// The App Store item id. Empty until the app has a store page — fill in the
    /// numeric id from App Store Connect after the first submission and the
    /// share link points there instead of the site.
    private static let appStoreID = ""
    private static var shareAppURL: URL {
        appStoreID.isEmpty
            ? URL(string: "https://gofinancium.com")!
            : URL(string: "https://apps.apple.com/app/id\(appStoreID)")!
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: FITheme.Metrics.sectionSpacing) {
                    header

                    FISection("profile.section.general") {
                        NavigationLink {
                            CurrencyPickerView(selected: currencyCode, onSelect: updateCurrency)
                        } label: {
                            FIListRow(
                                title: Text("profile.main_currency"),
                                icon: "banknote",
                                accessory: .valueChevron(Text(verbatim: currencyCode))
                            )
                        }
                        .buttonStyle(.plain)

                        FIRowSeparator()

                        NavigationLink { CategoriesView() } label: {
                            FIListRow("profile.categories", icon: "square.grid.2x2", accessory: .chevron)
                        }
                        .buttonStyle(.plain)
                    }

                    FISection("profile.section.app") {
                        NavigationLink { AppIconPickerView() } label: {
                            FIListRow("profile.app_icon", icon: "app.badge", accessory: .chevron)
                        }
                        .buttonStyle(.plain)

                        FIRowSeparator()

                        FIListRow(
                            title: Text("profile.sync"),
                            icon: "arrow.triangle.2.circlepath",
                            accessory: .value(Text(syncStatusKey))
                        )
                    }

                    FISection("profile.notifications") {
                        FIToggleRow("profile.notifications.monthly", isOn: $monthlyRemind)
                    }

                    FISection("profile.section.legal") {
                        // Privacy policy — kept in the list but not wired up yet.
                        FIListRow("profile.privacy", icon: "hand.raised", accessory: .chevron)

                        FIRowSeparator()

                        Button { openURL(Self.termsURL) } label: {
                            FIListRow("profile.terms", icon: "doc.text", accessory: .chevron)
                        }
                        .buttonStyle(.plain)
                    }

                    FISection("profile.section.support") {
                        Button { openSupportMail() } label: {
                            FIListRow("profile.support.contact", icon: "headphones", accessory: .chevron)
                        }
                        .buttonStyle(.plain)

                        FIRowSeparator()

                        ShareLink(item: Self.shareAppURL) {
                            FIListRow("profile.support.share", icon: "square.and.arrow.up", accessory: .chevron)
                        }
                        .buttonStyle(.plain)

                        FIRowSeparator()

                        Button { requestReview() } label: {
                            FIListRow("profile.support.rate", icon: "star", accessory: .chevron)
                        }
                        .buttonStyle(.plain)
                    }

                    FISection("profile.section.management") {
                        FIListRow(
                            "profile.account.delete",
                            titleColor: FITheme.Palette.destructive,
                            icon: "trash",
                            iconColor: FITheme.Palette.destructive
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { showDeleteAccount = true }

                        FIRowSeparator()

                        FIListRow(
                            "profile.logout",
                            titleColor: FITheme.Palette.destructive,
                            icon: "rectangle.portrait.and.arrow.right",
                            iconColor: FITheme.Palette.destructive
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { showSignOut = true }
                    }

                    Text(verbatim: versionFootnote)
                        .font(FITheme.Typography.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                }
                .fiCardInsets()
                .padding(.top, 4)
                .padding(.bottom, 28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .fiPageBackground()
            .fiSheetChrome("profile.title", onClose: { dismiss() })
            .alert(Text("profile.account.delete.confirm"), isPresented: $showDeleteAccount) {
                Button("profile.account.delete", role: .destructive) { deleteAccount() }
                Button("common.cancel", role: .cancel) {}
            } message: {
                Text("profile.account.delete.message")
            }
            .alert(Text("profile.logout.confirm"), isPresented: $showSignOut) {
                Button("profile.logout", role: .destructive) {
                    auth.signOut()
                    dismiss()
                }
                Button("common.cancel", role: .cancel) {}
            } message: {
                Text("profile.logout.message")
            }
            .sheet(isPresented: $showNameSheet) { ProfileNameSheet() }
            .onAppear { monthlyRemind = store.settings.monthlyRemindersEnabled }
            .onChange(of: store.settings) { _, settings in
                monthlyRemind = settings.monthlyRemindersEnabled
            }
            .onChange(of: monthlyRemind) { _, isOn in
                guard isOn else { pushReminderSetting(); return }
                Task {
                    if await store.requestReminderAuthorization() { pushReminderSetting() }
                    else { monthlyRemind = false }
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            FIAvatar(
                monogram: profile.monogram,
                colorHex: profile.colorHex,
                emoji: profile.emoji,
                monogramStyle: profile.monogramStyle,
                photo: profile.photo,
                size: 124
            )

            Text(verbatim: displayName)
                .font(.headline)

            Button { showNameSheet = true } label: {
                Text("profile.name.edit")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(FITheme.Palette.controlFill, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    // MARK: - Derived

    private var displayName: String {
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        if !auth.fullName.isEmpty { return auth.fullName }
        return NSLocalizedString("profile.name.not_set", comment: "No name yet")
    }

    private var currencyCode: String { store.mainCurrencyCode }

    private var syncStatusKey: LocalizedStringKey {
        store.mode == .icloud ? "profile.sync.on" : "profile.sync.off"
    }

    private var versionFootnote: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info["CFBundleVersion"] as? String ?? "1"
        return "Financium \(version) (\(build))"
    }

    // MARK: - Actions

    private func openSupportMail() {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = Self.supportEmail
        components.queryItems = [URLQueryItem(name: "subject", value: "Financium — \(versionFootnote)")]
        if let url = components.url { openURL(url) }
    }

    private func deleteAccount() {
        Task {
            await store.deleteEverything()
            await profile.deleteFromCloud()
            auth.signOut()
            dismiss()
        }
    }

    private func updateCurrency(_ code: String) {
        Task {
            _ = await store.updateSettings(
                currency: code, monthlyReminders: monthlyRemind,
                promoEmail: false, promoPush: false
            )
        }
    }

    private func pushReminderSetting() {
        guard monthlyRemind != store.settings.monthlyRemindersEnabled else { return }
        Task {
            _ = await store.updateSettings(
                currency: currencyCode, monthlyReminders: monthlyRemind,
                promoEmail: false, promoPush: false
            )
        }
    }
}

/// The profile-edit sheet: avatar with a pencil to the appearance workshop, and
/// the display name. Name defaults to the Apple account name.
struct ProfileNameSheet: View {
    @EnvironmentObject private var profile: ProfileStore
    @EnvironmentObject private var auth: AppleAuth
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                ZStack(alignment: .bottomTrailing) {
                    FIAvatar(
                        monogram: monogram,
                        colorHex: profile.colorHex,
                        emoji: profile.emoji,
                        monogramStyle: profile.monogramStyle,
                        photo: profile.photo,
                        size: 148
                    )
                    NavigationLink {
                        ProfileAppearanceEditorView()
                    } label: {
                        Image(systemName: "pencil")
                            .font(.callout.weight(.bold))
                            .foregroundStyle(.primary)
                            .padding(9)
                            .background(FITheme.Palette.controlFill, in: Circle())
                            .overlay(Circle().stroke(FITheme.Palette.pageBackground, lineWidth: 3))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 16)

                FICard {
                    FITextFieldRow("profile.name", text: $name)
                        .textContentType(.name)
                        .textInputAutocapitalization(.words)
                }
                .fiCardInsets()

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .fiPageBackground()
            .fiSheetChrome(
                title: Text("profile.title"),
                confirm: .confirm(isEnabled: true) { save(); dismiss() },
                onClose: { save(); dismiss() }
            )
        }
        .onAppear {
            name = profile.name.isEmpty ? auth.fullName : profile.name
        }
    }

    private var monogram: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? profile.monogram : String(trimmed.first!).uppercased()
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != profile.name else { return }
        profile.name = trimmed
        profile.commit()
    }
}

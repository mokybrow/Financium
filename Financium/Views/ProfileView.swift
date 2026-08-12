import SwiftUI

/// The Profile tab, per the mock-up: an avatar and name at the top, then
/// General / Security / Money / Notifications as separate labelled cards, and a
/// copyright line at the bottom.
///
/// Each row edits one thing and saves it on its own. The previous version had
/// "Save name" and "Save settings" buttons, which meant a user could leave the
/// screen having changed something that was never sent.
struct ProfileView: View {
    @EnvironmentObject private var auth: AuthSession
    @EnvironmentObject private var store: FinanceStore

    /// Cleared to send a local user back to the sign-in screen.
    @AppStorage("finance.local_mode") private var localMode = false

    @State private var nameEditor = false
    @State private var showLocalReset = false
    @State private var emailEditor = false
    @State private var showLogout = false
    @State private var monthlyRemind = true
    @State private var promoEmail = false
    @State private var promoPush = true

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: FITheme.Metrics.sectionSpacing) {
                    header

                    FISection("profile.general") {
                        // A name and an email belong to an account. Without one
                        // there is nothing to edit, so the rows are absent
                        // rather than present and inert.
                        if store.mode == .account {
                            Button {
                                nameEditor = true
                            } label: {
                                FIListRow(
                                    title: Text("profile.name"),
                                    accessory: .valueChevron(Text("common.edit"))
                                )
                            }
                            .buttonStyle(.plain)

                            FIRowSeparator()
                        }

                        NavigationLink {
                            AppIconPickerView()
                        } label: {
                            FIListRow(title: Text("profile.app_icon"), accessory: .chevron)
                        }
                        .buttonStyle(.plain)
                    }

                    if store.mode == .account {
                        FISection("profile.security") {
                            Button {
                                emailEditor = true
                            } label: {
                                FIListRow(
                                    title: Text("profile.email"),
                                    subtitle: Text(emailStatusKey),
                                    accessory: .valueChevron(Text("common.edit"))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    FISection("profile.money") {
                        NavigationLink {
                            CurrencyPickerView(selected: currencyCode, onSelect: updateCurrency)
                        } label: {
                            FIListRow(
                                title: Text("profile.main_currency"),
                                accessory: .valueChevron(Text(verbatim: currencyCode))
                            )
                        }
                        .buttonStyle(.plain)

                        FIRowSeparator()

                        NavigationLink {
                            CategoriesView()
                        } label: {
                            FIListRow(title: Text("profile.categories"), accessory: .chevron)
                        }
                        .buttonStyle(.plain)
                    }

                    FISection("profile.notifications") {
                        // Payment reminders are scheduled on the device, so they
                        // work either way.
                        FIToggleRow(
                            "profile.notifications.monthly",
                            subtitle: "profile.notifications.monthly.hint",
                            isOn: $monthlyRemind
                        )

                        // Promotional mail and pushes are sent from the server
                        // to an address it knows. Without an account there is no
                        // address and nothing to send, so the switches are
                        // absent rather than present and inert.
                        if store.mode == .account {
                            FIRowSeparator()
                            FIToggleRow("profile.notifications.promo_email", isOn: $promoEmail)
                            FIRowSeparator()
                            FIToggleRow("profile.notifications.promo_push", isOn: $promoPush)
                        }
                    }

                    if store.mode == .account {
                        FICard {
                            FIDestructiveRow("profile.logout") {
                                showLogout = true
                            }
                        }
                    } else {
                        FISection(footnote: Text("profile.local.hint")) {
                            FIInlineActionRow("profile.go_to_sign_in", centred: true) { localMode = false }
                            FIRowSeparator()
                            FIDestructiveRow("profile.local.reset") { showLocalReset = true }
                        }
                    }

                    FIFootnote("profile.copyright")
                }
                .fiCardInsets()
                .padding(.top, 4)
                .padding(.bottom, 28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .fiPageBackground()
            .navigationTitle(Text("profile.title"))
            .toolbarTitleDisplayMode(.inlineLarge)
            .sheet(isPresented: $nameEditor) { NameEditorView() }
            .sheet(isPresented: $emailEditor) { EmailChangeView() }
            .alert(Text("profile.logout.confirm"), isPresented: $showLogout) {
                Button("profile.logout", role: .destructive) { auth.logout() }
                Button("common.cancel", role: .cancel) {}
            } message: {
                Text("profile.logout.message")
            }
            .alert(Text("profile.local.reset.confirm"), isPresented: $showLocalReset) {
                Button("common.delete", role: .destructive) {
                    Task {
                        await store.localBackend.removeAll()
                        await store.refresh()
                    }
                }
                Button("common.cancel", role: .cancel) {}
            } message: {
                Text("profile.local.reset.message")
            }
            .onAppear(perform: syncToggles)
            .onChange(of: store.settings) { _, _ in syncToggles() }
            .onChange(of: monthlyRemind) { _, isOn in
                // Permission is asked for at the moment it starts to matter. A
                // refusal turns the switch back off rather than storing a
                // setting the system will not act on.
                guard isOn else {
                    pushNotificationSettings()
                    return
                }
                Task {
                    if await store.requestReminderAuthorization() {
                        pushNotificationSettings()
                    } else {
                        monthlyRemind = false
                    }
                }
            }
            .onChange(of: promoEmail) { _, _ in pushNotificationSettings() }
            .onChange(of: promoPush) { _, _ in pushNotificationSettings() }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            // Initials rather than a photo: there is no avatar upload, and a
            // generic silhouette says less than the user's own initial.
            Text(verbatim: initials)
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 108, height: 108)
                .background(FITheme.Palette.controlFill, in: RoundedRectangle(cornerRadius: 28, style: .continuous))

            Text(verbatim: displayName)
                .font(.headline)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var displayName: String {
        guard store.mode == .account else {
            return NSLocalizedString("profile.local.title", comment: "Working without an account")
        }
        let name = auth.user?.name ?? ""
        return name.isEmpty ? (auth.user?.email ?? "") : name
    }

    private var initials: String {
        guard let first = displayName.first else { return "?" }
        return String(first).uppercased()
    }

    private var emailStatusKey: LocalizedStringKey {
        (auth.user?.emailConfirmed ?? false) ? "profile.email.verified" : "profile.email.unverified"
    }

    private var currencyCode: String {
        store.mainCurrencyCode
    }

    // MARK: - Actions

    private func updateCurrency(_ code: String) {
        Task {
            _ = await store.updateSettings(
                currency: code,
                monthlyReminders: monthlyRemind,
                promoEmail: promoEmail,
                promoPush: promoPush
            )
        }
    }

    private func pushNotificationSettings() {
        guard monthlyRemind != store.settings.monthlyRemindersEnabled
                || promoEmail != store.settings.promoEmailEnabled
                || promoPush != store.settings.promoPushEnabled else { return }
        Task {
            _ = await store.updateSettings(
                currency: currencyCode,
                monthlyReminders: monthlyRemind,
                promoEmail: promoEmail,
                promoPush: promoPush
            )
        }
    }

    private func syncToggles() {
        monthlyRemind = store.settings.monthlyRemindersEnabled
        promoEmail = store.settings.promoEmailEnabled
        promoPush = store.settings.promoPushEnabled
    }
}

// MARK: - Name editor

private struct NameEditorView: View {
    @EnvironmentObject private var auth: AuthSession
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var working = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                FICard {
                    FITextFieldRow("profile.name", text: $name)
                        .textContentType(.name)
                        .textInputAutocapitalization(.words)
                }
                .fiCardInsets()
                .padding(.top, 12)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .fiPageBackground()
            .fiSheetChrome(
                title: Text("profile.name"),
                confirm: .confirm(isEnabled: !trimmed.isEmpty && !working) { submit() },
                onClose: { dismiss() }
            )
        }
        .presentationDetents([.height(220)])
        .presentationDragIndicator(.visible)
        .onAppear { name = auth.user?.name ?? "" }
    }

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        working = true
        Task {
            let updated = await auth.updateName(trimmed)
            working = false
            if updated { dismiss() }
        }
    }
}

// MARK: - Email change

private struct EmailChangeView: View {
    @EnvironmentObject private var auth: AuthSession
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var working = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: FITheme.Metrics.headerSpacing) {
                FICard {
                    FITextFieldRow("email.placeholder", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(codeSent)

                    // The code field appears only once there is a code to enter,
                    // so the sheet never asks for something the user cannot have.
                    if codeSent {
                        FIRowSeparator()
                        FITextFieldRow("email.code", text: $code, showsClearButton: false)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                    }
                }

                FIFootnote(codeSent ? "email.code.hint" : "email.change.hint")
            }
            .fiCardInsets()
            .padding(.top, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .fiPageBackground()
            .fiSheetChrome(
                title: Text("profile.email"),
                confirm: .confirm(isEnabled: isValid && !working) { submit() },
                onClose: { dismiss() }
            )
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private var isValid: Bool {
        if codeSent {
            return !code.trimmingCharacters(in: .whitespaces).isEmpty
        }
        // Not a full RFC check — just enough to catch the obvious typo before
        // spending a round trip and an email on it.
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("@") && trimmed.contains(".") && !trimmed.hasPrefix("@")
    }

    private func submit() {
        working = true
        Task {
            if codeSent {
                if await auth.confirmEmailChange(code) { dismiss() }
            } else if await auth.initiateEmailChange(email.trimmingCharacters(in: .whitespaces)) {
                codeSent = true
            }
            working = false
        }
    }
}

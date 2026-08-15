import AuthenticationServices
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var auth: AuthSession
    @EnvironmentObject private var finance: FinanceStore
    @EnvironmentObject private var rates: ExchangeRates
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: FinanceSection? = .money

    /// Set once the reader chooses to work without an account. Not persisted as
    /// a "logged in" flag — closing the app returns them to the choice, which is
    /// the honest thing to do when there is no account to remember them by.
    @AppStorage("finance.local_mode") private var localMode = false

    @State private var offerMigration = false
    @State private var migrating = false
    @State private var migrationReport: String?
    @State private var isBooting = true
    @State private var firstLoadTimedOut = false

    /// Whether the launch screen should stay up for the first read of the
    /// ledger.
    ///
    /// The session check finishes long before the ledger does, so releasing the
    /// splash on that alone handed the reader a Money screen with a heading and
    /// a blank space under it — the emptiest possible answer to "how much money
    /// do I have", given before anything had been asked. Held until the first
    /// load settles either way.
    ///
    /// Cached figures end the wait too: they are last night's numbers rather
    /// than this second's, but they are the reader's own and are worth more
    /// than a logo. Signed out, there is nothing to wait for.
    private var isLoadingFirstContent: Bool {
        guard auth.isAuthenticated, !firstLoadTimedOut else { return false }
        return !finance.hasLoaded && finance.loadFailure == nil && finance.accounts.isEmpty
    }

    /// An invite code waiting to be redeemed, and what came of it.
    @State private var pendingInvite: String?
    @State private var joinedAccountName: String?

    /// What the invite task watches.
    ///
    /// The session belongs in here as well as the code. A link tapped by
    /// somebody not yet signed in — which on a second device is the usual
    /// case — has to wait, and watching the code alone meant it waited
    /// forever: the guard returned, the code never changed, and nothing ever
    /// asked again. Signing in now moves this value and the held invite is
    /// redeemed.
    private struct InviteAttempt: Equatable {
        let code: String?
        let signedIn: Bool
    }

    private var inviteAttempt: InviteAttempt {
        InviteAttempt(code: pendingInvite, signedIn: auth.isAuthenticated)
    }

    var body: some View {
        ZStack {
            Group {
                if auth.isAuthenticated || localMode {
                    adaptiveContent
                        .task {
                            if auth.isAuthenticated { await auth.loadUser() }
                            await rates.refresh()
                            await finance.refresh()
                        }
                } else {
                    AuthView { localMode = true }
                }
            }

            // One screen for every wait that happens before there is anything to
            // look at: the cold start, the round trip to Apple after the
            // sign-in button is pressed, and the first read of the ledger.
            if isBooting || auth.isWorking || isLoadingFirstContent {
                LaunchScreen()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeOut(duration: 0.25), value: auth.isWorking)
        .animation(.easeOut(duration: 0.25), value: isLoadingFirstContent)
        // Insurance, not a schedule. Every path through `refresh()` ends in
        // either `hasLoaded` or `loadFailure`, so this should never fire — but
        // "should never" is a poor reason to let a splash screen be the last
        // thing somebody sees.
        .task {
            try? await Task.sleep(for: .seconds(8))
            firstLoadTimedOut = true
        }
        .task {
            // Held until the stored session has been checked, so the first thing
            // drawn is the screen the reader belongs on — rather than the
            // sign-in page flashing past on the way to their accounts.
            let started = ContinuousClock.now
            await auth.bootstrap()
            // And held a moment longer, so a warm start reads as a launch
            // instead of a flicker.
            try? await Task.sleep(until: started.advanced(by: .milliseconds(600)), clock: .continuous)
            withAnimation(.easeOut(duration: 0.25)) { isBooting = false }
        }
        .onChange(of: auth.isAuthenticated) { _, signedIn in
            // Signing in starts a fresh wait, so the escape hatch from the last
            // one must not still be latched open.
            firstLoadTimedOut = false
            finance.adopt(mode: signedIn ? .account : .local)
            Task {
                await finance.refresh()
                // Asked, not assumed: uploading someone's ledger is not a thing
                // to do quietly because they happened to sign in.
                if signedIn, await finance.localBackend.hasData { offerMigration = true }
            }
        }
        .onAppear {
            finance.adopt(mode: auth.isAuthenticated ? .account : .local)
        }
        .onChange(of: scenePhase) { _, phase in
            // Polling a shared account only while somebody is looking at it.
            // In the background there is nothing to update and no reason to
            // keep asking.
            switch phase {
            case .active:
                Task {
                    await finance.refresh()
                    finance.startLiveUpdates()
                }
            default:
                finance.stopLiveUpdates()
            }
        }
        .onOpenURL { url in
            // Held rather than acted on: an invite that arrives before the
            // session is ready would be redeemed as nobody.
            if let code = Self.inviteCode(from: url) { pendingInvite = code }
        }
        .task(id: inviteAttempt) {
            guard let code = pendingInvite, auth.isAuthenticated else { return }
            // Cleared after the call, not before. `id:` is what keeps this task
            // alive, so writing to `pendingInvite` first changed the id and
            // cancelled the very task making the request — the join was called
            // off mid-flight and the reader was told something had gone wrong,
            // by the app that had gone and done it.
            let account = await finance.joinAccount(code: code)
            pendingInvite = nil
            if let account {
                joinedAccountName = account.name
            }
        }
        .alert(
            Text("shared.joined.title"),
            isPresented: Binding(
                get: { joinedAccountName != nil },
                set: { if !$0 { joinedAccountName = nil } }
            )
        ) {
            Button("common.ok", role: .cancel) { joinedAccountName = nil }
        } message: {
            Text(verbatim: String(
                format: NSLocalizedString("shared.joined.message", comment: "Joined a shared account"),
                joinedAccountName ?? ""
            ))
        }
        .alert(Text("migration.offer.title"), isPresented: $offerMigration) {
            Button("migration.offer.move") { migrate() }
            Button("migration.offer.keep", role: .cancel) {}
        } message: {
            Text("migration.offer.message")
        }
        .alert(
            Text("migration.done.title"),
            isPresented: Binding(
                get: { migrationReport != nil },
                set: { if !$0 { migrationReport = nil } }
            )
        ) {
            Button("common.ok", role: .cancel) { migrationReport = nil }
        } message: {
            Text(verbatim: migrationReport ?? "")
        }
        .overlay {
            if migrating {
                ProgressView().controlSize(.large)
            }
        }
    }

    /// The invite code in `financium://join/<code>`, if that is what this is.
    ///
    /// Read from the path rather than a query item because the link is meant to
    /// be short enough to read out loud, and `?code=` doubles its length for
    /// nothing.
    private static func inviteCode(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "financium",
              url.host?.lowercased() == "join" else { return nil }
        let code = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return code.isEmpty ? nil : code
    }

    /// Uploads the local ledger and reports what landed.
    ///
    /// The count is shown even when everything worked: moving months of records
    /// is the kind of thing a person wants confirmed, not left to be inferred
    /// from the screen behind the sheet.
    private func migrate() {
        migrating = true
        Task {
            let result = await LocalDataMigration.run(from: finance.localBackend, to: RemoteFinanceBackend(auth: auth))
            await finance.refresh()
            migrating = false
            migrationReport = result.failures == 0
                ? String(
                    format: NSLocalizedString("migration.done.message", comment: "Everything moved"),
                    result.moved
                )
                : String(
                    format: NSLocalizedString("migration.done.partial", comment: "Some records stayed behind"),
                    result.moved, result.failures
                )
        }
    }

    @ViewBuilder
    private var adaptiveContent: some View {
        if horizontalSizeClass == .regular {
            NavigationSplitView {
                List(FinanceSection.allCases, selection: $selection) { section in
                    Label(section.titleKey, systemImage: section.symbol)
                        .tag(section)
                }
                .navigationTitle(Text(verbatim: "Financium"))
            } detail: {
                sectionView(selection ?? .money)
            }
        } else {
            TabView {
                sectionView(.money)
                    .tabItem { Label(FinanceSection.money.titleKey, systemImage: FinanceSection.money.symbol) }
                sectionView(.budget)
                    .tabItem { Label(FinanceSection.budget.titleKey, systemImage: FinanceSection.budget.symbol) }
                sectionView(.goals)
                    .tabItem { Label(FinanceSection.goals.titleKey, systemImage: FinanceSection.goals.symbol) }
                sectionView(.profile)
                    .tabItem { Label(FinanceSection.profile.titleKey, systemImage: FinanceSection.profile.symbol) }
            }
        }
    }

    @ViewBuilder
    private func sectionView(_ section: FinanceSection) -> some View {
        switch section {
        case .money: MoneyView()
        case .budget: BudgetView()
        case .goals: GoalsView()
        case .profile: ProfileView()
        }
    }
}

#Preview {
    let auth = AuthSession()
    ContentView()
        .environmentObject(auth)
        .environmentObject(FinanceStore(auth: auth))
        .environmentObject(FinanceCategoryStore())
        .environmentObject(ExchangeRates())
}

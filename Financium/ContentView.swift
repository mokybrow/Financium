import AuthenticationServices
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var auth: AuthSession
    @EnvironmentObject private var finance: FinanceStore
    @EnvironmentObject private var rates: ExchangeRates
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selection: FinanceSection? = .money

    /// Set once the reader chooses to work without an account. Not persisted as
    /// a "logged in" flag — closing the app returns them to the choice, which is
    /// the honest thing to do when there is no account to remember them by.
    @AppStorage("finance.local_mode") private var localMode = false

    @State private var offerMigration = false
    @State private var migrating = false
    @State private var migrationReport: String?
    @State private var isBooting = true

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
            // look at: the cold start, and the round trip to Apple after the
            // sign-in button is pressed.
            if isBooting || auth.isWorking {
                LaunchScreen()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeOut(duration: 0.25), value: auth.isWorking)
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

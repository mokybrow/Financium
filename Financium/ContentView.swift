import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var account: iCloudAccount
    @EnvironmentObject private var auth: AppleAuth
    @EnvironmentObject private var profile: ProfileStore
    @EnvironmentObject private var finance: FinanceStore
    @EnvironmentObject private var rates: ExchangeRates
    @StateObject private var push = PushNotifications.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: FinanceSection? = .money

    @State private var isBooting = true
    @State private var firstLoadTimedOut = false

    /// Whether the launch screen should stay up for the first read of the
    /// ledger.
    private var isLoadingFirstContent: Bool {
        guard auth.isAuthenticated, !firstLoadTimedOut else { return false }
        return !finance.hasLoaded && finance.loadFailure == nil && finance.accounts.isEmpty
    }

    var body: some View {
        ZStack {
            Group {
                if auth.isAuthenticated {
                    adaptiveContent
                        .task {
                            await account.refresh()
                            if account.isAvailable { finance.enableCloudSync() }
                            finance.adopt(mode: finance.resolvedMode())
                            profile.refreshFromCloud()
                            profile.seedNameIfEmpty(auth.fullName)
                            await auth.revalidate()
                            await rates.refresh()
                            await finance.refresh()
                            await push.activate()
                        }
                        .sheet(isPresented: $profile.isPresented) {
                            ProfileView()
                        }
                } else {
                    AuthView()
                }
            }

            if isBooting || isLoadingFirstContent {
                LaunchScreen()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeOut(duration: 0.25), value: isLoadingFirstContent)
        .animation(.easeOut(duration: 0.25), value: auth.isAuthenticated)
        .task {
            try? await Task.sleep(for: .seconds(8))
            firstLoadTimedOut = true
        }
        .task {
            let started = ContinuousClock.now
            await account.refresh()
            try? await Task.sleep(until: started.advanced(by: .milliseconds(400)), clock: .continuous)
            withAnimation(.easeOut(duration: 0.25)) { isBooting = false }
        }
        .onChange(of: auth.isAuthenticated) { _, signedIn in
            guard signedIn else { return }
            firstLoadTimedOut = false
            Task {
                await account.refresh()
                if account.isAvailable { finance.enableCloudSync() }
                finance.adopt(mode: finance.resolvedMode())
                profile.refreshFromCloud()
                profile.seedNameIfEmpty(auth.fullName)
                await finance.refresh()
            }
        }
        .onChange(of: account.status) { _, _ in
            firstLoadTimedOut = false
            Task { @MainActor in
                if account.isAvailable { finance.enableCloudSync() }
                finance.adopt(mode: finance.resolvedMode())
                profile.refreshFromCloud()
                await finance.refresh()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task {
                    await account.refresh()
                    profile.refreshFromCloud()
                    await finance.refresh()
                    finance.startLiveUpdates()
                }
            default:
                finance.stopLiveUpdates()
            }
        }
        .onOpenURL { url in
            handleWidgetLink(url)
        }
        .onChange(of: push.pendingDeepLink) { _, link in
            guard let link else { return }
            push.consumePendingDeepLink(link)
            Task { await finance.refresh() }
        }
    }

    /// Where the Home Screen tiles point.
    private func handleWidgetLink(_ url: URL) {
        guard url.scheme?.lowercased() == "financium" else { return }

        switch url.host?.lowercased() {
        case "new":
            selection = .money
            let kind = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "kind" }?.value
            finance.pendingQuickAdd = kind?.lowercased() == "income" ? .income : .expense
        case "money":
            selection = .money
        case "budgets", "budget":
            selection = .budget
        case "goals":
            selection = .goals
        default:
            break
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
            }
        }
    }

    @ViewBuilder
    private func sectionView(_ section: FinanceSection) -> some View {
        switch section {
        case .money: MoneyView()
        case .budget: BudgetView()
        case .goals: GoalsView()
        }
    }
}

#Preview {
    let account = iCloudAccount()
    ContentView()
        .environmentObject(account)
        .environmentObject(AppleAuth())
        .environmentObject(ProfileStore())
        .environmentObject(FinanceStore(account: account))
        .environmentObject(FinanceCategoryStore())
        .environmentObject(ExchangeRates())
}

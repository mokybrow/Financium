import AuthenticationServices
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var auth: AuthSession
    @EnvironmentObject private var finance: FinanceStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selection: FinanceSection? = .money

    var body: some View {
        Group {
            if auth.isAuthenticated {
                adaptiveContent
                    .task {
                        await auth.loadUser()
                        await finance.refresh()
                    }
            } else {
                AuthView()
                    .task { await auth.bootstrap() }
            }
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
}

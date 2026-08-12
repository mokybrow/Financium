import SwiftUI

@main
struct FinanciumApp: App {
    @StateObject private var auth: AuthSession
    @StateObject private var finance: FinanceStore
    @StateObject private var categories = FinanceCategoryStore()
    @StateObject private var rates = ExchangeRates()

    init() {
        let session = AuthSession()
        _auth = StateObject(wrappedValue: session)
        _finance = StateObject(wrappedValue: FinanceStore(auth: session))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(auth)
                .environmentObject(finance)
                .environmentObject(categories)
                .environmentObject(rates)
                .tint(.blue)
        }
    }
}

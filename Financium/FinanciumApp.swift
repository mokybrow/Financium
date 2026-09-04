import SwiftUI

@main
struct FinanciumApp: App {
    // APNs delivers the CloudKit change token to the application delegate, and
    // the delegate forwards remote notifications to the sync engine.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var account: iCloudAccount
    @StateObject private var auth = AppleAuth()
    @StateObject private var profile = ProfileStore()
    @StateObject private var finance: FinanceStore
    @StateObject private var categories = FinanceCategoryStore()
    @StateObject private var rates = ExchangeRates()

    init() {
        let account = iCloudAccount()
        _account = StateObject(wrappedValue: account)
        _finance = StateObject(wrappedValue: FinanceStore(account: account))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(account)
                .environmentObject(auth)
                .environmentObject(profile)
                .environmentObject(finance)
                .environmentObject(categories)
                .environmentObject(rates)
                .tint(.blue)
        }
    }
}

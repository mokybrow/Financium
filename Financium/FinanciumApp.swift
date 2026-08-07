import SwiftUI

@main
struct FinanciumApp: App {
    @StateObject private var auth: AuthSession
    @StateObject private var finance: FinanceStore

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
                .tint(.indigo)
        }
    }
}

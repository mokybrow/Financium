import SwiftUI

nonisolated struct FinancePlanBindingRequest: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let currency: String
    let accountID: String
    let category: String?
}

struct FinancePlanBindingView: View {
    @EnvironmentObject private var store: FinanceStore
    @EnvironmentObject private var categories: FinanceCategoryStore
    @Environment(\.dismiss) private var dismiss
    let key: String
    let currency: String
    let initialAccountID: String
    let initialCategory: String?
    var planTitle = ""
    @State private var accountID = ""
    @State private var category = ""
    @State private var saving = false

    private var accounts: [FinanceAccount] {
        store.accounts.filter { !$0.isArchived && $0.balance.currencyCode == currency }
    }
    private var options: [String] {
        var values = categories.options(for: .expense, existing: store.transactions)
        if !category.isEmpty && !values.contains(category) { values.append(category) }
        return values
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("plan.binding.account", selection: $accountID) {
                        Text("plan.binding.choose").tag("")
                        ForEach(accounts, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    if initialCategory != nil {
                        Picker("plan.binding.category", selection: $category) {
                            ForEach(options, id: \.self) { value in
                                Label(FinanceCategoryStore.displayName(for: value), systemImage: categories.symbol(for: value, kind: .expense)).tag(value)
                            }
                        }
                    }
                } header: {
                    if !planTitle.isEmpty { Text(verbatim: planTitle) }
                } footer: {
                    Text(initialCategory == nil ? "plan.binding.goal.help" : "plan.binding.budget.help")
                }
                if accounts.isEmpty { Text("plan.binding.empty").foregroundStyle(.secondary) }
            }
            .navigationTitle("plan.binding.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel", systemImage: "xmark") { dismiss() }.tint(.primary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save", systemImage: "checkmark") {
                        saving = true
                        Task {
                            if await store.bindSharedPlan(key: key, accountID: accountID, category: initialCategory == nil ? nil : category) { dismiss() }
                            saving = false
                        }
                    }.disabled(saving || accountID.isEmpty || (initialCategory != nil && category.isEmpty))
                }
            }
            .interactiveDismissDisabled(saving)
            .fiErrorAlert($store.errorMessage)
            .onAppear {
                accountID = accounts.contains { $0.id == initialAccountID } ? initialAccountID : ""
                category = initialCategory ?? ""
            }
        }
    }
}

import SwiftProtobuf
import SwiftUI
import UIKit

struct MoneyView: View {
    @EnvironmentObject private var store: FinanceStore
    @State private var transactionEditor: TransactionEditorKind?
    @State private var showAccountEditor = false
    @State private var activityKind: ActivityKind?
    @State private var accountActivity: Finance_Account?

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: FITheme.Metrics.sectionSpacing) {
                    FinancePeriodRow()
                    flowCard
                    accountsSection
                    activitySection
                }
                .fiCardInsets()
                .padding(.top, 4)
                .padding(.bottom, 28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .fiPageBackground()
            .navigationTitle(Text("money.title"))
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { addMenu }
            }
            .refreshable { await store.refresh() }
            .overlay {
                if store.isLoading && store.accounts.isEmpty { ProgressView() }
            }
            .navigationDestination(item: $activityKind) { kind in
                AccountActivityView(kind: kind)
            }
            .navigationDestination(item: $accountActivity) { account in
                AccountActivityView(account: account)
            }
            .sheet(item: $transactionEditor) { TransactionEditorView(kind: $0) }
            .sheet(isPresented: $showAccountEditor) { AccountEditorView() }
            .alert(Text("common.error"), isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )) {
                Button("common.ok", role: .cancel) { store.errorMessage = nil }
            } message: {
                Text(store.errorMessage ?? "")
            }
        }
    }

    private var flowCard: some View {
        FICard {
            FIListRow(title: Text("money.spended"), accessory: .value(Text(verbatim: approximate(store.overview.spent.formatted))))
            FIRowSeparator()
            FIListRow(title: Text("money.earned"), accessory: .value(Text(verbatim: approximate(store.overview.earned.formatted))))
        }
    }

    private func approximate(_ value: String) -> String {
        value.isEmpty ? value : "~" + value
    }

    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: FITheme.Metrics.headerSpacing) {
            FISectionHeader("money.accounts")
            FICard {
                if store.accounts.isEmpty {
                    FIEmptyState(title: "money.accounts.empty", subtitle: "money.accounts.empty.subtitle")
                    FIRowSeparator()
                    FIInlineActionRow("money.accounts.add") { showAccountEditor = true }
                } else {
                    ForEach(Array(store.accounts.enumerated()), id: \.element.id) { index, account in
                        if index > 0 { FIRowSeparator() }
                        accountRow(account)
                    }
                }
            }
        }
    }

    private func accountRow(_ account: Finance_Account) -> some View {
        Button {
            accountActivity = account
        } label: {
            FIListRow(title: Text(verbatim: account.name), subtitle: Text(verbatim: account.balance.formatted)) {
                HStack(spacing: 12) {
                    Image(systemName: accountSymbol(account))
                        .foregroundStyle(FITheme.Palette.accent)
                    FIChevron()
                }
            }
        }
        .buttonStyle(.plain)
        .id(account.id)
        .fiRowContextMenu {
            Button {
                UIPasteboard.general.string = account.balance.formatted
            } label: {
                Label("money.account.copy_balance", systemImage: "doc.on.doc")
            }
            Button(role: .destructive) {
                Task { await store.deleteAccount(account) }
            } label: {
                Label("money.account.delete", systemImage: "trash")
            }
        }
    }

    private func accountSymbol(_ account: Finance_Account) -> String {
        account.symbolName.isEmpty ? FinanceCurrencies.symbolName(for: account.balance.currencyCode) : account.symbolName
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: FITheme.Metrics.headerSpacing) {
            FISectionHeader("money.activity")
            FICard {
                Button { activityKind = .expenses } label: {
                    FIListRow(title: Text("money.activity.expenses"), accessory: .chevron)
                }
                .buttonStyle(.plain)
                FIRowSeparator()
                Button { activityKind = .incoming } label: {
                    FIListRow(title: Text("money.activity.incoming"), accessory: .chevron)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var addMenu: some View {
        FIToolbarAddButton {
            Button { transactionEditor = .income } label: {
                Label("money.add.incoming", systemImage: "arrow.down")
            }
            Button { transactionEditor = .expense } label: {
                Label("money.add.expense", systemImage: "arrow.up")
            }
            Button { transactionEditor = .transfer } label: {
                Label("money.add.transfer", systemImage: "arrow.up.arrow.down")
            }
            Divider()
            Button { showAccountEditor = true } label: {
                Label("money.accounts.add", systemImage: "creditcard")
            }
        }
    }
}

enum ActivityKind: String, Identifiable, Hashable {
    case expenses
    case incoming

    var id: String { rawValue }
    var titleKey: LocalizedStringKey {
        self == .expenses ? "activity.expenses.title" : "activity.incoming.title"
    }
}

private enum ActivitySort: String, CaseIterable, Identifiable {
    case dateDescending, dateAscending, valueDescending, valueAscending

    var id: String { rawValue }
    var titleKey: LocalizedStringKey {
        switch self {
        case .dateDescending: "activity.sort.date_desc"
        case .dateAscending: "activity.sort.date_asc"
        case .valueDescending: "activity.sort.value_desc"
        case .valueAscending: "activity.sort.value_asc"
        }
    }
}

private enum ActivityAccountFilter: String, CaseIterable, Identifiable {
    case all, cash, banks

    var id: String { rawValue }
    var titleKey: LocalizedStringKey {
        switch self {
        case .all: "activity.filter.all"
        case .cash: "activity.filter.cash"
        case .banks: "activity.filter.banks"
        }
    }
}

struct AccountActivityView: View {
    @EnvironmentObject private var store: FinanceStore
    private let kind: ActivityKind?
    private let account: Finance_Account?

    @State private var sort: ActivitySort = .dateDescending
    @State private var accountFilter: ActivityAccountFilter = .all
    @State private var currencyFilter = ""
    @State private var filtersVisible = false
    @State private var editingTransaction: Finance_Transaction?

    init(kind: ActivityKind) {
        self.kind = kind
        self.account = nil
    }

    init(account: Finance_Account) {
        self.kind = nil
        self.account = account
    }

    private var transactions: [Finance_Transaction] {
        let scoped = store.transactions.filter { transaction in
            if let account {
                return transaction.fromAccountID == account.id || transaction.toAccountID == account.id
            }
            switch kind {
            case .expenses: return transaction.kind == .expense
            case .incoming: return transaction.kind == .income
            case nil: return true
            }
        }
        let filtered = scoped.filter { transaction in
            guard account == nil else { return true }
            if !currencyFilter.isEmpty && transaction.amount.currencyCode != currencyFilter { return false }
            guard accountFilter != .all else { return true }
            guard let transactionAccount = account(for: transaction) else { return false }
            return accountFilter == .cash ? isCash(transactionAccount) : !isCash(transactionAccount)
        }
        return filtered.sorted(by: sortPredicate)
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: FITheme.Metrics.sectionSpacing) {
                if filtersVisible && account == nil { filterCard }
                FICard {
                    if transactions.isEmpty {
                        FIEmptyState(title: "activity.empty", subtitle: "activity.empty.subtitle")
                    } else {
                        ForEach(Array(transactions.enumerated()), id: \.element.id) { index, transaction in
                            if index > 0 { FIRowSeparator() }
                            row(transaction)
                        }
                    }
                }
            }
            .fiCardInsets()
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .fiPageBackground()
        .navigationTitle(account.map { Text(verbatim: $0.name) } ?? Text(kind?.titleKey ?? "activity.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                sortMenu
                if account == nil {
                    Button { filtersVisible.toggle() } label: {
                        Image(systemName: filtersVisible ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel(Text("activity.filter"))
                }
            }
        }
        .sheet(item: $editingTransaction) { TransactionEditorView(transaction: $0) }
    }

    private var filterCard: some View {
        FICard {
            Picker("activity.filter", selection: $accountFilter) {
                ForEach(ActivityAccountFilter.allCases) { filter in
                    Text(filter.titleKey).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, FITheme.Metrics.cardInset)
            .padding(.vertical, 10)

            FIRowSeparator()
            FIMenuRow("activity.filter.currency", value: currencyFilter.isEmpty ? String(localized: "activity.filter.all") : currencyFilter) {
                Button("activity.filter.all") { currencyFilter = "" }
                ForEach(availableCurrencies, id: \.self) { code in
                    Button { currencyFilter = code } label: {
                        if code == currencyFilter { Label(code, systemImage: "checkmark") } else { Text(verbatim: code) }
                    }
                }
            }
        }
    }

    private var sortMenu: some View {
        Menu {
            ForEach(ActivitySort.allCases) { option in
                Button { sort = option } label: {
                    if option == sort { Label(option.titleKey, systemImage: "checkmark") } else { Text(option.titleKey) }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel(Text("activity.sort"))
    }

    private func row(_ transaction: Finance_Transaction) -> some View {
        Button { editingTransaction = transaction } label: {
            FIListRow(
                title: Text(verbatim: transaction.title.isEmpty ? transaction.category : transaction.title),
                subtitle: Text(verbatim: subtitle(for: transaction))
            ) {
                HStack(spacing: 10) {
                    Text(verbatim: transaction.amount.formatted).foregroundStyle(.primary)
                    FIChevron()
                }
            }
        }
        .buttonStyle(.plain)
        .id(transaction.id)
        .fiRowContextMenu {
            Button { editingTransaction = transaction } label: {
                Label("common.edit", systemImage: "pencil")
            }
            Button(role: .destructive) {
                Task { await store.deleteTransaction(transaction) }
            } label: {
                Label("transaction.delete", systemImage: "trash")
            }
        }
    }

    private func subtitle(for transaction: Finance_Transaction) -> String {
        let day = transaction.hasOccurredAt ? transaction.occurredAt.date.formatted(.dateTime.day().month(.abbreviated)) : ""
        let accountName = account == nil ? account(for: transaction)?.name ?? "" : ""
        return [day, accountName].filter { !$0.isEmpty }.joined(separator: " – ")
    }

    private func account(for transaction: Finance_Transaction) -> Finance_Account? {
        let id = transaction.kind == .income ? transaction.toAccountID : transaction.fromAccountID
        return store.accounts.first { $0.id == id }
    }

    private func isCash(_ account: Finance_Account) -> Bool {
        let value = (account.name + " " + account.symbolName).lowercased()
        return value.contains("cash") || value.contains("налич") || value.contains("wallet") || value.contains("banknote")
    }

    private var availableCurrencies: [String] {
        Array(Set(store.transactions.map(\.amount.currencyCode).filter { !$0.isEmpty })).sorted()
    }

    private func sortPredicate(_ lhs: Finance_Transaction, _ rhs: Finance_Transaction) -> Bool {
        switch sort {
        case .dateDescending: return lhs.occurredAt.date > rhs.occurredAt.date
        case .dateAscending: return lhs.occurredAt.date < rhs.occurredAt.date
        case .valueDescending: return lhs.amount.minorUnits > rhs.amount.minorUnits
        case .valueAscending: return lhs.amount.minorUnits < rhs.amount.minorUnits
        }
    }
}

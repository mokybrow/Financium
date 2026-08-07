import SwiftUI
import UIKit
import SwiftProtobuf

/// The Money tab, per the mock-ups: the month and currency selectors, a
/// spended/earned card, the list of accounts, and links into the activity
/// lists.
///
/// The gradient balance hero card and the inline transactions list the previous
/// version had are gone: the mock-ups put the totals in one flat card and move
/// operations behind Accounts Activity.
struct MoneyView: View {
    @EnvironmentObject private var store: FinanceStore
    @State private var transactionEditor: TransactionEditorKind?
    @State private var showAccountEditor = false
    @State private var activityKind: ActivityKind?

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
                if store.isLoading && store.accounts.isEmpty {
                    ProgressView()
                }
            }
            .navigationDestination(item: $activityKind) { kind in
                AccountActivityView(kind: kind)
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

    // MARK: - Totals

    private var flowCard: some View {
        FICard {
            FIListRow(
                title: Text("money.spended"),
                accessory: .value(Text(verbatim: approximate(store.overview.spent.formatted)))
            )
            FIRowSeparator()
            FIListRow(
                title: Text("money.earned"),
                accessory: .value(Text(verbatim: approximate(store.overview.earned.formatted)))
            )
        }
    }

    /// The mock-ups prefix the totals with a tilde: cross-currency sums are
    /// converted at today's rate, so the number is an estimate and should not
    /// pretend to be exact.
    private func approximate(_ value: String) -> String {
        value.isEmpty ? value : "~" + value
    }

    // MARK: - Accounts

    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: FITheme.Metrics.headerSpacing) {
            FISectionHeader("money.accounts")

            FICard {
                if store.accounts.isEmpty {
                    FIEmptyState(
                        title: "money.accounts.empty",
                        subtitle: "money.accounts.empty.subtitle"
                    )
                    FIRowSeparator()
                    FIInlineActionRow("money.accounts.add") {
                        showAccountEditor = true
                    }
                } else {
                    ForEach(Array(store.accounts.enumerated()), id: \.element.id) { index, account in
                        if index > 0 {
                            FIRowSeparator()
                        }
                        accountRow(account)
                    }
                }
            }
        }
    }

    private func accountRow(_ account: Finance_Account) -> some View {
        FIListRow(
            title: Text(verbatim: account.name),
            subtitle: Text(verbatim: account.balance.formatted),
            accessory: .symbol(name: accountSymbol(account), color: FITheme.Palette.accent)
        )
        // Pinned identity so a reorder cannot leave a row's menu wired to the
        // account that used to sit in that slot.
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

    /// The account's own glyph when it has one, otherwise the currency sign —
    /// which is what the mock-ups show for cash accounts.
    private func accountSymbol(_ account: Finance_Account) -> String {
        if !account.symbolName.isEmpty {
            return account.symbolName
        }
        return FinanceCurrencies.symbolName(for: account.balance.currencyCode)
    }

    // MARK: - Activity

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: FITheme.Metrics.headerSpacing) {
            FISectionHeader("money.activity")

            FICard {
                Button {
                    activityKind = .expenses
                } label: {
                    FIListRow(title: Text("money.activity.expenses"), accessory: .chevron)
                }
                .buttonStyle(.plain)

                FIRowSeparator()

                Button {
                    activityKind = .incoming
                } label: {
                    FIListRow(title: Text("money.activity.incoming"), accessory: .chevron)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var addMenu: some View {
        FIToolbarAddButton {
            Button {
                transactionEditor = .income
            } label: {
                Label("money.add.incoming", systemImage: "arrow.down")
            }

            Button {
                transactionEditor = .expense
            } label: {
                Label("money.add.expense", systemImage: "arrow.up")
            }

            Button {
                transactionEditor = .transfer
            } label: {
                Label("money.add.transfer", systemImage: "arrow.up.arrow.down")
            }

            Divider()

            Button {
                showAccountEditor = true
            } label: {
                Label("money.accounts.add", systemImage: "creditcard")
            }
        }
    }
}

/// Which half of the ledger an activity screen shows.
enum ActivityKind: String, Identifiable, Hashable {
    case expenses
    case incoming

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .expenses: return "activity.expenses.title"
        case .incoming: return "activity.incoming.title"
        }
    }
}

/// The list behind "Expenses" / "Incoming".
///
/// Transfers appear in neither: money moving between the user's own accounts is
/// not spending and not income, and counting it as either would double the
/// month's totals.
struct AccountActivityView: View {
    @EnvironmentObject private var store: FinanceStore
    let kind: ActivityKind

    private var transactions: [Finance_Transaction] {
        store.transactions.filter { transaction in
            switch kind {
            case .expenses: return transaction.kind == .expense
            case .incoming: return transaction.kind == .income
            }
        }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: FITheme.Metrics.sectionSpacing) {
                FICard {
                    if transactions.isEmpty {
                        FIEmptyState(title: "activity.empty", subtitle: "activity.empty.subtitle")
                    } else {
                        ForEach(Array(transactions.enumerated()), id: \.element.id) { index, transaction in
                            if index > 0 {
                                FIRowSeparator()
                            }
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
        .navigationTitle(Text(kind.titleKey))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ transaction: Finance_Transaction) -> some View {
        FIListRow(
            title: Text(verbatim: transaction.title.isEmpty ? transaction.category : transaction.title),
            subtitle: Text(verbatim: subtitle(for: transaction)),
            accessory: .value(Text(verbatim: transaction.amount.formatted))
        )
        .id(transaction.id)
        .fiRowContextMenu {
            Button(role: .destructive) {
                Task { await store.deleteTransaction(transaction) }
            } label: {
                Label("transaction.delete", systemImage: "trash")
            }
        }
    }

    /// Category and date, which is what distinguishes two otherwise identical
    /// rows in a month's worth of groceries.
    private func subtitle(for transaction: Finance_Transaction) -> String {
        let day = transaction.hasOccurredAt
            ? transaction.occurredAt.date.formatted(.dateTime.day().month(.abbreviated))
            : ""
        let category = transaction.category

        return [category, day].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

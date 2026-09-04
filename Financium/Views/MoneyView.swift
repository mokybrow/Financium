import SwiftProtobuf
import SwiftUI

struct MoneyView: View {
    @EnvironmentObject private var store: FinanceStore
    @EnvironmentObject private var rates: ExchangeRates
    @State private var sheet: MoneySheet?
    @State private var activityKind: ActivityKind?
    @State private var accountActivity: Finance_Account?
    /// Waiting on a confirmation. Deleting is one tap in a menu that opens on
    /// a long press, and none of it can be undone.
    @State private var pendingAccountDeletion: Finance_Account?
    /// The plain delete was refused because the account still has
    /// transactions — asking whether to take them with it.
    @State private var accountDeletionNeedsCascade: Finance_Account?

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: FITheme.Metrics.sectionSpacing) {
                    FinancePeriodRow(showsCurrency: true)
                    activitySection
                    accountsSection
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
                ToolbarItem(placement: .topBarTrailing) { ProfileToolbarButton() }
            }
            .refreshable {
                await rates.refresh()
                // A pull is a request for the truth now, so it does not settle
                // for an answer that was already on its way.
                await store.refresh(force: true)
            }
            .navigationDestination(item: $activityKind) { kind in
                AccountActivityView(kind: kind)
            }
            .navigationDestination(item: $accountActivity) { account in
                AccountActivityView(account: account)
            }
            // One sheet, chosen by case. Stacked `.sheet` modifiers on the same
            // view fight over the presentation and only the last one reliably
            // wins — a bug that shows up as a tap doing nothing.
            .sheet(item: $sheet) { destination in
                switch destination {
                case .transaction(let kind):
                    TransactionEditorView(kind: kind)
                case .account(let account):
                    AccountEditorView(account: account)
                case .correction(let account):
                    BalanceCorrectionView(account: account)
                }
            }
            .fiErrorAlert($store.errorMessage)
            .fiConfirmDelete($pendingAccountDeletion) { account in
                Task {
                    if await store.deleteAccount(account) == .hasTransactions {
                        accountDeletionNeedsCascade = account
                    }
                }
            }
            .alert(
                Text("money.account.delete.has_transactions.title"),
                isPresented: Binding(
                    get: { accountDeletionNeedsCascade != nil },
                    set: { if !$0 { accountDeletionNeedsCascade = nil } }
                )
            ) {
                Button("money.account.delete.force", role: .destructive) {
                    if let account = accountDeletionNeedsCascade {
                        Task { await store.deleteAccount(account, cascade: true) }
                    }
                }
                Button("common.cancel", role: .cancel) {}
            } message: {
                Text("money.account.delete.has_transactions.message")
            }
            .onChange(of: store.pendingQuickAdd) { _, kind in
                guard kind != nil else { return }
                presentPendingQuickAdd()
            }
            .task {
                // A tile tapped from a cold start sets this before this screen
                // exists, so the change above never fires. Checked once on
                // appearance for that case.
                presentPendingQuickAdd()
            }
        }
    }

    /// Opens the editor a widget asked for, once there is something to open it
    /// from.
    ///
    /// Deferred by one turn of the run loop. A tile tapped from a cold start
    /// sets this while the tab bar is still being assembled, and presenting a
    /// sheet from a `TabHostingController` that is not yet in the view
    /// hierarchy is what produced "Presenting view controller from detached
    /// view controller" — a warning today, a crash in a future release, and in
    /// the meantime a sheet with the wrong safe-area insets.
    private func presentPendingQuickAdd() {
        guard let kind = store.pendingQuickAdd else { return }
        store.pendingQuickAdd = nil
        Task { @MainActor in
            sheet = .transaction(kind)
        }
    }


    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: FITheme.Metrics.headerSpacing) {
            FISectionHeader("money.accounts")

            if store.accounts.isEmpty {
                // Three different nothings, and they must not look alike.
                //
                // "No accounts yet" is an answer and is only true once the
                // backend has said so. A failed load is not that answer — it is
                // a fault, and saying "no accounts" would tell someone their
                // money is gone. Anything else is still in flight, and stays
                // blank until it settles.
                if store.hasLoaded {
                    accountsNotice(
                        title: Text("money.accounts.empty"),
                        detail: Text("money.accounts.empty.subtitle")
                    ) {
                        EmptyView()
                    }
                } else if let failure = store.loadFailure {
                    accountsNotice(
                        title: Text("money.accounts.failed"),
                        detail: Text(verbatim: failure)
                    ) {
                        Button("common.retry") {
                            Task { await store.refresh() }
                        }
                        .buttonStyle(.bordered)
                        .padding(.top, 4)
                    }
                } else {
                    Color.clear.frame(height: placeholderHeight)
                }
            } else {
                FICard {
                    ForEach(Array(store.accounts.enumerated()), id: \.element.id) { index, account in
                        if index > 0 { FIRowSeparator() }
                        accountRow(account)
                    }
                }
            }
        }
    }

    private var placeholderHeight: CGFloat { 200 }

    /// What stands in for the accounts card when there is no card to draw.
    ///
    /// Not `FIEmptyState`, which is built to be laid over a scroll view with
    /// `.overlay` and sizes itself to whatever it covers. Used as a sibling in
    /// this stack — which is what it was — its `maxHeight: .infinity` measures
    /// the viewport *plus* the rows already above it, so the text lands below
    /// the fold and a reader with no accounts sees an empty screen and no
    /// explanation. A stated height puts it directly under the header, where
    /// the card would have been.
    private func accountsNotice(
        title: Text,
        detail: Text,
        @ViewBuilder action: () -> some View
    ) -> some View {
        VStack(spacing: 8) {
            title
                .font(.system(.title3, design: .default).weight(.bold))
                .foregroundStyle(.secondary)

            detail
                .font(FITheme.Typography.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            action()
        }
        .frame(maxWidth: .infinity)
        .frame(height: placeholderHeight)
        .padding(.horizontal, FITheme.Metrics.cardInset)
    }

    private func accountRow(_ account: Finance_Account) -> some View {
        Button {
            accountActivity = account
        } label: {
            FIListRow(title: Text(verbatim: account.name), subtitle: Text(verbatim: account.balance.formatted)) {
                HStack(spacing: 12) {
                    // Two people, when there are two people. Ahead of the
                    // account's own glyph because it says something about who
                    // the money belongs to rather than what kind of account it
                    // is, and that is the more surprising fact of the two.
                    if store.isShared(account) {
                        Image(systemName: "person.2.fill")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(Text("money.account.shared"))
                    }
                    accountGlyph(account)
                        .foregroundStyle(FITheme.Palette.accent)
                    FIChevron()
                }
            }
        }
        .buttonStyle(.plain)
        .id(account.id)
        .fiRowContextMenu {
            Button {
                sheet = .account(account)
            } label: {
                Label("money.account.edit", systemImage: "pencil")
            }
            Button {
                sheet = .correction(account)
            } label: {
                Label("money.account.correct", systemImage: "plusminus")
            }

            // The owner can revoke an existing invite and every participant's
            // access without opening the account first. A participant cannot
            // close somebody else's share; their corresponding action is to
            // leave it.
            if store.isOwner(of: account), store.hasShareInvite(account) {
                FIDestructiveMenuButton(
                    titleKey: "money.account.make_private",
                    systemImage: "person.2.slash"
                ) {
                    Task { await store.makeAccountPrivate(account) }
                }
            } else if !store.isOwner(of: account) {
                FIDestructiveMenuButton(titleKey: "money.account.leave", systemImage: "person.fill.xmark") {
                    Task { await store.stopSharingAccount(account, memberID: store.currentUserID) }
                }
            }

            FIDestructiveMenuButton(titleKey: "money.account.delete") {
                pendingAccountDeletion = account
            }
        }
    }

    /// The mark at the trailing edge of an account row.
    ///
    /// The icon the user picked, if they picked one. Otherwise the currency's
    /// own SF Symbol — and where the currency has none, its sign as text rather
    /// than a generic banknote glyph, which looked the same for every exotic
    /// currency and so said nothing about any of them.
    @ViewBuilder
    private func accountGlyph(_ account: Finance_Account) -> some View {
        let code = account.balance.currencyCode.isEmpty ? store.mainCurrencyCode : account.balance.currencyCode

        if !account.symbolName.isEmpty {
            Image(systemName: account.symbolName)
        } else if let logo = FinanceCurrencies.logo(for: code) {
            Image(systemName: logo)
        } else {
            Text(verbatim: FinanceCurrencies.symbol(for: code))
                .font(FITheme.Typography.rowValue)
                .lineLimit(1)
        }
    }

    /// The month's figures: what is held, what it came to, and the two rows
    /// that produced it.
    ///
    /// No header — the chip above already says which period and which currency.
    /// The balance is converted into that currency; spend and income are not,
    /// because each is already a total in one currency and converting them
    /// would hide which.
    private var activitySection: some View {
        VStack(alignment: .leading, spacing: FITheme.Metrics.headerSpacing) {
            FICard {
                FIListRow(title: Text("money.total_balance")) {
                    Text(verbatim: totalBalanceText)
                        .font(FITheme.Typography.rowValue)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                FIRowSeparator()

                FIListRow(title: Text("money.net")) {
                    Text(verbatim: netText)
                        .font(FITheme.Typography.rowValue)
                        .foregroundStyle(netColor)
                        .lineLimit(1)
                }

                FIRowSeparator()

                Button { activityKind = .expenses } label: {
                    FIListRow(
                        title: Text("money.spended"),
                        accessory: .valueChevron(Text(verbatim: selectedTotals.spent.formatted))
                    )
                }
                .buttonStyle(.plain)

                FIRowSeparator()

                Button { activityKind = .incoming } label: {
                    FIListRow(
                        title: Text("money.earned"),
                        accessory: .valueChevron(Text(verbatim: selectedTotals.earned.formatted))
                    )
                }
                .buttonStyle(.plain)
            }

            if let note = conversionNote {
                FIFootnote(verbatim: note)
            }
        }
    }

    private var selectedTotals: Finance_CurrencyTotal {
        store.totals(for: store.effectiveDisplayCurrency)
    }

    /// Every account, converted into the currency on screen.
    ///
    /// Accounts the rates cannot reach are left out rather than added in at face
    /// value — a rouble counted as a dollar is a wrong total, and the footnote
    /// below says which ones were skipped.
    private var convertedBalance: (amount: Decimal, skipped: [String]) {
        let target = store.effectiveDisplayCurrency
        var total: Decimal = 0
        var skipped: Set<String> = []

        for account in store.accounts {
            let code = account.balance.currencyCode.isEmpty ? target : account.balance.currencyCode
            if let converted = rates.convert(account.balance.decimalValue, from: code, to: target) {
                total += converted
            } else {
                skipped.insert(code)
            }
        }
        return (total, skipped.sorted())
    }

    private var totalBalanceText: String {
        let result = convertedBalance
        let money = Finance_Money(decimal: result.amount, currencyCode: store.effectiveDisplayCurrency)
        // "≈" only when something was actually converted: a single-currency
        // total is exact, and hedging an exact number teaches the reader to
        // ignore the mark where it matters.
        let target = store.effectiveDisplayCurrency
        let converted = store.accounts.contains { !$0.balance.currencyCode.isEmpty && $0.balance.currencyCode != target }
        return converted ? "≈ " + money.formatted : money.formatted
    }

    /// Earned minus spent for the period, in the currency on screen.
    private var netText: String {
        let net = selectedTotals.earned.decimalValue - selectedTotals.spent.decimalValue
        let money = Finance_Money(decimal: abs(net), currencyCode: store.effectiveDisplayCurrency)
        return (net < 0 ? "−" : "+") + money.formatted
    }

    private var netColor: Color {
        let net = selectedTotals.earned.decimalValue - selectedTotals.spent.decimalValue
        if net > 0 { return FITheme.Palette.positive }
        if net < 0 { return FITheme.Palette.destructive }
        return .secondary
    }

    /// Says how old the rates are, and names anything that could not be
    /// converted — a total quietly missing an account is worse than a total
    /// that explains itself.
    private var conversionNote: String? {
        let target = store.effectiveDisplayCurrency
        let needsRates = store.accounts.contains {
            !$0.balance.currencyCode.isEmpty && $0.balance.currencyCode != target
        }
        guard needsRates else { return nil }

        // Checked first: with no rates at all, *every* foreign currency lands in
        // `skipped`, so listing them would report a dozen missing currencies
        // when the real answer is that nothing has been fetched yet.
        guard rates.isReady else {
            return NSLocalizedString("money.rates.unavailable", comment: "No rates at all")
        }

        // Named, not just counted: knowing it is the yen account that is missing
        // tells the reader how far off the total is.
        let skipped = convertedBalance.skipped
        if !skipped.isEmpty {
            return String(
                format: NSLocalizedString("money.rates.missing", comment: "Currencies left out of the total"),
                skipped.joined(separator: ", ")
            )
        }
        // Yesterday's rates are still worth using — they are far closer than no
        // total at all — but the reader is told which day they are from rather
        // than left to assume the figure is current.
        guard rates.isStale, let published = rates.publishedOn else { return nil }
        return String(
            format: NSLocalizedString("money.rates.stale", comment: "Rates are from an earlier day"),
            published.formatted(.dateTime.day().month(.abbreviated).year())
        )
    }

    private var addMenu: some View {
        FIToolbarAddButton {
            // Plus and minus rather than arrows: the menu names three kinds of
            // money, and a sign says which direction it goes without needing a
            // convention explained. The transfer keeps the two-way arrow it
            // already wears on every transfer row.
            Button { sheet = .transaction(.income) } label: {
                Label("money.add.incoming", systemImage: "plus")
            }
            Button { sheet = .transaction(.expense) } label: {
                Label("money.add.expense", systemImage: "minus")
            }
            Button { sheet = .transaction(.transfer) } label: {
                Label("money.add.transfer", systemImage: "arrow.left.arrow.right")
            }
            Divider()
            Button { sheet = .account(nil) } label: {
                Label("money.accounts.add", systemImage: "creditcard")
            }
        }
    }
}

/// What the Money screen can put in front of you.
///
/// One type for all of them so a single `sheet(item:)` drives the presentation.
/// The id distinguishes cases as well as accounts, so going straight from
/// editing an account to correcting it rebuilds the sheet.
enum MoneySheet: Identifiable {
    case transaction(TransactionEditorKind)
    case account(Finance_Account?)
    case correction(Finance_Account)

    var id: String {
        switch self {
        case .transaction(let kind): "transaction.\(kind.id)"
        case .account(let account): "account.\(account?.id ?? "new")"
        case .correction(let account): "correction.\(account.id)"
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

    /// Drawn as icons in the menu's palette row, so each option needs a glyph
    /// that reads at a glance without its label.
    var symbol: String {
        switch self {
        case .all: "chart.pie"
        case .cash: "wallet.bifold"
        case .banks: "building.columns"
        }
    }
}

struct AccountActivityView: View {
    @EnvironmentObject private var store: FinanceStore
    private let kind: ActivityKind?
    private let account: Finance_Account?

    @State private var sort: ActivitySort = .dateDescending
    @State private var accountFilter: ActivityAccountFilter = .all
    /// Seeded from the Money screen's currency picker on appear, so tapping a
    /// total opens the transactions that add up to it rather than all of them.
    @State private var currencyFilter = ""
    @State private var editingTransaction: Finance_Transaction?
    @State private var pendingTransactionDeletion: Finance_Transaction?
    /// A new transaction being added from this account's own list.
    @State private var addKind: TransactionEditorKind?
    /// Days the reader has folded away. Keyed by start-of-day.
    @State private var collapsedDays: Set<Date> = []
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

    /// One day of transactions, for the collapsible sections. Empty when the
    /// list is sorted by value — grouping by day only makes sense in date
    /// order.
    private struct DayGroup: Identifiable {
        let day: Date
        let items: [Finance_Transaction]
        var id: Date { day }
    }

    private var dayGroups: [DayGroup] {
        guard sort == .dateDescending || sort == .dateAscending else { return [] }
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: transactions) {
            calendar.startOfDay(for: $0.occurredAt.date)
        }
        let ascending = sort == .dateAscending
        return grouped.keys
            .sorted { ascending ? $0 < $1 : $0 > $1 }
            .map { DayGroup(day: $0, items: grouped[$0] ?? []) }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: FITheme.Metrics.sectionSpacing) {
                if dayGroups.isEmpty {
                    if !transactions.isEmpty {
                        FICard {
                            ForEach(Array(transactions.enumerated()), id: \.element.id) { index, transaction in
                                if index > 0 { FIRowSeparator() }
                                row(transaction)
                            }
                        }
                    }
                } else {
                    ForEach(dayGroups) { group in
                        daySection(group)
                    }
                }
            }
            .fiCardInsets()
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .fiPageBackground()
        .overlay {
            if transactions.isEmpty {
                FIEmptyState(title: "activity.empty", subtitle: "activity.empty.subtitle")
            }
        }
        .navigationTitle(account.map { Text(verbatim: $0.name) } ?? Text(kind?.titleKey ?? "activity.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let account {
                    // Left of "+": sharing is not adding money, but it is the
                    // other thing this page's owner can do to the account
                    // itself, and the two read as a pair in that order.
                    if store.isOwner(of: account) {
                        shareControl(for: account)
                    }

                    FIToolbarAddButton {
                        Button { addKind = .income } label: { Label("money.add.incoming", systemImage: "plus") }
                        Button { addKind = .expense } label: { Label("money.add.expense", systemImage: "minus") }
                        if store.accounts.count > 1 {
                            Button { addKind = .transfer } label: {
                                Label("money.add.transfer", systemImage: "arrow.left.arrow.right")
                            }
                        }
                    }
                    .accessibilityIdentifier("account.\(account.id).add")
                }
                sortMenu
                if account == nil {
                    filterMenu
                }
            }
        }
        .onAppear {
            // Only when that currency actually has transactions here: seeding a
            // code the picker has no option for would leave nothing selected
            // and an empty list with no visible reason.
            if currencyFilter.isEmpty, account == nil,
               availableCurrencies.contains(store.effectiveDisplayCurrency) {
                currencyFilter = store.effectiveDisplayCurrency
            }
        }
        .sheet(item: $editingTransaction) { TransactionEditorView(transaction: $0) }
        .sheet(item: $addKind) { kind in
            TransactionEditorView(kind: kind, accountID: account?.id ?? "")
        }
        .fiConfirmDelete($pendingTransactionDeletion) { transaction in
            Task { await store.deleteTransaction(transaction) }
        }
    }

    /// The toolbar's share control.
    ///
    /// A native `ShareLink` lives in the toolbar itself. Its transferable loads
    /// the invite only after the system menu is already on screen.
    private func shareControl(for account: Finance_Account) -> some View {
        AccountShareLinkButton(
            accountID: account.id,
            accountName: account.name,
            existingShare: store.cachedShare(for: account),
            accessibilityLabel: store.hasShareInvite(account)
                ? "money.account.share.again"
                : "money.account.share"
        )
    }

    @ViewBuilder
    private func daySection(_ group: DayGroup) -> some View {
        let collapsed = collapsedDays.contains(group.day)
        VStack(alignment: .leading, spacing: FITheme.Metrics.headerSpacing) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    if collapsed { collapsedDays.remove(group.day) } else { collapsedDays.insert(group.day) }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(collapsed ? -90 : 0))
                    Text(verbatim: dayLabel(group.day))
                        .font(FITheme.Typography.sectionHeader)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    Text(verbatim: "\(group.items.count)")
                        .font(FITheme.Typography.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.horizontal, FITheme.Metrics.textInset)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: dayLabel(group.day)))
            .accessibilityHint(Text(collapsed
                ? LocalizedStringKey("activity.group.expand")
                : LocalizedStringKey("activity.group.collapse")))

            if !collapsed {
                FICard {
                    ForEach(Array(group.items.enumerated()), id: \.element.id) { index, transaction in
                        if index > 0 { FIRowSeparator() }
                        row(transaction)
                    }
                }
            }
        }
    }

    private func dayLabel(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return NSLocalizedString("activity.today", comment: "Today") }
        if calendar.isDateInYesterday(day) { return NSLocalizedString("activity.yesterday", comment: "Yesterday") }
        let sameYear = calendar.isDate(day, equalTo: Date(), toGranularity: .year)
        return sameYear
            ? day.formatted(.dateTime.weekday(.abbreviated).day().month(.wide))
            : day.formatted(.dateTime.day().month(.wide).year())
    }

    /// Account scope and currency, both as named rows.
    ///
    /// The palette style drew the mock-up's icon row, but it renders glyphs
    /// only — the captions under them in the design do not exist in a real
    /// menu, leaving three unlabelled shapes to guess at. An inline picker
    /// shows icon, name and checkmark together, which is what the sort menu
    /// beside it already does. Currency stays a submenu because the list is as
    /// long as the user has currencies.
    private var filterMenu: some View {
        FIToolbarMenu(systemImage: "line.3.horizontal.decrease", accessibilityLabel: "activity.filter") {
            Picker(selection: $accountFilter) {
                ForEach(ActivityAccountFilter.allCases) { option in
                    Label(option.titleKey, systemImage: option.symbol).tag(option)
                }
            } label: {
                Text("activity.filter.account")
            }
            .pickerStyle(.inline)

            Menu {
                Picker(selection: $currencyFilter) {
                    Text("activity.filter.all").tag("")
                    ForEach(availableCurrencies, id: \.self) { code in
                        Text(verbatim: code).tag(code)
                    }
                } label: {
                    Text("activity.filter.currency")
                }
                .pickerStyle(.inline)
            } label: {
                Label("activity.filter.currency", systemImage: "coloncurrencysign.circle")
            }
        }
    }

    private var sortMenu: some View {
        FIToolbarMenu(systemImage: "arrow.up.arrow.down", accessibilityLabel: "activity.sort") {
            Picker(selection: $sort) {
                ForEach(ActivitySort.allCases) { option in
                    Text(option.titleKey).tag(option)
                }
            } label: {
                Text("activity.sort")
            }
            .pickerStyle(.inline)
        }
    }

    private func row(_ transaction: Finance_Transaction) -> some View {
        Button { editingTransaction = transaction } label: {
            FIListRow(
                title: Text(verbatim: title(for: transaction)),
                subtitle: Text(verbatim: subtitle(for: transaction))
            ) {
                HStack(spacing: 10) {
                    Text(verbatim: amountText(for: transaction))
                        .foregroundStyle(amountColor(for: transaction))
                        // The amount is the one thing that must stay on one
                        // line: "−5 000,00 RUB" wrapping mid-figure is unreadable
                        // and drags the row's height around. The title above it
                        // is what gives way instead.
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

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
            FIDestructiveMenuButton(titleKey: "transaction.delete") {
                pendingTransactionDeletion = transaction
            }
        }
    }

    /// Which way the money moved, seen from the account being viewed.
    ///
    /// A transfer is an expense to one account and income to the other, so the
    /// direction cannot come from `kind` alone — it depends on which side of
    /// the transfer this screen is standing on. `nil` on the combined Expenses
    /// and Incoming lists, where every row already moves the same way and a
    /// column of identical signs would be noise.
    private enum Direction { case outgoing, incoming }

    private func direction(for transaction: Finance_Transaction) -> Direction? {
        guard let account else { return nil }
        switch transaction.kind {
        case .expense: return .outgoing
        case .income: return .incoming
        case .transfer: return transaction.toAccountID == account.id ? .incoming : .outgoing
        default: return nil
        }
    }

    /// What the row shows on the right.
    ///
    /// A transfer between currencies carries two amounts. Looking at the
    /// receiving account, the money that left the other one is the wrong
    /// number — and in the wrong currency — so the destination amount is shown
    /// instead.
    private func amountText(for transaction: Finance_Transaction) -> String {
        var money = transaction.amount
        if let account,
           transaction.kind == .transfer,
           transaction.toAccountID == account.id,
           transaction.hasDestinationAmount,
           transaction.destinationAmount.minorUnits > 0 {
            money = transaction.destinationAmount
        }

        switch direction(for: transaction) {
        // A true minus sign rather than a hyphen: it lines up with the digits
        // and is what a currency formatter would print.
        case .outgoing: return "−" + money.formatted
        case .incoming: return "+" + money.formatted
        case nil: return money.formatted
        }
    }

    private func amountColor(for transaction: Finance_Transaction) -> Color {
        switch direction(for: transaction) {
        case .outgoing: FITheme.Palette.destructive
        case .incoming: FITheme.Palette.positive
        case nil: .primary
        }
    }

    /// The row's name.
    ///
    /// Transfers created before they stopped borrowing a spend category were
    /// *saved* with that category as their title — the old editor wrote
    /// `title: categoryLabel`. So a stored title is only trusted on a transfer
    /// when it differs from the category; otherwise it is that old default and
    /// the row is named after the other account, which is what a transfer
    /// actually is.
    private func title(for transaction: Finance_Transaction) -> String {
        let stored = transaction.title
        let isLegacyDefault = transaction.kind == .transfer
            && !transaction.category.isEmpty
            && stored == transaction.category

        if !stored.isEmpty, !isLegacyDefault { return stored }

        guard transaction.kind == .transfer else {
            // A row written by an older build can have neither, and a blank
            // title reads as a rendering fault rather than as missing data.
            return transaction.category.isEmpty
                ? NSLocalizedString("transaction.untitled", comment: "No title or category")
                : FinanceCategoryStore.displayName(for: transaction.category)
        }
        let incoming = direction(for: transaction) == .incoming
        let otherID = incoming ? transaction.fromAccountID : transaction.toAccountID
        guard let other = store.accounts.first(where: { $0.id == otherID }) else {
            return NSLocalizedString("transaction.transfer", comment: "Transfer")
        }
        // Money arriving is named after where it came from, with no preamble:
        // the row already carries a "+", a green amount and the word "Transfer"
        // in its subtitle, so "Incoming from Cash" was the fourth thing on one
        // line saying the same thing. Outgoing keeps its preposition, which is
        // what distinguishes "to Sber" from a plain account name.
        guard !incoming else { return other.name }
        return String(
            format: NSLocalizedString("transaction.transfer_to_format", comment: "Transfer destination"),
            other.name
        )
    }

    /// Date, counterparty account, and the word "Transfer" when it is one.
    ///
    /// The transfer marker lives on this line rather than beside the amount:
    /// squeezed in next to the figure it pushed "−5 000,00 RUB" onto two lines,
    /// and an icon sitting between a date and a number reads as decoration. In
    /// the subtitle it is a word, in the reader's language, next to the other
    /// facts about the row.
    private func subtitle(for transaction: Finance_Transaction) -> String {
        let day = transaction.hasOccurredAt ? transaction.occurredAt.date.formatted(.dateTime.day().month(.abbreviated)) : ""
        let accountName = account == nil ? account(for: transaction)?.name ?? "" : ""
        let marker = transaction.kind == .transfer
            ? NSLocalizedString("transaction.transfer", comment: "Transfer")
            : ""
        return [day, accountName, marker].filter { !$0.isEmpty }.joined(separator: " · ")
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

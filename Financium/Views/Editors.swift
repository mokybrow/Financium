import SwiftUI
import SwiftProtobuf

// The editor sheets, per the mock-ups: a drawn header with a round close button
// and a filled blue confirm button, one card of menu rows, and a digits-only pad
// pinned to the bottom.
//
// The amount row is a real TextField on the decimal pad. The mock-up's number
// pad is the system decimal pad, so nothing here is hand-built: focus, the
// caret, paste and dictation all behave natively.

// MARK: - Shared pieces

/// Categories offered by the menus.
///
/// There is no category catalog on the backend yet, so the list is the union of
/// a sensible default set and whatever the user has already typed — which means
/// their own categories keep showing up without a schema change.
enum FinanceCategories {
    static let expense = ["Groceries", "Clothing", "Leisure", "Transport", "Home", "Health", "Other"]
    static let income = ["Salary", "Bonus", "Gift", "Refund", "Other"]

    static func options(for kind: TransactionEditorKind, existing: [Finance_Transaction]) -> [String] {
        let defaults = kind == .income ? income : expense
        let used = existing
            .filter { transaction in
                switch kind {
                case .income: return transaction.kind == .income
                case .expense: return transaction.kind == .expense
                case .transfer: return false
                }
            }
            .map(\.category)
            .filter { !$0.isEmpty }

        var seen = Set<String>()
        return (defaults + used).filter { seen.insert($0).inserted }
    }
}

/// Parses what the pad produced into a `Decimal`.
///
/// The pad writes the locale's separator, so the string is normalised here
/// rather than assuming a dot — a comma locale would otherwise silently parse
/// "2,50" as nil and save nothing.
func financeDecimal(from text: String) -> Decimal? {
    let separator = Locale.current.decimalSeparator ?? "."
    let normalized = text.replacingOccurrences(of: separator, with: ".")
    guard !normalized.isEmpty else { return nil }
    return Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX"))
}

/// Formats a stored amount back into something the pad can keep editing.
func financeAmountText(_ value: Decimal) -> String {
    let separator = Locale.current.decimalSeparator ?? "."
    return String(describing: value).replacingOccurrences(of: ".", with: separator)
}

private extension View {
    /// Common frame for the editor sheets.
    func financeEditorSheet() -> some View {
        fiPageBackground()
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
    }
}

// MARK: - Transactions

struct TransactionEditorView: View {
    @EnvironmentObject private var store: FinanceStore
    @Environment(\.dismiss) private var dismiss
    let kind: TransactionEditorKind
    let transaction: Finance_Transaction?

    @State private var accountID = ""
    @State private var destinationID = ""
    @State private var category = ""
    @State private var title = ""
    @State private var amount = ""
    @State private var occurredAt = Date()
    @State private var saving = false

    init(kind: TransactionEditorKind) {
        self.kind = kind
        self.transaction = nil
    }

    init(transaction: Finance_Transaction) {
        self.transaction = transaction
        switch transaction.kind {
        case .income: self.kind = .income
        case .transfer: self.kind = .transfer
        default: self.kind = .expense
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: FITheme.Metrics.headerSpacing) {
                    FICard {
                        if transaction != nil {
                            FITextFieldRow("transaction.name", text: $title)
                            FIRowSeparator()
                        }

                        if kind == .transfer {
                            transferRows
                        } else {
                            standardRows
                        }

                        FIRowSeparator()
                        FIListRow(
                            title: Text("transaction.currency"),
                            accessory: .value(Text(verbatim: transactionCurrency))
                        )

                        FIRowSeparator()
                        FIAmountRow(text: $amount)
                    }

                    if kind == .transfer {
                        FIFootnote("transaction.transfer.hint")
                    }
                }
                .fiCardInsets()
                .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .fiPageBackground()
            .fiSheetChrome(
                title: Text(titleKey),
                confirm: .confirm(isEnabled: isValid && !saving) { save() },
                onClose: { dismiss() }
            )
        }
        .financeEditorSheet()
        .onAppear(perform: prefill)
        .overlay {
            if saving {
                ProgressView().controlSize(.large)
            }
        }
    }

    private var titleKey: LocalizedStringKey {
        if transaction != nil { return "transaction.edit" }
        switch kind {
        case .income: return "money.add.incoming"
        case .expense: return "money.add.expense"
        case .transfer: return "money.add.transfer"
        }
    }

    @ViewBuilder
    private var standardRows: some View {
        FIMenuRow(title: Text("transaction.category"), value: Text(verbatim: categoryLabel)) {
            ForEach(categoryOptions, id: \.self) { option in
                Button {
                    category = option
                } label: {
                    if option == category {
                        Label(option, systemImage: "checkmark")
                    } else {
                        Text(verbatim: option)
                    }
                }
            }
        }

        FIRowSeparator()

        FIMenuRow(title: Text("transaction.account"), value: Text(verbatim: accountLabel(accountID))) {
            accountButtons(selection: $accountID)
        }
    }

    @ViewBuilder
    private var transferRows: some View {
        FIMenuRow(title: Text("transaction.from"), value: Text(verbatim: accountLabel(accountID))) {
            accountButtons(selection: $accountID)
        }

        FIRowSeparator()

        FIMenuRow(title: Text("transaction.to"), value: Text(verbatim: accountLabel(destinationID))) {
            // The source account is filtered out: a transfer to itself is a
            // no-op the backend would happily store.
            accountButtons(selection: $destinationID, excluding: accountID)
        }
    }

    @ViewBuilder
    private func accountButtons(selection: Binding<String>, excluding excluded: String? = nil) -> some View {
        ForEach(store.accounts.filter { $0.id != excluded }) { account in
            Button {
                selection.wrappedValue = account.id
            } label: {
                if account.id == selection.wrappedValue {
                    Label(account.name, systemImage: "checkmark")
                } else {
                    Text(verbatim: account.name)
                }
            }
        }
    }

    private var categoryOptions: [String] {
        FinanceCategories.options(for: kind, existing: store.transactions)
    }

    private var categoryLabel: String {
        category.isEmpty ? (categoryOptions.first ?? "") : category
    }

    private func accountLabel(_ id: String) -> String {
        store.accounts.first { $0.id == id }?.name ?? ""
    }

    private func prefill() {
        if let transaction {
            accountID = kind == .income ? transaction.toAccountID : transaction.fromAccountID
            destinationID = transaction.toAccountID
            category = transaction.category
            title = transaction.title
            amount = financeAmountText(transaction.amount.decimalValue)
            if transaction.hasOccurredAt { occurredAt = transaction.occurredAt.date }
            return
        }
        if accountID.isEmpty {
            accountID = store.accounts.first?.id ?? ""
        }
        if kind == .transfer, destinationID.isEmpty {
            destinationID = store.accounts.first { $0.id != accountID }?.id ?? ""
        }
        if category.isEmpty {
            category = categoryOptions.first ?? ""
        }
    }

    private var isValid: Bool {
        guard let value = financeDecimal(from: amount), value > 0 else { return false }
        guard !accountID.isEmpty else { return false }
        if kind == .transfer {
            return !destinationID.isEmpty && destinationID != accountID
        }
        return true
    }

    private var transactionCurrency: String {
        if let code = store.accounts.first(where: { $0.id == accountID })?.balance.currencyCode, !code.isEmpty {
            return code
        }
        if let transaction, !transaction.amount.currencyCode.isEmpty { return transaction.amount.currencyCode }
        return store.settings.mainCurrencyCode.isEmpty ? "RUB" : store.settings.mainCurrencyCode
    }

    private func save() {
        guard let value = financeDecimal(from: amount) else { return }
        saving = true

        Task {
            let created = await store.saveTransaction(
                id: transaction?.id ?? "",
                kind: kind,
                accountID: accountID,
                destinationID: destinationID,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? categoryLabel : title,
                category: categoryLabel,
                amount: value,
                currency: transactionCurrency,
                note: "",
                date: occurredAt
            )
            saving = false
            if created { dismiss() }
        }
    }
}

// MARK: - Accounts

struct AccountEditorView: View {
    @EnvironmentObject private var store: FinanceStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var symbol = "creditcard.fill"
    @State private var currency = "RUB"
    @State private var opening = ""
    @State private var saving = false

    private let symbols = ["creditcard.fill", "banknote.fill", "building.columns.fill", "wallet.bifold.fill"]

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                FICard {
                    FITextFieldRow("account.name.placeholder", text: $name)
                        .textInputAutocapitalization(.words)

                    FIRowSeparator()

                    FIMenuRow(title: Text("account.symbol"), value: Text(verbatim: "")) {
                        ForEach(symbols, id: \.self) { option in
                            Button {
                                symbol = option
                            } label: {
                                Label(option, systemImage: option)
                            }
                        }
                    }

                    FIRowSeparator()

                    NavigationLink {
                        CurrencyPickerView(selected: currency) { currency = $0 }
                    } label: {
                        FIListRow(
                            title: Text("account.currency"),
                            accessory: .valueChevron(Text(verbatim: currency))
                        )
                    }
                    .buttonStyle(.plain)

                    FIRowSeparator()

                    FIAmountRow(text: $opening, placeholder: "account.opening_balance")
                }
                .fiCardInsets()
                .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .fiPageBackground()
            .fiSheetChrome(
                title: Text("money.accounts.add"),
                confirm: .confirm(isEnabled: !name.trimmingCharacters(in: .whitespaces).isEmpty && !saving) { save() },
                onClose: { dismiss() }
            )
        }
        .financeEditorSheet()
        .overlay {
            if saving {
                ProgressView().controlSize(.large)
            }
        }
    }

    private func save() {
        saving = true
        // An empty opening balance means zero, not "invalid": most accounts are
        // created empty and typing a 0 for that is busywork.
        let value = financeDecimal(from: opening) ?? 0

        Task {
            let created = await store.createAccount(
                name: name.trimmingCharacters(in: .whitespaces),
                symbol: symbol,
                opening: value,
                currency: currency
            )
            saving = false
            if created { dismiss() }
        }
    }
}

// MARK: - Budgets

struct BudgetEditorView: View {
    @EnvironmentObject private var store: FinanceStore
    @Environment(\.dismiss) private var dismiss
    var budget: Finance_Budget?

    @State private var category = ""
    @State private var limit = ""
    @State private var reminder = true
    @State private var paymentDay = 1
    @State private var saving = false

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: FITheme.Metrics.headerSpacing) {
                    FICard {
                        FIMenuRow(title: Text("transaction.category"), value: Text(verbatim: categoryLabel)) {
                            ForEach(categoryOptions, id: \.self) { option in
                                Button {
                                    category = option
                                } label: {
                                    if option == category {
                                        Label(option, systemImage: "checkmark")
                                    } else {
                                        Text(verbatim: option)
                                    }
                                }
                            }
                        }

                        FIRowSeparator()
                        FIToggleRow("budget.remind", isOn: $reminder)

                        // Only meaningful when something is going to remind you.
                        if reminder {
                            FIRowSeparator()
                            paymentDayRow
                        }

                        FIRowSeparator()
                        FIAmountRow(text: $limit, placeholder: "budget.limit")
                    }

                    FIFootnote("budget.hint")
                }
                .fiCardInsets()
                .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .fiPageBackground()
            .fiSheetChrome(
                title: Text(budget == nil ? "budget.add" : "budget.title"),
                confirm: .confirm(isEnabled: isValid && !saving) { save() },
                onClose: { dismiss() }
            )
        }
        .financeEditorSheet()
        .onAppear(perform: prefill)
        .overlay {
            if saving {
                ProgressView().controlSize(.large)
            }
        }
    }

    /// Day of the month, shown as the grey chip from the mock-up.
    private var paymentDayRow: some View {
        FIListRow(title: Text("budget.payment_day")) {
            Menu {
                ForEach(1...31, id: \.self) { day in
                    Button {
                        paymentDay = day
                    } label: {
                        if day == paymentDay {
                            Label(String(day), systemImage: "checkmark")
                        } else {
                            Text(verbatim: String(day))
                        }
                    }
                }
            } label: {
                Text(verbatim: String(paymentDay))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(FITheme.Palette.controlFill, in: Capsule())
            }
            .tint(.primary)
        }
    }

    private var categoryOptions: [String] {
        FinanceCategories.options(for: .expense, existing: store.transactions)
    }

    private var categoryLabel: String {
        category.isEmpty ? (categoryOptions.first ?? "") : category
    }

    private var isValid: Bool {
        guard let value = financeDecimal(from: limit), value > 0 else { return false }
        return !categoryLabel.isEmpty
    }

    private func prefill() {
        guard let budget else {
            if category.isEmpty { category = categoryOptions.first ?? "" }
            return
        }
        category = budget.category
        limit = financeAmountText(budget.limit.decimalValue)
        reminder = budget.reminderEnabled
        paymentDay = max(1, min(31, Int(budget.paymentDay)))
    }

    private func save() {
        guard let value = financeDecimal(from: limit) else { return }
        saving = true

        Task {
            let saved = await store.upsertBudget(
                id: budget?.id ?? "",
                category: categoryLabel,
                limit: value,
                reminder: reminder,
                paymentDay: paymentDay
            )
            saving = false
            if saved { dismiss() }
        }
    }
}

// MARK: - Goals

struct GoalEditorView: View {
    @EnvironmentObject private var store: FinanceStore
    @Environment(\.dismiss) private var dismiss
    var goal: Finance_Goal?

    @State private var title = ""
    @State private var accountID = ""
    @State private var category = ""
    @State private var target = ""
    @State private var saving = false

    private let categories = ["Home", "Travel", "Education", "Health", "Tech", "Other"]

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: FITheme.Metrics.headerSpacing) {
                    FICard {
                        FIMenuRow(title: Text("transaction.account"), value: Text(verbatim: accountLabel)) {
                            ForEach(store.accounts) { account in
                                Button {
                                    accountID = account.id
                                } label: {
                                    if account.id == accountID {
                                        Label(account.name, systemImage: "checkmark")
                                    } else {
                                        Text(verbatim: account.name)
                                    }
                                }
                            }
                        }

                        FIRowSeparator()

                        FIMenuRow(title: Text("transaction.category"), value: Text(verbatim: categoryLabel)) {
                            ForEach(categories, id: \.self) { option in
                                Button {
                                    category = option
                                } label: {
                                    if option == category {
                                        Label(option, systemImage: "checkmark")
                                    } else {
                                        Text(verbatim: option)
                                    }
                                }
                            }
                        }

                        FIRowSeparator()
                        FIAmountRow(text: $target, placeholder: "goals.name")
                    }

                    FIFootnote("goals.hint")
                }
                .fiCardInsets()
                .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .fiPageBackground()
            .fiSheetChrome(
                title: Text(goal == nil ? "goals.add" : "goals.title"),
                confirm: .confirm(isEnabled: isValid && !saving) { save() },
                onClose: { dismiss() }
            )
        }
        .financeEditorSheet()
        .onAppear(perform: prefill)
        .overlay {
            if saving {
                ProgressView().controlSize(.large)
            }
        }
    }

    private var accountLabel: String {
        store.accounts.first { $0.id == accountID }?.name ?? ""
    }

    private var categoryLabel: String {
        category.isEmpty ? (categories.first ?? "") : category
    }

    private var isValid: Bool {
        guard let value = financeDecimal(from: target), value > 0 else { return false }
        return !accountID.isEmpty
    }

    private func prefill() {
        guard let goal else {
            if accountID.isEmpty { accountID = store.accounts.first?.id ?? "" }
            if category.isEmpty { category = categories.first ?? "" }
            return
        }
        title = goal.title
        accountID = goal.accountID
        category = goal.category
        target = financeAmountText(goal.target.decimalValue)
    }

    private func save() {
        guard let value = financeDecimal(from: target) else { return }
        saving = true

        Task {
            let stored = await store.upsertGoal(
                id: goal?.id ?? "",
                // The sheet has no separate name field, so the category names
                // the goal — matching how the list renders it.
                title: title.isEmpty ? categoryLabel : title,
                accountID: accountID,
                category: categoryLabel,
                target: value,
                // Progress is accumulated from incoming transactions, not typed
                // in: the goal sheet is where you say what you are saving for.
                saved: goal?.saved.decimalValue ?? 0
            )
            saving = false
            if stored { dismiss() }
        }
    }
}

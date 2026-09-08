import SwiftUI

// Editor sheets use native navigation chrome, controls and input methods so
// calendars, menus, focus, paste, dictation and accessibility follow iOS.

// MARK: - Shared pieces

/// Parses what the pad produced into a `Decimal`.
///
/// The pad writes the locale's separator, so the string is normalised here
/// rather than assuming a dot — a comma locale would otherwise silently parse
/// "2,50" as nil and save nothing.
func financeDecimal(from text: String) -> Decimal? {
    let locale = Locale.current
    let separator = locale.decimalSeparator ?? "."
    let grouping = locale.groupingSeparator ?? "\u{00A0}"
    let formatted = FIAmountRow.sanitize(text, locale: locale)
    let ungrouped = formatted
        .replacingOccurrences(of: grouping, with: "")
        .filter { !$0.isWhitespace }
    let normalized = ungrouped.replacingOccurrences(of: separator, with: ".")
    guard !normalized.isEmpty else { return nil }
    return Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX"))
}

/// Formats a stored amount back into something the pad can keep editing.
func financeAmountText(_ value: Decimal) -> String {
    let locale = Locale.current
    let separator = locale.decimalSeparator ?? "."
    let localized = String(describing: value).replacingOccurrences(of: ".", with: separator)
    return FIAmountRow.sanitize(localized, locale: locale)
}

private extension View {
    /// Common frame for the editor sheets.
    ///
    /// The error alert belongs here rather than on the screen underneath:
    /// saving fails inside the sheet, and SwiftUI will not present an alert
    /// from a view a sheet is covering — so the sheet just sat there saying
    /// nothing while the write had been refused.
    func financeEditorSheet(error: Binding<String?>) -> some View {
        presentationBackground(.ultraThinMaterial)
            .presentationDetents([.height(380), .large])
            .presentationDragIndicator(.hidden)
            .fiErrorAlert(error)
    }
}

// MARK: - Transactions

struct TransactionEditorView: View {
    @EnvironmentObject private var store: FinanceStore
    @EnvironmentObject private var categories: FinanceCategoryStore
    @Environment(\.dismiss) private var dismiss
    let kind: TransactionEditorKind
    let transaction: FinanceTransaction?
    /// Preselected account for a brand-new transaction — set when the editor is
    /// opened from inside one account's activity list.
    private let initialAccountID: String
    private let initialCategory: String
    private let initialDestinationID: String

    @State private var accountID = ""
    @State private var destinationID = ""
    @State private var category = ""
    @State private var title = ""
    @State private var amount = ""
    @State private var destinationAmount = ""
    @State private var occurredAt = Date()
    @State private var saving = false

    init(kind: TransactionEditorKind, accountID: String = "", category: String = "", destinationAccountID: String = "") {
        self.kind = kind
        self.transaction = nil
        self.initialAccountID = accountID
        self.initialCategory = category
        self.initialDestinationID = destinationAccountID
    }

    init(transaction: FinanceTransaction) {
        self.transaction = transaction
        self.initialAccountID = ""
        self.initialCategory = ""
        self.initialDestinationID = ""
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
                        FITextFieldRow("transaction.name", text: $title)
                        FIRowSeparator()

                        // The date sits right under the name, not folded away —
                        // it is edited about as often as the amount.
                        FIDateRow("transaction.date", date: $occurredAt)
                        FIRowSeparator()

                        if kind == .transfer {
                            transferRows
                        } else {
                            standardRows
                        }

                        FIRowSeparator()
                        FIAmountRow(text: $amount, placeholder: amountPlaceholder)

                        // A cross-currency transfer is two amounts, not one
                        // amount converted: the bank has already picked a rate
                        // and the user is copying both numbers off a statement.
                        if isCrossCurrency {
                            FIRowSeparator()
                            FIAmountRow(text: $destinationAmount, placeholder: "transaction.amount.received")
                        }
                    }

                    if let rate = exchangeRateText {
                        FIFootnote(verbatim: rate)
                    }

                    if kind == .transfer {
                        FIFootnote("transaction.transfer.hint")
                    }
                }
                .fiCardInsets()
                .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(.clear)
            .fiSheetChrome(
                title: Text(titleKey),
                confirm: .confirm(isEnabled: isValid && !saving) { save() },
                onClose: { dismiss() }
            )
        }
        .financeEditorSheet(error: $store.errorMessage)
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
        Menu {
            Picker("transaction.category", selection: Binding(get: { storedCategory }, set: { category = $0 })) {
                ForEach(categoryOptions, id: \.self) { option in
                    Label(FinanceCategoryStore.displayName(for: option), systemImage: categories.symbol(
                        for: option, kind: kind == .income ? .income : .expense
                    )).tag(option)
                }
            }
        } label: {
            FIListRow(title: Text("transaction.category")) {
                HStack(spacing: 8) {
                    Image(systemName: categories.symbol(for: storedCategory, kind: kind == .income ? .income : .expense))
                    Text(verbatim: categoryLabel)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }.foregroundStyle(.secondary)
            }
        }.tint(.primary)

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
        categories.options(for: kind, existing: store.transactions)
    }

    /// The category menu.
    ///
    /// The button's value is the stored identifier — that is what gets written
    /// to the transaction — while the label is its localized name, so switching
    /// the app's language re-labels existing categories instead of splitting
    /// them into new ones.
    @ViewBuilder
    private var categoryButtons: some View {
        ForEach(categoryOptions, id: \.self) { option in
            Button {
                category = option
            } label: {
                let name = FinanceCategoryStore.displayName(for: option)
                if option == category {
                    Label(name, systemImage: "checkmark")
                } else {
                    Label(name, systemImage: categories.symbol(for: option, kind: kind == .income ? .income : .expense))
                }
            }
        }
    }

    /// What gets written to the transaction: the stable identifier, never the
    /// translated name. Storing the display name would file a spend under
    /// "Продукты" on a Russian phone and "Groceries" on an English one, and the
    /// two would never again be recognised as the same category.
    private var storedCategory: String {
        category.isEmpty ? (categoryOptions.first ?? "") : category
    }

    private var categoryLabel: String {
        FinanceCategoryStore.displayName(for: storedCategory)
    }

    private func accountLabel(_ id: String) -> String {
        store.accounts.first { $0.id == id }?.name ?? ""
    }

    /// What the transaction is called if the user did not name it.
    ///
    /// For a spend or an income the category is a decent stand-in. A transfer
    /// has no category, so it is named after where the money went — which is
    /// the only thing that tells one transfer from another in a list.
    private var savedTitle: String {
        let typed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed.isEmpty else { return typed }
        guard kind == .transfer else { return categoryLabel }

        let destination = accountLabel(destinationID)
        guard !destination.isEmpty else { return NSLocalizedString("transaction.transfer", comment: "Transfer") }
        return String(
            format: NSLocalizedString("transaction.transfer_to_format", comment: "Transfer to account"),
            destination
        )
    }

    private func prefill() {
        if let transaction {
            accountID = kind == .income ? transaction.toAccountID : transaction.fromAccountID
            destinationID = transaction.toAccountID
            category = kind == .transfer ? "" : FinanceCategoryStore.canonical(transaction.category)
            // Old transfers were saved with their borrowed category as the
            // title. Leaving the field empty regenerates a proper name on save
            // instead of writing "Groceries" back.
            let isLegacyDefault = kind == .transfer
                && !transaction.category.isEmpty
                && transaction.title == transaction.category
            title = isLegacyDefault ? "" : transaction.title
            amount = financeAmountText(transaction.amount.decimalValue)
            if transaction.hasDestinationAmount, transaction.destinationAmount.minorUnits > 0 {
                destinationAmount = financeAmountText(transaction.destinationAmount.decimalValue)
            }
            if transaction.hasOccurredAt { occurredAt = transaction.occurredAt.date }
            return
        }
        if accountID.isEmpty {
            let preferred = store.accounts.first { $0.id == initialAccountID }?.id
            accountID = preferred ?? store.accounts.first?.id ?? ""
        }
        // A transfer gets no default category — `categoryOptions` is empty for
        // it, and defaulting to the first expense category is what named every
        // transfer after a grocery run.
        if kind == .transfer, destinationID.isEmpty {
            if !initialDestinationID.isEmpty, store.accounts.contains(where: { $0.id == initialDestinationID }) {
                destinationID = initialDestinationID
                if accountID == destinationID { accountID = store.accounts.first { $0.id != destinationID }?.id ?? "" }
            } else { destinationID = store.accounts.first { $0.id != accountID }?.id ?? "" }
        }
        if category.isEmpty {
            category = initialCategory.isEmpty ? (categoryOptions.first ?? "") : initialCategory
        }
    }

    private var isValid: Bool {
        guard let value = financeDecimal(from: amount), value > 0 else { return false }
        guard !accountID.isEmpty else { return false }
        if kind == .transfer {
            guard !destinationID.isEmpty, destinationID != accountID else { return false }
            // Across currencies the received amount is a second fact the app
            // cannot derive, so it has to be filled in before saving.
            if isCrossCurrency, (financeDecimal(from: destinationAmount) ?? 0) <= 0 { return false }
        }
        return true
    }

    private func account(_ id: String) -> FinanceAccount? {
        store.accounts.first { $0.id == id }
    }

    /// The currency the money lands in — the destination account's own.
    private var destinationCurrency: String {
        let code = account(destinationID)?.balance.currencyCode ?? ""
        return code.isEmpty ? transactionCurrency : code
    }

    private var isCrossCurrency: Bool {
        kind == .transfer && !destinationID.isEmpty && destinationCurrency != transactionCurrency
    }

    /// "Amount" normally, "Sent" once there is a second amount to tell it apart
    /// from.
    private var amountPlaceholder: LocalizedStringKey {
        isCrossCurrency ? "transaction.amount.sent" : "common.amount"
    }

    /// The rate the two amounts imply, shown rather than applied.
    ///
    /// The app has no rate feed and should not pretend to: this is arithmetic on
    /// what the user typed, offered as a sanity check on a pair of numbers
    /// copied off a statement. Rounded to four places because a rate like
    /// 0.010815 is meaningless at two and noise at eight.
    private var exchangeRateText: String? {
        guard isCrossCurrency,
              let sent = financeDecimal(from: amount), sent > 0,
              let received = financeDecimal(from: destinationAmount), received > 0 else { return nil }

        let rate = NSDecimalNumber(decimal: received / sent).rounding(
            accordingToBehavior: NSDecimalNumberHandler(
                roundingMode: .plain, scale: 4,
                raiseOnExactness: false, raiseOnOverflow: false,
                raiseOnUnderflow: false, raiseOnDivideByZero: false
            )
        )
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 4
        guard let value = formatter.string(from: rate) else { return nil }

        return String(
            format: NSLocalizedString("transaction.rate_format", comment: "Implied exchange rate"),
            transactionCurrency,
            value,
            destinationCurrency
        )
    }

    /// The currency is never asked for: an amount is always in the currency of
    /// the account it moves through, and failing that the one currency the user
    /// set in Profile.
    private var transactionCurrency: String {
        if let code = store.accounts.first(where: { $0.id == accountID })?.balance.currencyCode, !code.isEmpty {
            return code
        }
        if let transaction, !transaction.amount.currencyCode.isEmpty { return transaction.amount.currencyCode }
        return store.mainCurrencyCode
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
                title: savedTitle,
                // Empty for a transfer, so it never lands in a spend budget.
                category: kind == .transfer ? "" : storedCategory,
                amount: value,
                destinationAmount: isCrossCurrency ? financeDecimal(from: destinationAmount) : nil,
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

/// The glyphs an account can be marked with.
///
/// Each one carries a name: a menu listing "creditcard.fill" and
/// "wallet.bifold.fill" asks the user to read SF Symbol identifiers. The
/// currency signs are here as well, so an account can be marked by what it
/// holds rather than by what kind of thing it is — which is how a wallet of
/// foreign cash actually reads on the Money screen.
struct FinanceAccountIcon: Identifiable, Hashable {
    let symbol: String
    let titleKey: LocalizedStringKey

    var id: String { symbol }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.symbol == rhs.symbol }
    func hash(into hasher: inout Hasher) { hasher.combine(symbol) }

    static let kinds: [Self] = [
        Self(symbol: "creditcard.fill", titleKey: "account.icon.card"),
        Self(symbol: "banknote.fill", titleKey: "account.icon.cash"),
        Self(symbol: "building.columns.fill", titleKey: "account.icon.bank"),
        Self(symbol: "wallet.bifold.fill", titleKey: "account.icon.wallet"),
        Self(symbol: "chart.line.uptrend.xyaxis", titleKey: "account.icon.investments"),
        Self(symbol: "gift.fill", titleKey: "account.icon.savings")
    ]

    static let currencies: [Self] = [
        Self(symbol: "rublesign.circle.fill", titleKey: "account.icon.ruble"),
        Self(symbol: "dollarsign.circle.fill", titleKey: "account.icon.dollar"),
        Self(symbol: "eurosign.circle.fill", titleKey: "account.icon.euro"),
        Self(symbol: "sterlingsign.circle.fill", titleKey: "account.icon.pound"),
        Self(symbol: "yensign.circle.fill", titleKey: "account.icon.yen"),
        Self(symbol: "tengesign.circle.fill", titleKey: "account.icon.tenge"),
        Self(symbol: "turkishlirasign.circle.fill", titleKey: "account.icon.lira"),
        Self(symbol: "bitcoinsign.circle.fill", titleKey: "account.icon.bitcoin")
    ]

    static var all: [Self] { kinds + currencies }

    static func titleKey(for symbol: String) -> LocalizedStringKey {
        all.first { $0.symbol == symbol }?.titleKey ?? "account.icon.card"
    }
}

/// Creates a new account, or edits an existing one.
///
/// One sheet for both: the fields are the same, and an account's currency is a
/// property of that account rather than something fixed at creation — a travel
/// wallet that was opened in the wrong currency should be fixable without
/// deleting it and losing the name.
struct AccountEditorView: View {
    @EnvironmentObject private var store: FinanceStore
    @Environment(\.dismiss) private var dismiss

    let account: FinanceAccount?

    @State private var name = ""
    @State private var symbol = "creditcard.fill"
    @State private var colorID = "red"
    @State private var accountType = "card"
    @State private var annualRate = ""
    @State private var currency = "RUB"
    @State private var balance = ""
    @State private var saving = false
    @State private var prefilled = false

    init(account: FinanceAccount? = nil) {
        self.account = account
    }

    /// Original-rendering swatches preserve colour in native menu items.
    private var colorRow: some View {
        Menu {
            Picker("home.account.color", selection: $colorID) {
                ForEach(FIHomeStyle.colors, id: \.self) { color in
                    Label {
                        Text(LocalizedStringKey("home.color." + color))
                    } icon: {
                        Image(uiImage: FIHomeStyle.colorSwatches[color] ?? UIImage()).renderingMode(.original)
                    }.tag(color)
                }
            }
        } label: {
            FIListRow(title: Text("home.account.color")) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(FIHomeStyle.cardColor(colorID))
                        .frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(.black.opacity(0.15), lineWidth: 1))
                    Text(LocalizedStringKey("home.color." + colorID))
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .tint(.primary)
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                FICard {
                    FITextFieldRow("account.name.placeholder", text: $name)
                        .textInputAutocapitalization(.words)

                    FIRowSeparator()

                    FIMenuRow(title: Text("account.currency"), value: Text(currency)) {
                        ForEach(FinanceCurrencies.popular, id: \.self) { code in
                            Button(code) { currency = code }
                        }
                    }
                    FIRowSeparator()
                    FIMenuRow(title: Text("home.account.type"), value: Text(LocalizedStringKey("home.type." + accountType))) {
                        ForEach(["card", "cash", "deposit"], id: \.self) { type in
                            Button(LocalizedStringKey("home.type." + type)) { accountType = type }
                        }
                    }
                    FIRowSeparator()
                    colorRow
                    if accountType == "deposit" {
                        FIRowSeparator()
                        FIAmountRow(text: $annualRate, placeholder: "home.account.rate")
                    }

                }
                .fiCardInsets()
                .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(.clear)
            .fiSheetChrome(
                title: Text(account == nil ? "money.accounts.add" : "account.edit"),
                confirm: .confirm(isEnabled: !name.trimmingCharacters(in: .whitespaces).isEmpty && validRate && !saving) { save() },
                onClose: { dismiss() }
            )
        }
        .financeEditorSheet(error: $store.errorMessage)
        .onAppear(perform: prefill)
        .overlay {
            if saving {
                ProgressView().controlSize(.large)
            }
        }
    }

    @ViewBuilder
    private func iconButtons(_ icons: [FinanceAccountIcon]) -> some View {
        ForEach(icons) { icon in
            Button {
                symbol = icon.symbol
            } label: {
                Label {
                    Text(icon.titleKey)
                } icon: {
                    Image(systemName: icon.symbol == symbol ? "checkmark" : icon.symbol)
                }
            }
        }
    }

    private var balancePlaceholder: LocalizedStringKey {
        account == nil ? "account.opening_balance" : "account.balance"
    }

    /// Fills the fields once. Coming back from the pushed currency picker must
    /// not re-run this and throw away the code the user just chose.
    private func prefill() {
        guard !prefilled else { return }
        prefilled = true

        guard let account else {
            currency = store.mainCurrencyCode
            return
        }
        colorID = account.colorID.isEmpty ? "red" : account.colorID
        accountType = account.accountType.isEmpty ? (account.symbolName == "banknote.fill" ? "cash" : "card") : account.accountType
        annualRate = financeAmountText(Decimal(account.annualRateBasisPoints) / 100)
        name = account.name
        symbol = account.symbolName.isEmpty ? "creditcard.fill" : account.symbolName
        currency = account.balance.currencyCode.isEmpty ? "RUB" : account.balance.currencyCode
        balance = financeAmountText(account.balance.decimalValue)
    }

    private var validRate: Bool {
        guard accountType == "deposit" else { return true }
        guard let rate = financeDecimal(from: annualRate) else { return false }
        return rate >= 0 && rate <= 100
    }

    private func save() {
        guard validRate else { return }
        saving = true
        let appearance = FinanceAccountAppearance(colorID: colorID, accountType: accountType, annualRateBasisPoints: accountType == "deposit" ? NSDecimalNumber(decimal: (financeDecimal(from: annualRate) ?? 0) * 100).int32Value : 0)
        symbol = accountType == "cash" ? "banknote.fill" : (accountType == "deposit" ? "building.columns.fill" : "creditcard.fill")
        // On a new account an empty field means zero: most accounts start empty
        // and typing a 0 for that is busywork. On an existing one it means
        // "leave the money alone" — clearing the field to change the currency
        // must not also wipe the balance.
        let typed = financeDecimal(from: balance)
        let value = typed ?? (account?.balance.decimalValue ?? 0)

        Task {
            let saved: Bool
            if let account {
                // The balance travels whenever the amount or the currency
                // changed. Sending it unconditionally would let a rename
                // overwrite money that moved in the meantime; never sending it
                // left the currency stuck on the old code.
                let untouched = value == account.balance.decimalValue
                    && currency == account.balance.currencyCode
                saved = await store.updateAccount(
                    id: account.id,
                    name: name.trimmingCharacters(in: .whitespaces),
                    symbol: symbol,
                    balance: untouched ? nil : value,
                    currency: currency,
                    isArchived: account.isArchived, appearance: appearance
                )
            } else {
                saved = await store.createAccount(
                    name: name.trimmingCharacters(in: .whitespaces),
                    symbol: symbol,
                    opening: value,
                    currency: currency, appearance: appearance
                )
            }
            saving = false
            if saved { dismiss() }
        }
    }
}

/// Adjusts an account's balance up or down by an amount.
///
/// The account editor can already set a balance outright, but a correction is
/// how the question actually arrives: the bank says 12 340 and the app says
/// 12 300, so the answer is "add 40", not "work out 12 340 and type it in".
///
/// Written as a real transaction rather than a silent balance edit. A balance
/// that no longer equals the movements that produced it is a ledger nobody can
/// check, and a correction the user cannot find afterwards is the one entry they
/// will most want to find. The money is real too: if the bank says there is 40
/// more, that 40 came from somewhere the app failed to record, so counting it as
/// income is nearer the truth than hiding it.
struct BalanceCorrectionView: View {
    @EnvironmentObject private var store: FinanceStore
    @Environment(\.dismiss) private var dismiss

    let account: FinanceAccount

    private enum Direction: String, CaseIterable, Identifiable {
        case add, subtract
        var id: String { rawValue }
        var titleKey: LocalizedStringKey {
            self == .add ? "correction.add" : "correction.subtract"
        }
    }

    @State private var direction: Direction = .add
    @State private var amount = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: FITheme.Metrics.headerSpacing) {
                FICard {
                    FIListRow(
                        title: Text("correction.current"),
                        accessory: .value(Text(verbatim: account.balance.formatted))
                    )

                    FIRowSeparator()

                    FIMenuRow(title: Text("correction.direction"), value: Text(direction.titleKey)) {
                        ForEach(Direction.allCases) { option in
                            Button {
                                direction = option
                            } label: {
                                if option == direction {
                                    Label { Text(option.titleKey) } icon: {
                                        Image(systemName: "checkmark")
                                    }
                                } else {
                                    Text(option.titleKey)
                                }
                            }
                        }
                    }

                    FIRowSeparator()

                    FIAmountRow(text: $amount, placeholder: "correction.amount")

                    // The result, shown before it is committed: the point of a
                    // correction is landing on a particular number, so that
                    // number should be on screen before the tap that saves it.
                    if let preview = resultText {
                        FIRowSeparator()
                        FIListRow(
                            title: Text("correction.result"),
                            accessory: .value(Text(verbatim: preview))
                        )
                    }
                }

                FIFootnote("correction.hint")

                Spacer(minLength: 0)
            }
            .fiCardInsets()
            .padding(.top, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(.clear)
            .fiSheetChrome(
                title: Text("correction.title"),
                confirm: .confirm(isEnabled: delta != nil && !saving) { save() },
                onClose: { dismiss() }
            )
        }
        .financeEditorSheet(error: $store.errorMessage)
        .overlay {
            if saving {
                ProgressView().controlSize(.large)
            }
        }
    }

    /// The signed change, or `nil` while there is nothing to apply.
    private var delta: Decimal? {
        guard let value = financeDecimal(from: amount), value > 0 else { return nil }
        return direction == .add ? value : -value
    }

    private var resultText: String? {
        guard let delta else { return nil }
        let money = FinanceMoney(
            decimal: account.balance.decimalValue + delta,
            currencyCode: account.balance.currencyCode
        )
        return money.formatted
    }

    private func save() {
        guard let delta, let value = financeDecimal(from: amount) else { return }
        saving = true

        Task {
            let saved = await store.saveTransaction(
                kind: delta > 0 ? .income : .expense,
                accountID: account.id,
                destinationID: "",
                title: NSLocalizedString("correction.entry", comment: "Balance correction entry"),
                // No category: a correction is not spending on anything, and
                // filing it under one would count it against that category's
                // budget.
                category: "",
                amount: value,
                currency: account.balance.currencyCode,
                note: "",
                date: Date()
            )
            saving = false
            if saved { dismiss() }
        }
    }
}

// MARK: - Budgets

struct BudgetEditorView: View {
    @EnvironmentObject private var store: FinanceStore
    @EnvironmentObject private var categories: FinanceCategoryStore
    @Environment(\.dismiss) private var dismiss
    var budget: FinanceBudget?

    @State private var accountID = ""
    @State private var title = ""
    @State private var category = ""
    @State private var limit = ""
    @State private var reminder = true
    @State private var paymentDate = Date()
    @State private var recurrence: FinanceBudgetRecurrence = .monthly
    @State private var saving = false
    @State private var cover = FinancePlanCover.newPlan()
    @State private var loadingCover = false
    @State private var prefilled = false

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: FITheme.Metrics.headerSpacing) {
                    FIPlanCoverComposer(cover: $cover,
                        title: title.isEmpty ? NSLocalizedString("cover.preview.title", comment: "") : title,
                        amount: FinanceMoney(decimal: financeDecimal(from: limit) ?? 0, currencyCode: store.accounts.first(where: { $0.id == accountID })?.balance.currencyCode ?? budget?.limit.currencyCode ?? store.mainCurrencyCode).formatted,
                        loading: $loadingCover)

                    FICard {
                        FITextFieldRow("budget.name.placeholder", text: $title)
                            .textInputAutocapitalization(.sentences)

                        FIRowSeparator()

                        FIMenuRow(title: Text("transaction.account"), value: Text(store.accounts.first(where: { $0.id == accountID })?.name ?? NSLocalizedString("home.all_accounts", comment: "All accounts"))) {
                            Button("home.all_accounts") { accountID = "" }
                            ForEach(store.accounts) { account in Button(account.name) { accountID = account.id } }
                        }
                        FIRowSeparator()
                        FIMenuRow(title: Text("transaction.category"), value: Text(verbatim: categoryLabel)) {
                            categoryButtons
                        }

                        FIRowSeparator()

                        FIAmountRow(text: $limit, placeholder: "budget.limit.placeholder")
                        FIRowSeparator()
                        FIToggleRow("budget.remind", isOn: $reminder)

                        // The date and how often it comes round are only
                        // meaningful if there is a reminder to schedule.
                        if reminder {
                            FIRowSeparator()
                            FIDateRow("budget.payment_date", date: $paymentDate)

                            FIRowSeparator()
                            FIMenuRow(title: Text("budget.recurrence"), value: Text(recurrenceTitle(recurrence))) {
                                ForEach(recurrenceOptions, id: \.rawValue) { option in
                                    Button {
                                        recurrence = option
                                    } label: {
                                        if option == recurrence {
                                            Label { Text(recurrenceTitle(option)) } icon: {
                                                Image(systemName: "checkmark")
                                            }
                                        } else {
                                            Text(recurrenceTitle(option))
                                        }
                                    }
                                }
                            }
                        }

                        FIRowSeparator()

                    }


                    FIFootnote("budget.hint")
                }
                .fiCardInsets()
                .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(.clear)
            .fiSheetChrome(
                title: Text(budget == nil ? "budget.add" : "budget.edit"),
                confirm: .confirm(isEnabled: isValid && !saving && !loadingCover) { save() },
                onClose: { dismiss() }
            )
        }
        .presentationBackground(Color(uiColor: .systemGroupedBackground))
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .fiErrorAlert($store.errorMessage)
        .onAppear(perform: prefill)
        .overlay {
            if saving {
                ProgressView().controlSize(.large)
            }
        }
    }

    /// All expense categories remain available, including those already used
    /// by other budgets in this month.
    private var categoryOptions: [String] {
        var all = categories.options(for: .expense, existing: store.transactions)
        // A custom category may survive only on the budget (for example after
        // it was removed from the catalog). It must remain editable.
        if let budget {
            let current = FinanceCategoryStore.canonical(budget.category)
            if !current.isEmpty, !all.contains(current) { all.append(current) }
        }
        return all
    }

    /// The category menu.
    ///
    /// The button's value is the stored identifier — that is what gets written
    /// to the transaction — while the label is its localized name, so switching
    /// the app's language re-labels existing categories instead of splitting
    /// them into new ones.
    @ViewBuilder
    private var categoryButtons: some View {
        ForEach(categoryOptions, id: \.self) { option in
            Button {
                category = option
            } label: {
                let name = FinanceCategoryStore.displayName(for: option)
                if option == category {
                    Label(name, systemImage: "checkmark")
                } else {
                    Text(verbatim: name)
                }
            }
        }
    }

    /// Store the category identifier, preserving the choice when other
    /// budgets are added or refreshed while the editor is open.
    private var storedCategory: String {
        category.isEmpty ? (categoryOptions.first ?? "") : category
    }

    private var categoryLabel: String {
        FinanceCategoryStore.displayName(for: storedCategory)
    }

    private var recurrenceOptions: [FinanceBudgetRecurrence] {
        [.once, .weekly, .monthly, .quarterly, .yearly]
    }

    private func recurrenceTitle(_ value: FinanceBudgetRecurrence) -> LocalizedStringKey {
        switch value {
        case .weekly: "budget.recurrence.weekly"
        case .monthly: "budget.recurrence.monthly"
        case .quarterly: "budget.recurrence.quarterly"
        case .yearly: "budget.recurrence.yearly"
        default: "budget.recurrence.once"
        }
    }

    private var isValid: Bool {
        guard let value = financeDecimal(from: limit), value > 0 else { return false }
        return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !storedCategory.isEmpty
    }

    private func prefill() {
        guard !prefilled else { return }
        prefilled = true
        guard let budget else {
            if category.isEmpty { category = categoryOptions.first ?? "" }
            return
        }
        cover = FinancePlanCover.decode(budget.coverJSON)
        accountID = budget.accountID
        title = budget.title.isEmpty ? FinanceCategoryStore.displayName(for: budget.category) : budget.title
        category = FinanceCategoryStore.canonical(budget.category)
        limit = financeAmountText(budget.limit.decimalValue)
        reminder = budget.reminderEnabled
        recurrence = budget.recurrence == .unspecified ? .once : budget.recurrence
        if let storedDate = financeDate(from: budget.paymentDate) {
            paymentDate = storedDate
        }
    }

    private func save() {
        guard isValid, !saving, !loadingCover, let value = financeDecimal(from: limit) else { return }
        let coverJSON: String
        do { coverJSON = try cover.encoded() }
        catch { store.errorMessage = error.localizedDescription; return }
        saving = true

        Task {
            let saved = await store.upsertBudget(
                id: budget?.id ?? "",
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                category: storedCategory,
                limit: value,
                reminder: reminder,
                paymentDate: paymentDate,
                recurrence: recurrence, accountID: accountID, coverJSON: coverJSON
            )
            saving = false
            if saved { dismiss() }
        }
    }
}

// MARK: - Goals

struct GoalEditorView: View {
    @EnvironmentObject private var store: FinanceStore
    @EnvironmentObject private var categories: FinanceCategoryStore
    @Environment(\.dismiss) private var dismiss
    var goal: FinanceGoal?

    @State private var title = ""
    @State private var accountID = ""
    @State private var category = ""
    @State private var target = ""
    @State private var saving = false
    @State private var cover = FinancePlanCover.newPlan()
    @State private var loadingCover = false
    @State private var prefilled = false


    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: FITheme.Metrics.headerSpacing) {
                    FIPlanCoverComposer(cover: $cover,
                        title: title.isEmpty ? NSLocalizedString("cover.preview.title", comment: "") : title,
                        amount: FinanceMoney(decimal: financeDecimal(from: target) ?? 0, currencyCode: currency).formatted,
                        loading: $loadingCover)

                    FICard {
                        FITextFieldRow("goals.name.placeholder", text: $title)
                            .textInputAutocapitalization(.sentences)

                        FIRowSeparator()

                        FIMenuRow(title: Text("transaction.account"), value: Text(verbatim: accountLabel)) {
                            Button("home.all_accounts") { accountID = "" }
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

                        FIAmountRow(text: $target, placeholder: "goals.target.placeholder")
                    }

                    FIFootnote("goals.hint")
                }
                .fiCardInsets()
                .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(.clear)
            .fiSheetChrome(
                title: Text(goal == nil ? "goals.add" : "goals.edit"),
                confirm: .confirm(isEnabled: isValid && !saving && !loadingCover) { save() },
                onClose: { dismiss() }
            )
        }
        .presentationBackground(Color(uiColor: .systemGroupedBackground))
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .fiErrorAlert($store.errorMessage)
        .onAppear(perform: prefill)
        .overlay {
            if saving {
                ProgressView().controlSize(.large)
            }
        }
    }

    private var selectedAccount: FinanceAccount? {
        store.accounts.first { $0.id == accountID }
    }

    private var accountLabel: String {
        selectedAccount?.name ?? NSLocalizedString("home.all_accounts", comment: "")
    }

    /// One account supplies its currency. With all accounts, keep the goal's
    /// existing currency (or the main currency for a new goal).
    private var currency: String {
        let code = selectedAccount?.balance.currencyCode ?? ""
        return code.isEmpty ? (goal?.target.currencyCode ?? store.mainCurrencyCode) : code
    }

    private var categoryOptions: [String] {
        categories.options(for: .expense, existing: store.transactions)
    }

    /// The category menu.
    ///
    /// The button's value is the stored identifier — that is what gets written
    /// to the transaction — while the label is its localized name, so switching
    /// the app's language re-labels existing categories instead of splitting
    /// them into new ones.
    @ViewBuilder
    private var categoryButtons: some View {
        ForEach(categoryOptions, id: \.self) { option in
            Button {
                category = option
            } label: {
                let name = FinanceCategoryStore.displayName(for: option)
                if option == category {
                    Label(name, systemImage: "checkmark")
                } else {
                    Text(verbatim: name)
                }
            }
        }
    }

    /// What gets written to the transaction: the stable identifier, never the
    /// translated name. Storing the display name would file a spend under
    /// "Продукты" on a Russian phone and "Groceries" on an English one, and the
    /// two would never again be recognised as the same category.
    private var storedCategory: String {
        category.isEmpty ? (categoryOptions.first ?? "") : category
    }

    private var categoryLabel: String {
        FinanceCategoryStore.displayName(for: storedCategory)
    }

    private var isValid: Bool {
        guard let value = financeDecimal(from: target), value > 0 else { return false }
        return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (accountID.isEmpty || selectedAccount != nil)
    }

    private func prefill() {
        guard !prefilled else { return }
        prefilled = true
        guard let goal else {
            // Prefer an account already in the user's main currency, so the
            // default goal is denominated the way the rest of the app is.
            if accountID.isEmpty {
                let preferred = store.accounts.first { $0.balance.currencyCode == store.mainCurrencyCode }
                accountID = (preferred ?? store.accounts.first)?.id ?? ""
            }
            if category.isEmpty { category = categoryOptions.first ?? "" }
            return
        }
        cover = FinancePlanCover.decode(goal.coverJSON)
        title = goal.title
        accountID = goal.accountID
        category = FinanceCategoryStore.canonical(goal.category)
        target = financeAmountText(goal.target.decimalValue)
    }

    private func save() {
        guard isValid, !saving, !loadingCover, let value = financeDecimal(from: target) else { return }
        let coverJSON: String
        do { coverJSON = try cover.encoded() }
        catch { store.errorMessage = error.localizedDescription; return }
        saving = true

        Task {
            let stored = await store.upsertGoal(
                id: goal?.id ?? "",
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                accountID: accountID,
                category: storedCategory,
                target: value,
                currency: currency, coverJSON: coverJSON
            )
            saving = false
            if stored { dismiss() }
        }
    }
}

private func financeDate(from value: String) -> Date? {
    guard value.count == 10 else { return nil }
    let components = value.split(separator: "-").compactMap { Int($0) }
    guard components.count == 3 else { return nil }
    return Calendar.current.date(from: DateComponents(year: components[0], month: components[1], day: components[2]))
}

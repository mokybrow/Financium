import Combine
import SwiftUI

/// A category the user added, and which side of the ledger it belongs to.
///
/// The kind matters because the category menus are already split: an expense
/// sheet offering "Salary" is noise, and a category with no side would have to
/// appear in both.
struct FinanceCategory: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case expense, income

        var id: String { rawValue }

        var titleKey: LocalizedStringKey {
            switch self {
            case .expense: "categories.kind.expense"
            case .income: "categories.kind.income"
            }
        }
    }

    let name: String
    let kind: Kind
    var symbolName: String? = nil

    var id: String { "\(kind.rawValue).\(name)" }
}

/// The categories a transaction can be filed under.
///
/// A category is stored on a transaction as a plain string, and the backend has
/// no catalog of its own, so the stored value has to be stable across languages:
/// a budget on "Groceries" must keep matching after the user switches the app to
/// Russian. Built-in categories therefore keep a fixed English identifier in the
/// data and are only translated on the way to the screen. A category the user
/// types is stored exactly as typed — it is already in their language, and there
/// is nothing to translate it to.
@MainActor
final class FinanceCategoryStore: ObservableObject {
    /// Built in, in the order they are offered.
    nonisolated static let builtInExpense = [
        "Groceries", "Restaurants", "Clothing", "Leisure", "Transport", "Home",
        "Utilities", "Health", "Education", "Travel", "Subscriptions", "Pets", "Other"
    ]
    nonisolated static let builtInIncome = [
        "Salary", "Bonus", "Gift", "Refund", "Investment", "Freelance", "Other"
    ]

    @Published private(set) var custom: [FinanceCategory] = []
    /// Built-in categories the user removed, by lower-cased identifier. They
    /// stop being offered anywhere; transactions already filed under them are
    /// untouched.
    @Published private(set) var hiddenBuiltIns: Set<String> = []

    private let defaults: UserDefaults
    private static let storageKey = "finance.custom_categories.v2"
    private static let hiddenBuiltInsKey = "finance.hidden_builtin_categories"
    /// The first format: a bare list of names, all of them expenses.
    private static let legacyStorageKey = "finance.custom_categories"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hiddenBuiltIns = Set(defaults.stringArray(forKey: Self.hiddenBuiltInsKey) ?? [])

        if let data = defaults.data(forKey: Self.storageKey) {
            // Keyed on presence, not on decoding: falling through to the legacy
            // branch when stored data fails to decode would resurrect
            // categories the user had deleted.
            custom = (try? JSONDecoder().decode([FinanceCategory].self, from: data)) ?? []
            return
        }

        // Categories saved before the kind existed were all expenses, which is
        // what the only menu offering them was. Written through and the old key
        // dropped, so the mapping runs once rather than on every launch.
        let legacy = defaults.stringArray(forKey: Self.legacyStorageKey) ?? []
        var seen = Set<String>()
        custom = legacy
            .filter { seen.insert($0.lowercased()).inserted }
            .map { FinanceCategory(name: $0, kind: .expense) }

        if !legacy.isEmpty {
            persist()
            defaults.removeObject(forKey: Self.legacyStorageKey)
        }
    }

    // MARK: - Editing

    /// Adds a category, refusing a name that side of the ledger already has —
    /// a second "Health" would split one category's spending across two rows
    /// for no reason. The same name on the other side is fine: "Other" is
    /// legitimately both.
    @discardableResult
    func add(_ name: String, kind: FinanceCategory.Kind, symbolName: String = "tag") -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !exists(trimmed, kind: kind) else { return false }
        custom.append(FinanceCategory(name: trimmed, kind: kind, symbolName: symbolName))
        persist()
        return true
    }

    static let symbols = ["tag", "cart", "fork.knife", "cup.and.saucer", "tshirt", "house", "car", "bus", "airplane", "heart", "cross.case", "book", "graduationcap", "gift", "pawprint", "gamecontroller", "film", "music.note", "phone", "wifi", "bolt", "leaf", "sportscourt", "briefcase", "banknote", "creditcard", "chart.line.uptrend.xyaxis", "building.columns"]

    func symbol(for name: String, kind: FinanceCategory.Kind) -> String {
        if let custom = custom.first(where: { $0.kind == kind && $0.name.caseInsensitiveCompare(name) == .orderedSame }),
           let symbol = custom.symbolName { return symbol }
        switch Self.canonical(name) {
        case "Groceries": return "cart"
        case "Restaurants": return "fork.knife"
        case "Clothing": return "tshirt"
        case "Leisure": return "gamecontroller"
        case "Transport": return "car"
        case "Home": return "house"
        case "Utilities": return "bolt"
        case "Health": return "cross.case"
        case "Education": return "graduationcap"
        case "Travel": return "airplane"
        case "Subscriptions": return "repeat"
        case "Pets": return "pawprint"
        case "Salary": return "briefcase"
        case "Bonus": return "star"
        case "Gift": return "gift"
        case "Refund": return "arrow.uturn.backward"
        case "Investment": return "chart.line.uptrend.xyaxis"
        case "Freelance": return "laptopcomputer"
        default: return "tag"
        }
    }

    func remove(customIDs: Set<String>, builtIns: Set<String>) {
        custom.removeAll { customIDs.contains($0.id) }
        hiddenBuiltIns.formUnion(builtIns.map { Self.canonical($0).lowercased() })
        persist()
        persistHidden()
    }

    func remove(_ category: FinanceCategory) {
        custom.removeAll { $0 == category }
        persist()
    }

    /// Removes a built-in category from every menu. Reversible with
    /// `restoreBuiltIn`.
    func hideBuiltIn(_ identifier: String) {
        hiddenBuiltIns.insert(Self.canonical(identifier).lowercased())
        persistHidden()
    }

    func restoreBuiltIn(_ identifier: String) {
        hiddenBuiltIns.remove(Self.canonical(identifier).lowercased())
        persistHidden()
    }

    func restoreAllBuiltIns() {
        hiddenBuiltIns.removeAll()
        persistHidden()
    }

    func isBuiltInHidden(_ identifier: String) -> Bool {
        hiddenBuiltIns.contains(Self.canonical(identifier).lowercased())
    }

    /// Whether a category — built-in identifier or a custom name — is already
    /// on a recorded transaction, in which case it must not be removed.
    func isUsed(_ category: String, in transactions: [FinanceTransaction]) -> Bool {
        let target = Self.canonical(category).lowercased()
        return transactions.contains {
            !$0.category.isEmpty && Self.canonical($0.category).lowercased() == target
        }
    }

    func exists(_ name: String, kind: FinanceCategory.Kind) -> Bool {
        let candidate = name.trimmingCharacters(in: .whitespacesAndNewlines)

        // Checked in every bundled language, but only against built-ins on the
        // *same* side. `canonical` translates by name alone with no notion of
        // who asked, so an English-locale user typing "Дом" would still fold
        // into the built-in "Home" here. But "Groceries" is only ever a
        // built-in expense, so typing it for income must not collide with the
        // expense-side entry — that's exactly the case a user reasonably wants
        // (products bought for resale, say, tracked as its own income line).
        if let identifier = Self.identifiersByName[candidate.lowercased()],
           Self.builtInIdentifiers(for: kind).contains(identifier.lowercased()) {
            return true
        }

        let mine = custom.filter { $0.kind == kind }.map(\.name)
        return mine.contains { $0.caseInsensitiveCompare(candidate) == .orderedSame }
    }

    // MARK: - Storage

    private func persist() {
        guard let data = try? JSONEncoder().encode(custom) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private func persistHidden() {
        defaults.set(Array(hiddenBuiltIns), forKey: Self.hiddenBuiltInsKey)
    }

    // MARK: - Naming

    /// Every name a built-in category is known by, in every language the app
    /// ships, mapped back to its identifier.
    ///
    /// Transactions written by earlier builds stored the *translated* name, so
    /// the same category sits in the data as both "Groceries" and "Продукты".
    /// Without this the two are different categories: the menu offers both, the
    /// budget list shows one in each language, and a budget on one does not
    /// match spending filed under the other.
    private nonisolated static let identifiersByName: [String: String] = {
        var map: [String: String] = [:]
        for identifier in builtInExpense + builtInIncome {
            map[identifier.lowercased()] = identifier
            let key = "category.\(identifier.lowercased())"

            for code in Bundle.main.localizations {
                guard let path = Bundle.main.path(forResource: code, ofType: "lproj"),
                      let bundle = Bundle(path: path) else { continue }
                let name = bundle.localizedString(forKey: key, value: key, table: nil)
                if name != key { map[name.lowercased()] = identifier }
            }
        }
        return map
    }()

    /// The built-in identifiers that live on one side of the ledger, lower-cased
    /// for comparison against `identifiersByName`'s values.
    nonisolated static func builtInIdentifiers(for kind: FinanceCategory.Kind) -> Set<String> {
        let names = kind == .expense ? builtInExpense : builtInIncome
        return Set(names.map { $0.lowercased() })
    }

    /// The identifier a stored category belongs to, whatever language it was
    /// written in. Unknown values are the user's own and pass through.
    nonisolated static func canonical(_ stored: String) -> String {
        identifiersByName[stored.lowercased()] ?? stored
    }

    /// What a stored category is called on screen.
    ///
    /// Built-ins go through the string table; anything else is the user's own
    /// words and is shown untouched.
    nonisolated static func displayName(for stored: String) -> String {
        let identifier = canonical(stored)
        let key = "category.\(identifier.lowercased())"
        let translated = NSLocalizedString(key, comment: "Built-in category")
        // NSLocalizedString hands back the key when there is no entry for it,
        // which is exactly how a custom category identifies itself.
        return translated == key ? stored : translated
    }

    /// Everything on offer for a kind of transaction: the built-ins, the user's
    /// own of that kind, and any category already sitting on a transaction — so
    /// a category typed on another device still shows up in the menu.
    func options(for kind: TransactionEditorKind, existing: [FinanceTransaction]) -> [String] {
        // A transfer has no category: it is the same money in two places, not
        // money spent on anything.
        guard kind != .transfer else { return [] }

        let side: FinanceCategory.Kind = kind == .income ? .income : .expense
        let builtIn = (side == .income ? Self.builtInIncome : Self.builtInExpense)
            .filter { !isBuiltInHidden($0) }
        let mine = custom.filter { $0.kind == side }.map(\.name)
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

        // Only the stored values are folded onto identifiers, so a category the
        // data holds in two languages collapses to one entry. The user's own
        // names are left alone: canonicalizing them could silently rewrite a
        // custom category into a built-in that happens to share a translation.
        var seen = Set<String>()
        return (builtIn + mine + used.map { Self.canonical($0) })
            .filter { seen.insert($0.lowercased()).inserted }
    }
}

// MARK: - Screen

/// Profile → Categories. The user's own on top, the built-in ones below for
/// reference, and one note at the foot of the page explaining the lot.
struct CategoriesView: View {
    @EnvironmentObject private var categories: FinanceCategoryStore

    @State private var editing = false
    @State private var adding = false
    /// Rows ticked for deletion while editing (`Row.id`).
    @State private var selected: Set<String> = []
    @State private var confirmDelete = false

    private struct Row: Identifiable {
        let name: String        // stored identifier (built-in) or user name (custom)
        let display: String
        let kind: FinanceCategory.Kind
        let custom: FinanceCategory?
        var id: String { custom?.id ?? "builtin.\(name)" }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: FITheme.Metrics.sectionSpacing) {
                categorySection(.income)
                categorySection(.expense)


            }
            .fiCardInsets()
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .fiPageBackground()
        .navigationTitle(Text("categories.title"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(editing)
        .toolbar {
            // Each control is its own toolbar item with its own id, so a control
            // only ever fades in or out as a whole. Nothing morphs one item slot
            // between a menu and a plain button — that swap is what UIKit can't
            // animate smoothly on the very first tap.
            ToolbarItem(id: "categories.menu", placement: .topBarTrailing) {
                if !editing {
                    Menu {
                        Button { editing = true } label: {
                            Label("common.edit", systemImage: "pencil")
                        }
                        Button { adding = true } label: { Label("categories.add", systemImage: "plus") }
                        Divider()
                        Button {
                            categories.restoreAllBuiltIns()
                        } label: {
                            Label("categories.restore_builtins", systemImage: "arrow.uturn.backward")
                        }
                        .disabled(categories.hiddenBuiltIns.isEmpty)
                    } label: { Image(systemName: "ellipsis") }
                    .tint(.primary)
                }
            }
            ToolbarItem(id: "categories.cancel", placement: .cancellationAction) {
                if editing {
                    Button(role: .close) { endEditing() }
                        .tint(.primary)
                        .accessibilityLabel(Text("common.cancel"))
                }
            }
            ToolbarItem(id: "categories.delete", placement: .confirmationAction) {
                if editing {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Image(systemName: "trash")
                    }
                    .tint(.primary)
                    .disabled(selected.isEmpty)
                    .accessibilityLabel(Text("common.delete"))
                }
            }
        }
        .sheet(isPresented: $adding) { CategoryEditorView() }
        .alert(Text("categories.delete.selected"), isPresented: $confirmDelete) {
            Button("common.delete", role: .destructive) { deleteSelected() }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("categories.delete.message")
        }
    }

    private func rows(_ kind: FinanceCategory.Kind) -> [Row] {
        let builtIns = (kind == .income ? FinanceCategoryStore.builtInIncome : FinanceCategoryStore.builtInExpense)
            .filter { !categories.isBuiltInHidden($0) }
            .map { Row(name: $0, display: FinanceCategoryStore.displayName(for: $0), kind: kind, custom: nil) }
        let mine = categories.custom.filter { $0.kind == kind }
            .map { Row(name: $0.name, display: $0.name, kind: kind, custom: $0) }
        return builtIns + mine
    }

    @ViewBuilder
    private func categorySection(_ kind: FinanceCategory.Kind) -> some View {
        let items = rows(kind)
        if !items.isEmpty {
            FISection(kind == .income ? "categories.income" : "categories.expense") {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, row in
                    VStack(spacing: 0) {
                        if index > 0 { FIRowSeparator() }
                        categoryRow(row)
                    }
                }
            }
        }
    }

    private func categoryRow(_ row: Row) -> some View {
        let isOn = selected.contains(row.id)

        return HStack(spacing: 0) {
            if editing {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isOn ? FITheme.Palette.accent : Color.secondary)
                    .padding(.leading, FITheme.Metrics.cardInset)
                    .padding(.trailing, 4)
            }
            FIListRow(title: Text(verbatim: row.display), icon: categories.symbol(for: row.name, kind: row.kind), iconColor: FITheme.Palette.accent) {
                if row.custom != nil {
                    Image(systemName: "person.fill").foregroundStyle(FITheme.Palette.accent)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard editing else { return }
            if isOn { selected.remove(row.id) } else { selected.insert(row.id) }
        }
    }

    private func endEditing() {
        editing = false
        selected.removeAll()
    }

    private func deleteSelected() {
        let all = (rows(.income) + rows(.expense)).filter { selected.contains($0.id) }
        categories.remove(customIDs: Set(all.compactMap { $0.custom?.id }),
                          builtIns: Set(all.filter { $0.custom == nil }.map(\.name)))
        selected.removeAll()
    }

}

// MARK: - Editor

private struct CategoryEditorView: View {
    @EnvironmentObject private var categories: FinanceCategoryStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var kind: FinanceCategory.Kind = .expense
    @State private var symbolName = "tag"

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: FITheme.Metrics.headerSpacing) {
                FICard {
                    FITextFieldRow("categories.name.placeholder", text: $name)
                        .textInputAutocapitalization(.words)

                    FIRowSeparator()

                    FIMenuRow(title: Text("categories.kind"), value: Text(kind.titleKey)) {
                        ForEach(FinanceCategory.Kind.allCases) { option in
                            Button {
                                kind = option
                            } label: {
                                if option == kind {
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
                    Menu {
                        Picker("categories.icon", selection: $symbolName) {
                            ForEach(FinanceCategoryStore.symbols, id: \.self) { symbol in
                                Label(LocalizedStringKey("category.icon.\(symbol)"), systemImage: symbol).tag(symbol)
                            }
                        }
                    } label: {
                        FIListRow(title: Text("categories.icon")) {
                            HStack(spacing: 8) {
                                Image(systemName: symbolName)
                                Text(LocalizedStringKey("category.icon.\(symbolName)"))
                                Image(systemName: "chevron.up.chevron.down").font(.caption2)
                            }.foregroundStyle(.secondary)
                        }
                    }.tint(.primary)
                }

                if isDuplicate {
                    FIFootnote("categories.duplicate")
                } else {
                    FIFootnote("categories.hint")
                }

                Spacer(minLength: 0)
            }
            .fiCardInsets()
            .padding(.top, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .fiPageBackground()
            .fiSheetChrome(
                title: Text("categories.add"),
                confirm: .confirm(isEnabled: isValid) { save() },
                onClose: { dismiss() }
            )
        }
        .presentationDetents([.height(360), .large])
    }

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isDuplicate: Bool {
        !trimmed.isEmpty && categories.exists(trimmed, kind: kind)
    }

    private var isValid: Bool {
        !trimmed.isEmpty && !isDuplicate
    }

    private func save() {
        if categories.add(trimmed, kind: kind, symbolName: symbolName) { dismiss() }
    }
}

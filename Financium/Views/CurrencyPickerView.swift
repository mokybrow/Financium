import SwiftUI

/// Every currency the system knows about, with its localized name.
enum FinanceCurrencies {
    /// `commonISOCurrencyCodes` rather than `isoCurrencyCodes`: the latter
    /// includes withdrawn currencies and metals, which nobody keeps a bank
    /// account in.
    static let all: [String] = Locale.commonISOCurrencyCodes

    /// Shown first, because these cover almost every account anyone adds.
    static let popular = ["RUB", "USD", "EUR", "GBP", "CNY", "JPY", "TRY", "KZT", "AED", "GEL"]

    static func name(for code: String) -> String {
        Locale.current.localizedString(forCurrencyCode: code) ?? code
    }

    static func symbol(for code: String) -> String {
        // `Locale.currencySymbol` is the *locale's* symbol, not the code's, so
        // the symbol has to come from a formatter pinned to that currency.
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        return formatter.currencySymbol ?? code
    }

    /// SF Symbol for the sign, when one exists — used on the account rows.
    static func symbolName(for code: String) -> String {
        switch code.uppercased() {
        case "RUB": return "rublesign"
        case "USD": return "dollarsign"
        case "EUR": return "eurosign"
        case "GBP": return "sterlingsign"
        case "JPY", "CNY": return "yensign"
        case "TRY": return "turkishlirasign"
        case "KZT": return "tengesign"
        case "INR": return "indianrupeesign"
        case "KRW": return "wonsign"
        case "BRL": return "brazilianrealsign"
        case "NGN": return "nairasign"
        case "ILS": return "shekelsign"
        case "PHP": return "pesosign"
        case "THB": return "bahtsign"
        case "VND": return "dongsign"
        case "UAH": return "hryvniasign"
        case "GEL": return "larisign"
        case "PLN": return "florinsign"
        default: return "banknote"
        }
    }
}

/// Currency chooser.
///
/// A pushed, searchable list rather than a menu: there are around 150 codes, and
/// a menu that long is a scroll wheel you cannot search. `List` + `.searchable`
/// is what iOS does for exactly this shape of choice.
struct CurrencyPickerView: View {
    @Environment(\.dismiss) private var dismiss

    let selected: String
    let onSelect: (String) -> Void

    @State private var query = ""

    var body: some View {
        List {
            // The popular section disappears while searching: it would just
            // duplicate rows the query already matched.
            if query.isEmpty {
                Section {
                    ForEach(FinanceCurrencies.popular, id: \.self) { code in
                        row(code)
                    }
                } header: {
                    Text("currency.popular")
                }
            }

            Section {
                ForEach(filtered, id: \.self) { code in
                    row(code)
                }
            } header: {
                Text("currency.all")
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, prompt: Text("currency.search"))
        .navigationTitle(Text("currency.title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var filtered: [String] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return FinanceCurrencies.all }

        // Matches the code and the localized name, so both "EUR" and "евро"
        // find the same row.
        return FinanceCurrencies.all.filter { code in
            code.localizedCaseInsensitiveContains(trimmed)
                || FinanceCurrencies.name(for: code).localizedCaseInsensitiveContains(trimmed)
        }
    }

    private func row(_ code: String) -> some View {
        Button {
            onSelect(code)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: code)
                        .font(FITheme.Typography.rowTitle)
                        .foregroundStyle(.primary)

                    Text(verbatim: FinanceCurrencies.name(for: code))
                        .font(FITheme.Typography.rowSubtitle)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(verbatim: FinanceCurrencies.symbol(for: code))
                    .font(FITheme.Typography.rowValue)
                    .foregroundStyle(.secondary)

                if code == selected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(FITheme.Palette.accent)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

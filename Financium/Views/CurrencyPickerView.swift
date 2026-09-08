import SwiftUI

/// Every currency the system knows about, with its localized name.
nonisolated enum FinanceCurrencies {
    /// `commonISOCurrencyCodes` rather than `isoCurrencyCodes`: the latter
    /// includes withdrawn currencies and metals, which nobody keeps a bank
    /// account in.
    static let all: [String] = popular

    /// Shown first, because these cover almost every account anyone adds.
    static let popular = ["RUB", "USD", "EUR", "GBP", "CNY", "JPY", "TRY", "KZT", "AED", "GEL"]

    static func name(for code: String) -> String {
        Locale.current.localizedString(forCurrencyCode: code) ?? code
    }

    /// The currency's own sign, where it has one.
    ///
    /// Deliberately not taken from `NumberFormatter`. A formatter prints the
    /// sign as the *reader's* locale writes it, which is the disambiguated form
    /// for anything foreign: a Russian phone renders USD as "US$", an English
    /// one renders RUB as "RUB". Both are correct for prose and wrong on a row
    /// that has already said which account it belongs to. This table is the
    /// sign as the currency's own country writes it.
    ///
    /// `nil` where a currency has no distinctive sign, so callers can decide
    /// for themselves — print the ISO code, or nothing where the code is
    /// already on screen.
    static func sign(for code: String) -> String? {
        switch code.uppercased() {
        case "RUB": return "₽"
        case "USD": return "$"
        case "EUR": return "€"
        case "GBP": return "£"
        case "JPY": return "¥"
        case "CNY": return "¥"
        case "KZT": return "₸"
        case "TRY": return "₺"
        case "UAH": return "₴"
        case "GEL": return "₾"
        case "INR": return "₹"
        case "KRW": return "₩"
        case "THB": return "฿"
        case "VND": return "₫"
        case "ILS": return "₪"
        case "NGN": return "₦"
        case "PHP": return "₱"
        case "BRL": return "R$"
        case "AED": return "د.إ"
        case "PLN": return "zł"
        case "CZK": return "Kč"
        case "CHF": return "Fr."
        case "SEK", "NOK", "DKK", "ISK": return "kr"
        case "AMD": return "֏"
        case "AZN": return "₼"
        case "KGS": return "с"
        case "UZS": return "so'm"
        case "BYN": return "Br"
        case "HUF": return "Ft"
        case "BTC": return "₿"
        default: return nil
        }
    }

    /// What to print next to an amount: the sign if the currency has one, its
    /// ISO code otherwise. Never a locale-disambiguated form like "US$".
    static func symbol(for code: String) -> String {
        sign(for: code) ?? code.uppercased()
    }

    /// SF Symbol for the sign, when one exists — used on the account rows and
    /// beside each code in the picker.
    ///
    /// `nil` rather than a "banknote" fallback so callers can tell a real sign
    /// from a stand-in: an account row prints the text sign instead, which says
    /// more than a glyph that looks the same for every exotic currency.
    static func logo(for code: String) -> String? {
        switch code.uppercased() {
        case "RUB": return "rublesign"
        case "USD", "CAD", "AUD", "NZD", "HKD", "SGD", "MXN", "ARS", "CLP", "COP": return "dollarsign"
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
        case "CHF": return "francsign"
        case "BTC": return "bitcoinsign"
        default: return nil
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
        // The list draws its own grouped background, which is a different grey
        // from the one every other screen uses. Clearing it and putting the
        // app's background behind makes the pushed picker look like it belongs
        // to the sheet it was opened from.
        .scrollContentBackground(.hidden)
        .fiPageBackground()
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
                // Leading, and holding its width whether or not it is drawn, so
                // the codes stay in one column instead of shifting sideways as
                // the selection moves.
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(FITheme.Palette.accent)
                    .opacity(code == selected ? 1 : 0)
                    .frame(width: 18)
                    .accessibilityHidden(code != selected)

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: code)
                        .font(FITheme.Typography.rowTitle)
                        .foregroundStyle(.primary)

                    Text(verbatim: FinanceCurrencies.name(for: code))
                        .font(FITheme.Typography.rowSubtitle)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Only where the currency has a sign of its own: the code is
                // already the row's title, and printing it twice says nothing.
                if let sign = FinanceCurrencies.sign(for: code) {
                    Text(verbatim: sign)
                        .font(FITheme.Typography.rowValue)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        .listRowBackground(FITheme.Palette.card)
    }
}

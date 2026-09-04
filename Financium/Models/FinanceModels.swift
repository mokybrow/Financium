import Combine
import Foundation
import SwiftUI

nonisolated extension Finance_Account: Identifiable {}
nonisolated extension Finance_Transaction: Identifiable {}
nonisolated extension Finance_Budget: Identifiable {}
nonisolated extension Finance_Goal: Identifiable {}

// Not MainActor: the local backend is an actor and formats and builds money
// away from the main thread.
nonisolated extension Finance_Money {
    init(decimal: Decimal, currencyCode: String) {
        self.init()
        let scaled = decimal * 100
        minorUnits = NSDecimalNumber(decimal: scaled).int64Value
        self.currencyCode = currencyCode.uppercased()
    }

    var decimalValue: Decimal { Decimal(minorUnits) / 100 }

    /// "360 000,00 ₽" — the number in the reader's local grouping, the sign in
    /// the currency's own notation.
    ///
    /// A `.currency` formatter would write the sign the way the reader's locale
    /// disambiguates it, so a Russian phone printed dollars as "US$" and an
    /// English one printed roubles as "RUB". The row has already said which
    /// account the money is in; it needs the sign, not a lesson in which
    /// country's dollar this is.
    var formatted: String {
        let code = currencyCode.isEmpty ? "RUB" : currencyCode
        let number = decimalValue.formatted(.number.precision(.fractionLength(2)))
        // Non-breaking space: an amount must never wrap between its digits and
        // its sign.
        return number + "\u{00A0}" + FinanceCurrencies.symbol(for: code)
    }

    /// The same amount, shortened for a place that has no room for it.
    ///
    /// "1,5 млн ₽" instead of "1 500 000,00 ₽". A row is a glance: the reader
    /// is looking for the order of magnitude and whether it went up, and the
    /// last two decimal places of a seven-figure sum answer neither question
    /// while making the whole thing shrink until none of it can be read.
    ///
    /// Only where it is needed. Below ten thousand nothing is abbreviated,
    /// because "9,4 тыс." is longer to *read* than "9 400" even though it is
    /// shorter to print, and the exact figure is worth having when it fits.
    /// Anywhere the number is the subject rather than a label — the detail
    /// screens, the editors — keeps `formatted`.
    var abbreviated: String {
        let code = currencyCode.isEmpty ? "RUB" : currencyCode
        let symbol = FinanceCurrencies.symbol(for: code)
        let value = NSDecimalNumber(decimal: decimalValue).doubleValue
        let magnitude = abs(value)

        guard magnitude >= 10_000 else { return formatted }

        let sign = value < 0 ? "−" : ""
        let (scaled, unitKey): (Double, String) = if magnitude >= 1_000_000_000 {
            (magnitude / 1_000_000_000, "unit.billion")
        } else if magnitude >= 1_000_000 {
            (magnitude / 1_000_000, "unit.million")
        } else {
            (magnitude / 1_000, "unit.thousand")
        }

        // One decimal, and not even that once the integer part is three digits:
        // "847 тыс." says as much as "846,9 тыс." in less space.
        let fractionDigits = scaled >= 100 ? 0 : 1
        let number = scaled.formatted(.number.precision(.fractionLength(fractionDigits)))
        let unit = NSLocalizedString(unitKey, comment: "Abbreviated magnitude")
        return sign + number + "\u{00A0}" + unit + "\u{00A0}" + symbol
    }
}

enum FinanceSection: String, CaseIterable, Identifiable {
    case money, budget, goals
    var id: Self { self }

    /// Localized tab title. A `LocalizedStringKey` rather than a `String` so the
    /// tab bar picks the right language instead of shipping one hardcoded.
    var titleKey: LocalizedStringKey {
        switch self {
        case .money: "tab.money"
        case .budget: "tab.budget"
        case .goals: "tab.goals"
        }
    }

    var symbol: String {
        switch self {
        case .money: "creditcard"
        case .budget: "chart.pie"
        case .goals: "target"
        }
    }
}

nonisolated enum TransactionEditorKind: Identifiable, Equatable {
    case expense, income, transfer
    var id: Int {
        switch self { case .expense: 1; case .income: 2; case .transfer: 3 }
    }
    var proto: Finance_TransactionKind {
        switch self { case .expense: .expense; case .income: .income; case .transfer: .transfer }
    }
    var titleKey: LocalizedStringKey {
        switch self {
        case .expense: "money.add.expense"
        case .income: "money.add.incoming"
        case .transfer: "money.add.transfer"
        }
    }
}

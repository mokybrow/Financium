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
}

enum FinanceSection: String, CaseIterable, Identifiable {
    case money, budget, goals, profile
    var id: Self { self }

    /// Localized tab title. A `LocalizedStringKey` rather than a `String` so the
    /// tab bar picks the right language instead of shipping one hardcoded.
    var titleKey: LocalizedStringKey {
        switch self {
        case .money: "tab.money"
        case .budget: "tab.budget"
        case .goals: "tab.goals"
        case .profile: "tab.profile"
        }
    }

    var symbol: String {
        switch self {
        case .money: "creditcard"
        case .budget: "chart.pie"
        case .goals: "target"
        case .profile: "person.crop.circle"
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

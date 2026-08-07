import Combine
import Foundation
import SwiftUI

extension Finance_Account: Identifiable {}
extension Finance_Transaction: Identifiable {}
extension Finance_Budget: Identifiable {}
extension Finance_Goal: Identifiable {}

extension Finance_Money {
    init(decimal: Decimal, currencyCode: String) {
        self.init()
        let scaled = decimal * 100
        minorUnits = NSDecimalNumber(decimal: scaled).int64Value
        self.currencyCode = currencyCode.uppercased()
    }

    var decimalValue: Decimal { Decimal(minorUnits) / 100 }

    var formatted: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode.isEmpty ? "RUB" : currencyCode
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: decimalValue))
            ?? "\(decimalValue) \(currencyCode)"
    }
}

extension Finance_Transaction {
    var signedAmount: String {
        let prefix = kind == .expense ? "−" : kind == .income ? "+" : ""
        return prefix + amount.formatted
    }

    var symbolName: String {
        switch kind {
        case .expense: "arrow.up.right"
        case .income: "arrow.down.left"
        case .transfer: "arrow.left.arrow.right"
        default: "circle"
        }
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

enum TransactionEditorKind: Identifiable, Equatable {
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

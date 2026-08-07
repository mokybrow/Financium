import SwiftUI

/// The month chip and currency selector that sit under the title on Money,
/// Budget and Goals.
///
/// Shared rather than repeated three times because the month is one piece of
/// state on the store: switching it on Budget and coming back to Money must not
/// show two different months.
struct FinancePeriodRow: View {
    @EnvironmentObject private var store: FinanceStore

    var body: some View {
        HStack {
            Menu {
                ForEach(monthChoices, id: \.self) { month in
                    Button {
                        store.selectedMonth = month
                        Task { await store.refresh() }
                    } label: {
                        if Calendar.current.isDate(month, equalTo: store.selectedMonth, toGranularity: .month) {
                            Label(monthTitle(month), systemImage: "checkmark")
                        } else {
                            Text(verbatim: monthTitle(month))
                        }
                    }
                }
            } label: {
                FIMonthChip(title: monthTitle(store.selectedMonth))
            }
            .tint(.primary)

            Spacer(minLength: 12)

            FICurrencyMenu(code: currencyCode) {
                ForEach(currencyChoices, id: \.self) { code in
                    Button {
                        // Notifications are carried through unchanged: the
                        // settings call replaces the whole record, so a default
                        // here would quietly switch them off.
                        Task {
                            await store.updateSettings(
                                currency: code,
                                notifications: store.settings.notificationsEnabled
                            )
                        }
                    } label: {
                        if code == currencyCode {
                            Label(code, systemImage: "checkmark")
                        } else {
                            Text(verbatim: code)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, FITheme.Metrics.cardInset)
    }

    /// "Apr 2025" — abbreviated month plus year, as in the mock-ups.
    private func monthTitle(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).year())
    }

    /// A year back and one month forward: far enough to fix an old month, near
    /// enough that the menu stays a menu rather than a date picker.
    private var monthChoices: [Date] {
        Array((-11...1).compactMap { Calendar.current.date(byAdding: .month, value: $0, to: Date()) }.reversed())
    }

    private var currencyCode: String {
        let code = store.settings.mainCurrencyCode
        return code.isEmpty ? "RUB" : code.uppercased()
    }

    /// The user's own currency plus whatever their accounts are in, so the menu
    /// offers what is relevant instead of a list of 150 codes.
    private var currencyChoices: [String] {
        var codes = Set(store.accounts.map { $0.balance.currencyCode.uppercased() })
        codes.insert(currencyCode)
        codes.formUnion(FinanceCurrencies.popular)
        codes.remove("")
        return codes.sorted()
    }
}

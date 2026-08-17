import SwiftUI

/// The period chip, and optionally the currency the figures are shown in.
///
/// Shared rather than repeated three times because the period is one piece of
/// state on the store: switching it on Budget and coming back to Money must not
/// show two different windows.
///
/// The currency control only appears where there are figures for it to switch —
/// Money. It changes what is displayed and nothing else; the app's own currency
/// still lives in Profile.
struct FinancePeriodRow: View {
    @EnvironmentObject private var store: FinanceStore

    var showsCurrency = false

    @State private var choosingPeriod = false

    var body: some View {
        HStack {
            FIMonthChip(title: store.period.label) { choosingPeriod = true }

            Spacer()

            // Hidden with a single currency: a picker between one option is a
            // control that cannot do anything.
            if showsCurrency, store.displayCurrencyChoices.count > 1 {
                Menu {
                    ForEach(store.displayCurrencyChoices, id: \.self) { code in
                        Button {
                            store.displayCurrency = code
                        } label: {
                            if code == store.effectiveDisplayCurrency {
                                Label(code, systemImage: "checkmark")
                            } else {
                                Text(verbatim: code)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(verbatim: store.effectiveDisplayCurrency)
                            .font(.headline.weight(.semibold))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.footnote.weight(.semibold))
                    }
                    .foregroundStyle(FITheme.Palette.accent)
                }
                .accessibilityLabel(Text("money.currency"))
            }
        }
        .padding(.horizontal, FITheme.Metrics.cardInset)
        .sheet(isPresented: $choosingPeriod) {
            PeriodPickerView(period: store.period) { period in
                store.period = period
                // Forced: a read already in flight was issued for the previous
                // window and would answer with the wrong month.
                Task { await store.refresh(force: true) }
            }
        }
    }
}

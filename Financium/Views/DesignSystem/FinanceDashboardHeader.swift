import SwiftUI

/// Compact balance summary beneath the native navigation title.
struct FinanceDashboardHeader: View {
    @EnvironmentObject private var store: FinanceStore
    @EnvironmentObject private var rates: ExchangeRates
    @AppStorage("finance.secondaryCurrency") private var secondaryCurrency = "USD"

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text("home.current_balance").font(.subheadline).foregroundStyle(.secondary)
                Text(balance).font(.largeTitle.bold()).lineLimit(1).minimumScaleFactor(0.6)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 5) {
                Text(secondaryCurrency).font(.subheadline.weight(.medium))
                if let quote = rates.convert(1, from: secondaryCurrency, to: store.mainCurrencyCode) {
                    let change = rates.change(from: secondaryCurrency, to: store.mainCurrencyCode) ?? 0
                    HStack(spacing: 4) {
                        if change != 0 { Image(systemName: change > 0 ? "arrow.up" : "arrow.down") }
                        Text(FinanceMoney(decimal: quote, currencyCode: store.mainCurrencyCode).formatted)
                    }
                    .font(.headline)
                    .foregroundStyle(change < 0 ? Color.red : change > 0 ? Color.green : Color.primary)
                    if rates.isStale { Text("home.rate.cached").font(.caption2).foregroundStyle(.secondary) }
                } else { Text("home.rate.unavailable").font(.caption).foregroundStyle(.secondary) }
            }.padding(.bottom, 6)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
        .padding(.horizontal, 20)
    }

    private var balance: String {
        var total: Decimal = 0
        for account in store.accounts {
            guard let value = rates.convert(account.balance.decimalValue, from: account.balance.currencyCode, to: store.mainCurrencyCode) else { return "—" }
            total += value
        }
        let text = FinanceMoney(decimal: total, currencyCode: store.mainCurrencyCode).formatted
        return store.accounts.contains { $0.balance.currencyCode != store.mainCurrencyCode } ? "≈ " + text : text
    }

}

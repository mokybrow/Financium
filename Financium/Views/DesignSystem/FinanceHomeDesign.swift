import SwiftUI
import UIKit
import Charts

/// Shared geometry and colours for the home screen and its account details.
enum FIHomeStyle {
    static let colorSwatches: [String: UIImage] = Dictionary(uniqueKeysWithValues: colors.map { name in
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { _ in
            let circle = UIBezierPath(ovalIn: CGRect(x: 1, y: 1, width: 18, height: 18))
            UIColor(cardColor(name)).setFill()
            circle.fill()
            UIColor.label.withAlphaComponent(0.2).setStroke()
            circle.lineWidth = 0.5
            circle.stroke()
        }.withRenderingMode(.alwaysOriginal)
        return (name, image)
    })

    /// Fixed tile height — roughly the 1.588:1 payment-card ratio at the width
    /// a tile gets on a phone (screen − 40). Fixed rather than measured so the
    /// wallet animation isn't re-laying-out the card every frame.
    static let cardHeight: CGFloat = 220
    /// How much of a covered tile still shows in the collapsed stack.
    static let cardPeek: CGFloat = 56
    static let radius: CGFloat = 22
    /// The card colours the account editor offers — the RETRO palette plus a
    /// neutral trio. `brown` stays supported for the wallet artwork and for
    /// accounts created before this list, but is not offered.
    static let colors = ["yellow", "pink", "red", "purple", "green", "blue", "graphite", "black", "white"]

    static func cardColor(_ name: String) -> Color {
        switch name {
        case "yellow": Color(hex: "FFC567") ?? .yellow
        case "pink": Color(hex: "FB7DA8") ?? .pink
        case "red": Color(hex: "FD5A46") ?? .red
        case "purple": Color(hex: "552CB7") ?? .purple
        case "green": Color(hex: "00995E") ?? .green
        case "blue": Color(hex: "058CD7") ?? .blue
        case "graphite": Color(hex: "4A4A4F") ?? .gray
        case "black": Color(hex: "1C1C1E") ?? .black
        case "white": Color(hex: "FFFFFF") ?? .white
        case "brown": Color(red: 0.39, green: 0.32, blue: 0.31)
        default: Color(hex: "FD5A46") ?? .red
        }
    }

    /// Cards whose fill is light enough that their text and glyphs must be dark.
    static func prefersDarkInk(_ name: String) -> Bool {
        name == "yellow" || name == "white"
    }
}

struct FIAccountCard: View {
    let account: FinanceAccount
    var shared = false
    var showsBalance = true
    var add: (() -> Void)?
    private var colorID: String { account.colorID.isEmpty ? (isCash ? "brown" : "red") : account.colorID }

    /// Cash lives in a wallet; cards, current accounts and deposits are all
    /// carried as a bank card. The look of the tile follows from that.
    private var isCash: Bool {
        account.accountType == "cash" || account.symbolName == "banknote.fill" || account.symbolName == "wallet.bifold.fill"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(account.name).lineLimit(1)
                if shared { Image(systemName: "person.2.fill").font(.subheadline).accessibilityLabel(Text("money.account.shared")) }
                Spacer(minLength: 8)
                Text(account.balance.currencyCode)
            }.font(.title3.bold())
            Spacer(minLength: 8)
            if let add {
                HStack {
                    Spacer()
                    Button(action: add) { Image(systemName: "plus").font(.title2).frame(width: 48, height: 48) }
                        .buttonStyle(.plain).background(.white.opacity(0.45), in: Circle())
                        .accessibilityLabel(Text("common.add"))
                    Spacer()
                }
            }
            Spacer(minLength: 8)
            if showsBalance {
                Text("account.balance").font(.subheadline)
                Text(account.balance.formatted).font(.title3.bold()).lineLimit(1).minimumScaleFactor(0.65)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: FIHomeStyle.cardHeight)
        .background { cardBackground }
        .clipShape(RoundedRectangle(cornerRadius: FIHomeStyle.radius))
        .overlay {
            // A white card needs an edge to separate it from the page.
            if colorID == "white" {
                RoundedRectangle(cornerRadius: FIHomeStyle.radius)
                    .strokeBorder(.black.opacity(0.12), lineWidth: 1)
            }
        }
        .foregroundStyle(FIHomeStyle.prefersDarkInk(colorID) ? .black : .white)
    }

    @ViewBuilder
    private var cardBackground: some View {
        if isCash {
            // The wallet artwork carries its own clasp, bleeding off the
            // trailing edge; the clip shape above trims it to the tile.
            Image("WalletShape")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(FIHomeStyle.cardColor("brown"))
        } else {
            FIHomeStyle.cardColor(colorID)
        }
    }
}

/// The same analytics can be expanded on the home screen or presented alone.
struct HomeStatisticsView: View {
    @EnvironmentObject private var store: FinanceStore
    var embedded = false
    var onSky = false
    @State private var flowSelection: Date?
    @State private var expenseSelection: Double?
    @State private var incomeSelection: Double?
    @State private var forecastSelection: Date?
    @State private var forecastMonths = 3
    @State private var forecastBalance = false
    @State private var filter = AnalyticsFilter.all
    private let incomeColor = Color.blue
    private let expenseColor = Color.indigo

    private enum AnalyticsFilter: String, CaseIterable {
        case all, income, expense, savings
        var title: LocalizedStringKey { LocalizedStringKey("analytics." + rawValue) }
    }

    private var currency: String { store.effectiveDisplayCurrency }
    private var periodRows: [FinanceTransaction] {
        store.transactions.filter {
            ($0.kind == .income || $0.kind == .expense) && $0.amount.currencyCode == currency
        }
    }

    var body: some View {
        Group {
            if embedded { charts }
            else {
                ScrollView { charts.fiCardInsets().padding(.vertical, 12) }
                    .background(Color(uiColor: .systemBackground).ignoresSafeArea())
                    .navigationTitle(Text("home.statistics"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar(.visible, for: .navigationBar)
                    .toolbar(.hidden, for: .bottomBar)
                    .toolbarColorScheme(.light, for: .navigationBar)
                    .toolbarBackground(Color.white, for: .navigationBar)
                    .toolbarBackground(.visible, for: .navigationBar)
            }
        }
        .environment(\.colorScheme, .light)
        .tint(incomeColor)
        .onChange(of: store.period.label) { _, _ in resetSelection() }
        .onChange(of: currency) { _, _ in resetSelection() }
    }

    private var charts: some View {
        VStack(alignment: .leading, spacing: 24) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(AnalyticsFilter.allCases, id: \.self) { item in
                        Button { filter = item; flowSelection = nil } label: {
                            Text(item.title).font(.subheadline.weight(.medium))
                                .padding(.horizontal, 16).padding(.vertical, 10)
                                .foregroundStyle(filter == item ? Color.white : Color.primary)
                                .background(filter == item ? incomeColor : Color(uiColor: .secondarySystemBackground), in: Capsule())
                        }.buttonStyle(.plain)
                            .accessibilityAddTraits(filter == item ? .isSelected : [])
                    }
                }
            }
            if store.displayCurrencyChoices.count > 1 {
                HStack {
                    Text("money.currency").foregroundStyle(.secondary)
                    Spacer()
                    Picker("money.currency", selection: Binding(get: { currency }, set: { store.displayCurrency = $0 })) {
                        ForEach(store.displayCurrencyChoices, id: \.self) { Text($0).tag($0) }
                    }.pickerStyle(.menu)
                }.font(.subheadline)
            }
            if filter != .savings {
                FinancePeriodRow(showsCurrency: false, onSky: true)
                    .frame(maxWidth: .infinity)
            }
            switch filter {
            case .all:
                headline("home.current_balance", amount: store.accounts.filter { $0.balance.currencyCode == currency }.reduce(Decimal.zero) { $0 + $1.balance.decimalValue })
                flowChart
                HStack(spacing: 12) {
                    totalTile(kind: .income, color: incomeColor)
                    totalTile(kind: .expense, color: expenseColor)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(money(total(.income) - total(.expense))).font(.title3.bold()).monospacedDigit()
                    Text("analytics.net").font(.subheadline)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                .foregroundStyle(.primary)
                .background(incomeColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 18))
            case .income:
                headline("analytics.income.period", amount: total(.income))
                flowChart
                categoryChart("home.incomes", kind: .income, selection: $incomeSelection)
            case .expense:
                headline("analytics.expense.period", amount: total(.expense))
                flowChart
                categoryChart("home.expenses", kind: .expense, selection: $expenseSelection)
            case .savings:
                expectedIncome
            }
        }
    }

    private func headline(_ title: LocalizedStringKey, amount: Decimal) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(money(amount)).font(.largeTitle.bold()).monospacedDigit()
                .minimumScaleFactor(0.6).lineLimit(1)
        }
    }

    private var visibleKinds: [FinanceTransactionKind] {
        switch filter {
        case .income: [.income]
        case .expense: [.expense]
        case .all: [.income, .expense]
        case .savings: []
        }
    }

    private func total(_ kind: FinanceTransactionKind) -> Decimal {
        periodRows.filter { $0.kind == kind }.reduce(Decimal.zero) { $0 + $1.amount.decimalValue }
    }

    private func totalTile(kind: FinanceTransactionKind, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: kind == .income ? "arrow.down.left" : "arrow.up.right")
                .font(.headline).foregroundStyle(.white).frame(width: 38, height: 38).background(color, in: Circle())
            Text(money(total(kind))).font(.title3.bold()).lineLimit(1).minimumScaleFactor(0.6)
            Text(kindLabel(kind)).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22))
    }

    private struct FlowPoint: Identifiable {
        let date: Date
        let kind: FinanceTransactionKind
        let amount: Decimal
        var id: String { "\(date.timeIntervalSinceReferenceDate).\(kind.rawValue)" }
    }

    private var flowPoints: [FlowPoint] {
        guard !periodRows.isEmpty else { return [] }
        let calendar = Calendar.current
        let groups = Dictionary(grouping: periodRows) { calendar.startOfDay(for: $0.occurredAt.date) }
        let interval = store.period.interval
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now)) ?? .now
        // Days without transactions are zero; never interpolate across a gap as income.
        let end = min(interval.end, max(tomorrow, (groups.keys.max() ?? interval.start).addingTimeInterval(1)))
        var day = calendar.startOfDay(for: interval.start)
        var points: [FlowPoint] = []
        while day < end {
            for kind in [FinanceTransactionKind.income, .expense] {
                let amount = (groups[day] ?? []).filter { $0.kind == kind }.reduce(Decimal.zero) { $0 + $1.amount.decimalValue }
                points.append(FlowPoint(date: day, kind: kind, amount: amount))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return points
    }

    private var flowChart: some View {
        let points = flowPoints.filter { filter == .all || (filter == .income && $0.kind == .income) || (filter == .expense && $0.kind == .expense) }
        return VStack(alignment: .leading, spacing: 12) {
            if points.isEmpty { emptyChart }
            else {
                Chart(points) { point in
                    LineMark(x: .value("home.chart.date", point.date, unit: .day), y: .value("home.chart.amount", double(point.amount)))
                        .interpolationMethod(.linear)
                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                        .foregroundStyle(by: .value("home.chart.kind", kindLabel(point.kind)))
                        .accessibilityLabel(Text(point.date.formatted(.dateTime.day().month()) + " " + kindLabel(point.kind)))
                        .accessibilityValue(Text(money(point.amount)))
                    if points.count <= 2 || flowSelection.map({ Calendar.current.isDate(point.date, inSameDayAs: $0) }) == true {
                        PointMark(x: .value("home.chart.date", point.date, unit: .day), y: .value("home.chart.amount", double(point.amount)))
                            .foregroundStyle(by: .value("home.chart.kind", kindLabel(point.kind)))
                    }
                    if let selected = flowSelection, Calendar.current.isDate(point.date, inSameDayAs: selected), (point.kind == .income || filter == .expense) {
                        RuleMark(x: .value("home.chart.date", point.date, unit: .day)).foregroundStyle(.secondary.opacity(0.4))
                    }
                }
                .chartForegroundStyleScale([kindLabel(.income): incomeColor, kindLabel(.expense): expenseColor])
                .chartXSelection(value: $flowSelection)
                .chartLegend(position: .bottom)
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                } }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) }
                .frame(height: 220)
                Text("home.chart.hint").font(.caption).foregroundStyle(.secondary)
                if let selected = flowSelection {
                    Text(selected, format: .dateTime.day().month(.wide)).font(.subheadline.bold())
                    ForEach(visibleKinds, id: \.self) { kind in
                        HStack {
                            Text(kindLabel(kind))
                            Spacer()
                            Text(money(flowPoints.filter { $0.kind == kind && Calendar.current.isDate($0.date, inSameDayAs: selected) }.reduce(Decimal(0)) { $0 + $1.amount }))
                        }.font(.caption).monospacedDigit()
                    }
                }
            }
        }
    }

    private struct CategoryTotal: Identifiable {
        let name: String
        let value: Decimal
        var id: String { name }
    }

    private func categoryTotals(for kind: FinanceTransactionKind) -> [CategoryTotal] {
        var amounts: [String: Decimal] = [:]
        for transaction in periodRows where transaction.kind == kind {
            let name = FinanceCategoryStore.displayName(for: transaction.category)
            amounts[name, default: .zero] += transaction.amount.decimalValue
        }
        var totals: [CategoryTotal] = []
        for (name, amount) in amounts where amount > 0 {
            totals.append(CategoryTotal(name: name, value: amount))
        }
        totals.sort { lhs, rhs in
            if lhs.value == rhs.value { return lhs.name < rhs.name }
            return lhs.value > rhs.value
        }
        return totals
    }

    private func categoryChart(_ title: LocalizedStringKey, kind: FinanceTransactionKind, selection: Binding<Double?>) -> some View {
        let totals: [CategoryTotal] = categoryTotals(for: kind)
        let sum: Decimal = totals.reduce(Decimal.zero) { result, entry in result + entry.value }
        return statCard(title) {
            if totals.isEmpty { emptyChart }
            else {
                let selected = selectedCategory(totals, angle: selection.wrappedValue)
                Text(selected?.name ?? NSLocalizedString("home.chart.total", comment: "")).font(.subheadline.bold())
                Text(money(selected?.value ?? sum)).font(.headline).monospacedDigit()
                Chart(totals) { entry in
                    SectorMark(angle: .value("home.chart.amount", double(entry.value)), innerRadius: .ratio(0.58), angularInset: 2)
                        .cornerRadius(4)
                        .foregroundStyle(by: .value("transaction.category", entry.name))
                        .opacity(selected == nil || selected?.id == entry.id ? 1 : 0.35)
                        .accessibilityLabel(Text(entry.name))
                        .accessibilityValue(Text(money(entry.value)))
                }
                .chartForegroundStyleScale(range: [Color.blue, .indigo, .cyan, .purple, .teal, .gray])
                .chartAngleSelection(value: selection)
                .chartLegend(position: .bottom, alignment: .leading)
                .frame(height: 240)
                if let selected, sum > 0 {
                    Text((double(selected.value / sum)).formatted(.percent.precision(.fractionLength(1))))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func selectedCategory(_ totals: [CategoryTotal], angle: Double?) -> CategoryTotal? {
        guard let angle else { return nil }
        var boundary = 0.0
        for entry in totals {
            boundary += double(entry.value)
            if angle < boundary { return entry }
        }
        return totals.last
    }

    private struct ForecastPoint: Identifiable {
        let date: Date
        let value: Decimal
        let balance: Decimal
        var id: Date { date }
    }

    private var forecast: [ForecastPoint] {
        let accounts = store.accounts.filter { $0.balance.currencyCode == currency }
        guard !accounts.isEmpty else { return [] }
        let openingBalance = accounts.reduce(Decimal.zero) { $0 + $1.balance.decimalValue }
        let deposits = accounts.filter { $0.accountType == "deposit" }
        let annual = deposits.reduce(Decimal.zero) {
            $0 + max(0, $1.balance.decimalValue) * Decimal(max(0, $1.annualRateBasisPoints)) / 10_000
        }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: .now)
        guard let end = calendar.date(byAdding: .month, value: forecastMonths, to: start) else { return [] }
        var points = [ForecastPoint(date: start, value: 0, balance: openingBalance)]
        var date = start
        var income = Decimal.zero
        // Accrue each calendar day using that year's length; no compounding.
        while date < end {
            let daysInYear = calendar.range(of: .day, in: .year, for: date)?.count ?? 365
            income += annual / Decimal(daysInYear)
            guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { break }
            date = next
            points.append(ForecastPoint(date: date, value: income, balance: openingBalance + income))
        }
        return points
    }

    private var expectedIncome: some View {
        let points = forecast
        let selected = forecastSelection.flatMap { date in
            points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
        } ?? points.last
        return statCard("home.forecast.title") {
            Picker("home.forecast.period", selection: $forecastMonths) {
                Text("home.forecast.one").tag(1)
                Text("home.forecast.three").tag(3)
                Text("home.forecast.six").tag(6)
            }.pickerStyle(.segmented)
                .onChange(of: forecastMonths) { _, _ in forecastSelection = nil }
            Picker("home.forecast.metric", selection: $forecastBalance) {
                Text("home.forecast.income").tag(false)
                Text("home.forecast.balance").tag(true)
            }.pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 6) {
                Text(forecastBalance ? "home.forecast.balance" : "home.forecast.income")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text(selected.map { money(forecastBalance ? $0.balance : $0.value) } ?? "—")
                    .font(.largeTitle.bold()).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                if let selected {
                    Text(selected.date, format: .dateTime.day().month(.wide).year())
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("home.forecast.from_today").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.top, 10)

            forecastChart(points: points, selected: selected)

            if let selected {
                HStack {
                    Text(forecastBalance ? "home.forecast.income" : "home.forecast.balance")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(money(forecastBalance ? selected.value : selected.balance))
                        .fontWeight(.semibold).monospacedDigit()
                }.font(.subheadline).padding(.vertical, 8)
                Text("home.forecast.touch_hint").font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("home.forecast.calculation") {
                Text("home.forecast.note").font(.caption).foregroundStyle(.secondary)
                    .padding(.top, 4)
            }.font(.subheadline)
        }
    }

    private func forecastValue(_ point: ForecastPoint) -> Double {
        double(forecastBalance ? point.balance : point.value)
    }

    private func forecastDomain(_ points: [ForecastPoint]) -> ClosedRange<Double> {
        guard let first = points.first, let last = points.last else { return 0...1 }
        let low = min(forecastValue(first), forecastValue(last))
        let high = max(forecastValue(first), forecastValue(last))
        let padding = max((high - low) * 0.15, max(abs(high) * 0.005, 1))
        return (low >= 0 ? max(0, low - padding) : low - padding)...(high + padding)
    }

    private func forecastChart(points: [ForecastPoint], selected: ForecastPoint?) -> some View {
        let start = points.first?.date ?? Calendar.current.startOfDay(for: .now)
        let end = points.last?.date ?? Calendar.current.date(byAdding: .month, value: forecastMonths, to: start) ?? start.addingTimeInterval(86400)
        let domain = forecastDomain(points)
        return Chart {
            ForEach(points) { point in
                AreaMark(x: .value("home.chart.date", point.date),
                         yStart: .value("home.chart.amount", domain.lowerBound),
                         yEnd: .value("home.chart.amount", forecastValue(point)))
                    .interpolationMethod(.linear)
                    .foregroundStyle(LinearGradient(colors: [incomeColor.opacity(0.2), incomeColor.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                    .accessibilityHidden(true)
                LineMark(x: .value("home.chart.date", point.date), y: .value("home.chart.amount", forecastValue(point)))
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(incomeColor)
                    .accessibilityLabel(Text(point.date, format: .dateTime.day().month()))
                    .accessibilityValue(Text(money(forecastBalance ? point.balance : point.value)))
            }
            if let selected {
                RuleMark(x: .value("home.chart.date", selected.date))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(incomeColor.opacity(0.35))
                    .accessibilityHidden(true)
                PointMark(x: .value("home.chart.date", selected.date), y: .value("home.chart.amount", forecastValue(selected)))
                    .symbolSize(80).foregroundStyle(incomeColor)
                    .accessibilityHidden(true)
            }
        }
        .chartXScale(domain: start...end)
        .chartYScale(domain: domain)
        .chartXSelection(value: $forecastSelection)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 4]))
                if !points.isEmpty {
                    AxisValueLabel {
                        if let amount = value.as(Double.self) {
                            Text(amount.formatted(.number.notation(.compactName)))
                        }
                    }
                }
            }
        }
        .chartOverlay { _ in
            if points.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "chart.xyaxis.line").font(.title2).foregroundStyle(incomeColor)
                    Text("home.forecast.no_data").font(.headline)
                    Text("home.forecast.empty").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(20).frame(maxWidth: 240)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            }
        }
        .frame(height: 240)
        .padding(.vertical, 8)
    }

    private func statCard(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: FITheme.Metrics.headerSpacing) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(currency).font(.caption)
            }.foregroundStyle(onSky ? Color.white : Color.primary)
            FICard {
                VStack(alignment: .leading, spacing: 12, content: content)
                    .padding(FITheme.Metrics.cardInset)
                    .foregroundStyle(.primary)
            }
        }
    }
    private var emptyChart: some View {
        Text("activity.empty").font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 100)
    }
    private func money(_ value: Decimal) -> String { FinanceMoney(decimal: value, currencyCode: currency).formatted }
    private func double(_ value: Decimal) -> Double { NSDecimalNumber(decimal: value).doubleValue }
    private func kindLabel(_ kind: FinanceTransactionKind) -> String {
        NSLocalizedString(kind == .income ? "money.earned" : "money.spended", comment: "Chart legend")
    }
    private func resetSelection() { flowSelection = nil; expenseSelection = nil; incomeSelection = nil; forecastSelection = nil }
}

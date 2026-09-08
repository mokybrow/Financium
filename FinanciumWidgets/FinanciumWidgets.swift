import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Shared plumbing

/// The three colours the tiles need, stated here rather than imported.
///
/// The app's design system lives in the app target and pulls in most of the
/// interface with it; a widget extension that imported it would be compiling
/// screens it can never show. Three literals are cheaper than that, and they
/// are the app's own values.
private enum FIWidgetPalette {
    static let accent = Color(red: 0.0, green: 0.478, blue: 1.0)        // #007AFF
    static let positive = Color(red: 0.204, green: 0.780, blue: 0.349)  // #34C759
    static let destructive = Color(red: 1.0, green: 0.231, blue: 0.188) // #FF3B30
}


private struct FinanceEntry: TimelineEntry {
    let date: Date
    let snapshot: FinanceWidgetSnapshot
}

/// One provider for all three tiles.
///
/// They read the same snapshot and go stale at the same moment, so three
/// providers would be three copies of one decision about when to reload.
private struct FinanceProvider: TimelineProvider {
    func placeholder(in context: Context) -> FinanceEntry {
        FinanceEntry(date: .now, snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (FinanceEntry) -> Void) {
        completion(FinanceEntry(date: .now, snapshot: FinanceWidgetStore.load() ?? (context.isPreview ? .placeholder : .empty)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FinanceEntry>) -> Void) {
        let entry = FinanceEntry(date: .now, snapshot: FinanceWidgetStore.load() ?? .empty)
        // Only the app can produce fresh data. Re-reading never recalculates
        // totals; at a month boundary the view asks the user to open the app.
        let next = Calendar.current.date(byAdding: .hour, value: 1, to: .now) ?? .now.addingTimeInterval(3600)
        completion(Timeline(entries: [entry], policy: .after(min(next, Calendar.current.dateInterval(of: .month, for: .now)?.end ?? next))))
    }
}

extension FinanceWidgetSnapshot {
    /// What the gallery shows before a tile has any real data.
    static let placeholder = FinanceWidgetSnapshot(
        totalBalanceMinor: 37_684_600,
        spentMinor: 2_920_000,
        earnedMinor: 2_350_000,
        currencyCode: "RUB",
        budgets: [
            Budget(
                id: "placeholder",
                title: NSLocalizedString("widget.preview.budget", comment: "Preview budget"),
                spentMinor: 252_000,
                limitMinor: 240_000,
                currencyCode: "RUB"
            )
        ],
        updatedAt: .now,
        monthStart: .now
    )
}

/// The plain, theme-following surface every tile sits on.
///
/// `systemBackground` rather than a colour of our own: white on a light device,
/// near-black on a dark one, and it follows the appearance changing underneath
/// the widget without being told.
private extension View {
    func financeWidgetChrome() -> some View {
        containerBackground(for: .widget) {
            LinearGradient(colors: [Color(uiColor: .systemBackground), FIWidgetPalette.accent.opacity(0.07)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

// MARK: - Quick add

/// Two buttons, and the whole tile is those buttons.
///
/// A widget cannot present the transaction editor — a sheet needs the app — so
/// each side is a deep link that opens it. `Link` rather than `Button(intent:)`
/// for exactly that reason: the work happens in the app, and an intent that
/// only launches the app is a longer way of writing a link.
struct FinanciumQuickAddWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: FinanceWidgetStore.quickAddKind, provider: FinanceProvider()) { _ in
            QuickAddWidgetView()
                .financeWidgetChrome()
        }
        .configurationDisplayName(Text("widget.quick_add.title"))
        .description(Text("widget.quick_add.description"))
        .supportedFamilies([.systemSmall])
    }
}

private struct QuickAddWidgetView: View {
    var body: some View {
        VStack(spacing: 10) {
            action(
                title: Text("widget.quick_add.expense"),
                systemImage: "minus",
                tint: FIWidgetPalette.destructive,
                url: URL(string: "financium://new?kind=expense")
            )

            action(
                title: Text("widget.quick_add.income"),
                systemImage: "plus",
                tint: FIWidgetPalette.accent,
                url: URL(string: "financium://new?kind=income")
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func action(title: Text, systemImage: String, tint: Color, url: URL?) -> some View {
        Link(destination: url ?? URL(string: "financium://new")!) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(tint, in: Circle())

                title
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase)
                    .kerning(0.3)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
            .contentShape(Rectangle())
        }
    }
}

// MARK: - Summary

struct FinanciumSummaryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: FinanceWidgetStore.kind, provider: FinanceProvider()) { entry in
            SummaryWidgetView(snapshot: entry.snapshot)
                .financeWidgetChrome()
                .widgetURL(URL(string: "financium://money?period=month"))
        }
        .configurationDisplayName(Text("widget.summary.title"))
        .description(Text("widget.summary.description"))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct SummaryWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: FinanceWidgetSnapshot

    var body: some View {
        if !snapshot.isCurrentMonth {
            Label("widget.refresh", systemImage: "arrow.clockwise")
                .font(.callout)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("widget.month", systemImage: "chart.bar.xaxis")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if family == .systemMedium {
                        Text(snapshot.updatedAt, format: .dateTime.month(.wide))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if family == .systemMedium {
                    HStack(alignment: .top, spacing: 20) {
                        headline
                        VStack(spacing: 12) {
                            metric("widget.summary.earned", value: snapshot.earnedMinor, icon: "arrow.down.left", tint: FIWidgetPalette.positive)
                            metric("widget.summary.spent", value: snapshot.spentMinor, icon: "arrow.up.right", tint: FIWidgetPalette.destructive)
                        }
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    headline
                }
                Spacer(minLength: 0)
                HStack {
                    Text("widget.summary.total").foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(FinanceWidgetFormat.compact(snapshot.totalBalanceMinor, currencyCode: snapshot.currencyCode))
                        .monospacedDigit().privacySensitive()
                }
                .font(.caption).lineLimit(1).minimumScaleFactor(0.75)
            }
        }
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("widget.summary.difference").font(.caption).foregroundStyle(.secondary)
            Text(FinanceWidgetFormat.compactSigned(snapshot.differenceMinor, currencyCode: snapshot.currencyCode))
                .font(.system(.title2, design: .rounded, weight: .bold).monospacedDigit())
                .foregroundStyle(snapshot.differenceMinor < 0 ? FIWidgetPalette.destructive : FIWidgetPalette.positive)
                .lineLimit(1).minimumScaleFactor(0.65).privacySensitive()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metric(_ key: LocalizedStringKey, value: Int64, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(key, systemImage: icon).font(.caption2).foregroundStyle(tint)
            Text(FinanceWidgetFormat.compact(value, currencyCode: snapshot.currencyCode))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.7).privacySensitive()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// Each indicator is a separate gallery item, so adding all three needs no configuration.
enum MonthlyMetric: String {
    case difference, income, expense
    var title: LocalizedStringKey {
        switch self {
        case .difference: "widget.lock.difference"
        case .income: "widget.lock.income"
        case .expense: "widget.lock.expense"
        }
    }
    var icon: String {
        switch self {
        case .difference: "plus.forwardslash.minus"
        case .income: "arrow.down.left"
        case .expense: "arrow.up.right"
        }
    }
    func value(_ snapshot: FinanceWidgetSnapshot) -> Int64 {
        switch self {
        case .difference: snapshot.differenceMinor
        case .income: snapshot.earnedMinor
        case .expense: snapshot.spentMinor
        }
    }
}

struct FinanciumMonthlyWidget: Widget {
    let metric: MonthlyMetric
    init() { metric = .difference }
    init(metric: MonthlyMetric) { self.metric = metric }
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FinanciumMonthly." + metric.rawValue, provider: FinanceProvider()) { entry in
            MonthlyAccessoryView(snapshot: entry.snapshot, metric: metric)
                .containerBackground(for: .widget) { Color.clear }
                .widgetURL(URL(string: "financium://money?period=month"))
        }
        .configurationDisplayName(Text(metric.title))
        .description(Text("widget.lock.description"))
        .supportedFamilies([.accessoryInline, .accessoryCircular, .accessoryRectangular])
    }
}

private struct MonthlyAccessoryView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: FinanceWidgetSnapshot
    let metric: MonthlyMetric
    private var value: String {
        guard snapshot.isCurrentMonth else { return "—" }
        return metric == .difference
            ? FinanceWidgetFormat.compactSigned(metric.value(snapshot), currencyCode: snapshot.currencyCode)
            : FinanceWidgetFormat.compact(metric.value(snapshot), currencyCode: snapshot.currencyCode)
    }
    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                Text("\(Image(systemName: metric.icon)) \(Text(metric.title)) \(value)")
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    VStack(spacing: 2) {
                        Image(systemName: metric.icon).font(.caption).widgetAccentable()
                        Text(snapshot.isCurrentMonth
                             ? (metric == .difference
                                ? FinanceWidgetFormat.compactSigned(metric.value(snapshot))
                                : FinanceWidgetFormat.compact(metric.value(snapshot), currencyCode: ""))
                             : "—")
                            .font(.caption2.bold().monospacedDigit())
                            .lineLimit(1).minimumScaleFactor(0.75)
                        Text(snapshot.currencyCode).font(.system(size: 8, weight: .medium))
                    }.padding(4)
                }
            default:
                VStack(alignment: .leading, spacing: 2) {
                    Label(metric.title, systemImage: metric.icon).font(.caption.weight(.semibold)).widgetAccentable()
                    Text(value).font(.title3.bold().monospacedDigit()).lineLimit(1).minimumScaleFactor(0.65)
                    Text(snapshot.isCurrentMonth ? "widget.month" : "widget.refresh").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .privacySensitive()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(metric.title))
        .accessibilityValue(Text(value))
    }
}

// MARK: - Budget

private struct BudgetEntry: TimelineEntry {
    let date: Date
    let budget: FinanceWidgetSnapshot.Budget?
}

/// Its own provider, because this is the one tile whose contents depend on a
/// choice rather than only on the snapshot.
private struct BudgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> BudgetEntry {
        BudgetEntry(date: .now, budget: FinanceWidgetSnapshot.placeholder.budgets.first)
    }

    func snapshot(for configuration: BudgetWidgetConfigurationIntent, in context: Context) async -> BudgetEntry {
        BudgetEntry(date: .now, budget: resolve(configuration) ?? (context.isPreview ? FinanceWidgetSnapshot.placeholder.budgets.first : nil))
    }

    func timeline(for configuration: BudgetWidgetConfigurationIntent, in context: Context) async -> Timeline<BudgetEntry> {
        let entry = BudgetEntry(date: .now, budget: resolve(configuration))
        let next = Calendar.current.date(byAdding: .hour, value: 1, to: .now) ?? .now.addingTimeInterval(3600)
        return Timeline(entries: [entry], policy: .after(min(next, Calendar.current.dateInterval(of: .month, for: .now)?.end ?? next)))
    }

    /// The chosen budget, or the most-spent one.
    ///
    /// Falling back rather than showing nothing when the choice is gone: a
    /// budget can be deleted or renamed long after the tile was placed, and an
    /// empty square is a worse answer than a different budget.
    private func resolve(_ configuration: BudgetWidgetConfigurationIntent) -> FinanceWidgetSnapshot.Budget? {
        let budgets = FinanceWidgetStore.load()?.budgets ?? []
        if let chosen = configuration.budget?.id,
           let match = budgets.first(where: { $0.id == chosen }) {
            return match
        }
        return budgets.first
    }
}

/// One budget: its name, how much of it is gone, and what that is in money.
struct FinanciumBudgetWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: FinanceWidgetStore.budgetKind,
            intent: BudgetWidgetConfigurationIntent.self,
            provider: BudgetProvider()
        ) { entry in
            BudgetWidgetView(budget: entry.budget)
                .financeWidgetChrome()
        }
        .configurationDisplayName(Text("widget.budget.title"))
        .description(Text("widget.budget.description"))
        .supportedFamilies([.systemSmall])
    }
}

private struct BudgetWidgetView: View {
    let budget: FinanceWidgetSnapshot.Budget?

    var body: some View {
        Link(destination: URL(string: "financium://budgets?period=month")!) {
            if let budget {
                content(budget)
            } else {
                Text("widget.budget.empty")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func content(_ budget: FinanceWidgetSnapshot.Budget) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "gauge.with.dots.needle.50percent").foregroundStyle(ringTint(budget)).widgetAccentable()
                Spacer()
                Text("\(budget.percent)%").monospacedDigit().foregroundStyle(ringTint(budget))
            }.font(.caption.weight(.semibold))
            Text(budget.title).font(.subheadline.weight(.semibold)).lineLimit(2)
            Spacer(minLength: 0)
            Text(budget.isOverspent ? "widget.budget.over" : "widget.budget.left")
                .font(.caption2).foregroundStyle(.secondary)
            Text(FinanceWidgetFormat.compact(budget.remainingMinor, currencyCode: budget.currencyCode))
                .font(.system(.title3, design: .rounded, weight: .bold).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.7).privacySensitive()
            ProgressView(value: min(max(budget.progress, 0), 1)).tint(ringTint(budget))
                .accessibilityLabel(Text("widget.budget.title"))
                .accessibilityValue(Text("\(budget.percent)%"))
            Text(FinanceWidgetFormat.compact(budget.limitMinor, currencyCode: budget.currencyCode))
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func ringTint(_ budget: FinanceWidgetSnapshot.Budget) -> Color {
        budget.isOverspent ? FIWidgetPalette.destructive : FIWidgetPalette.accent
    }
}

// MARK: - Previews

#Preview("Quick add", as: .systemSmall) {
    FinanciumQuickAddWidget()
} timeline: {
    FinanceEntry(date: .now, snapshot: .placeholder)
}

#Preview("Summary", as: .systemMedium) {
    FinanciumSummaryWidget()
} timeline: {
    FinanceEntry(date: .now, snapshot: .placeholder)
}

#Preview("Budget", as: .systemSmall) {
    FinanciumBudgetWidget()
} timeline: {
    BudgetEntry(date: .now, budget: FinanceWidgetSnapshot.placeholder.budgets.first)
}

#Preview("Monthly net · Lock Screen", as: .accessoryRectangular) {
    FinanciumMonthlyWidget(metric: .difference)
} timeline: {
    FinanceEntry(date: .now, snapshot: .placeholder)
    FinanceEntry(date: .now, snapshot: .empty)
}

#Preview("Income · Lock Screen", as: .accessoryCircular) {
    FinanciumMonthlyWidget(metric: .income)
} timeline: {
    FinanceEntry(date: .now, snapshot: .placeholder)
}

#Preview("Expense · Lock Screen", as: .accessoryInline) {
    FinanciumMonthlyWidget(metric: .expense)
} timeline: {
    FinanceEntry(date: .now, snapshot: .placeholder)
}

#Preview("Monthly net · Small", as: .systemSmall) {
    FinanciumSummaryWidget()
} timeline: {
    FinanceEntry(date: .now, snapshot: .placeholder)
    FinanceEntry(date: .now, snapshot: .empty)
}

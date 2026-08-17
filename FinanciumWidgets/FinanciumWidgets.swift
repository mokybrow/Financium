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
        completion(FinanceEntry(date: .now, snapshot: FinanceWidgetStore.load() ?? .placeholder))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FinanceEntry>) -> Void) {
        let entry = FinanceEntry(date: .now, snapshot: FinanceWidgetStore.load() ?? .empty)
        // The app reloads these itself the moment the figures change, so this
        // is only a floor: it keeps a tile from sitting on yesterday's total if
        // the app has not been opened.
        let next = Calendar.current.date(byAdding: .hour, value: 1, to: .now) ?? .now.addingTimeInterval(3600)
        completion(Timeline(entries: [entry], policy: .after(next)))
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
                title: "Мобильный интернет",
                spentMinor: 252_000,
                limitMinor: 240_000,
                currencyCode: "RUB"
            )
        ],
        updatedAt: .now
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
            Color(uiColor: .systemBackground)
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
        HStack(spacing: 18) {
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
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(tint, in: Circle())

                title
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase)
                    .kerning(0.3)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
    }
}

// MARK: - Summary

/// The month in one picture: what is left, and where it went.
///
/// This was four labelled figures in a two-by-two grid — a table, and a table
/// makes the reader do the comparing. Four numbers of equal size say that all
/// four matter equally, which is not true: the balance is what the app is
/// opened for, and spending against income is a relationship rather than two
/// separate facts.
///
/// So: the balance leads, at a size that can be read across a room. Under it a
/// single bar splits the month into what came in and what went out, which is
/// the one shape that answers "how is this month going" without arithmetic —
/// a bar leaning red is a month spending more than it earns, and that is
/// visible before any of the figures are read. The two amounts label their own
/// halves, and the difference sits with the balance because it is the same
/// question asked over a shorter period.
struct FinanciumSummaryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: FinanceWidgetStore.kind, provider: FinanceProvider()) { entry in
            SummaryWidgetView(snapshot: entry.snapshot)
                .financeWidgetChrome()
        }
        .configurationDisplayName(Text("widget.summary.title"))
        .description(Text("widget.summary.description"))
        .supportedFamilies([.systemMedium])
    }
}

private struct SummaryWidgetView: View {
    let snapshot: FinanceWidgetSnapshot

    /// How much of the bar belongs to spending.
    ///
    /// Measured against the larger of the two, so the bar is always full and
    /// the split is the comparison. Against their sum, a month with no income
    /// would show spending at 100% and a month with no spending would show it
    /// at 0% — the same bar for two opposite situations.
    private var spentShare: Double {
        let spent = Double(snapshot.spentMinor)
        let earned = Double(snapshot.earnedMinor)
        let scale = max(spent, earned)
        guard scale > 0 else { return 0 }
        return min(max(spent / scale, 0), 1)
    }

    private var earnedShare: Double {
        let spent = Double(snapshot.spentMinor)
        let earned = Double(snapshot.earnedMinor)
        let scale = max(spent, earned)
        guard scale > 0 else { return 0 }
        return min(max(earned / scale, 0), 1)
    }

    private var isBehind: Bool { snapshot.differenceMinor < 0 }

    var body: some View {
        Link(destination: URL(string: "financium://money")!) {
            VStack(alignment: .leading, spacing: 14) {
                header
                bars
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("widget.summary.total")
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase)
                    .kerning(0.3)
                    .foregroundStyle(.secondary)

                Text(verbatim: FinanceWidgetFormat.compact(
                    snapshot.totalBalanceMinor,
                    currencyCode: snapshot.currencyCode
                ))
                .font(.system(size: 26, weight: .bold).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }

            Spacer(minLength: 12)

            // The month's net, as a badge rather than a fourth column: it is a
            // verdict on the two figures below, not a third one beside them.
            Text(verbatim: FinanceWidgetFormat.compactSigned(snapshot.differenceMinor))
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(isBehind ? FIWidgetPalette.destructive : FIWidgetPalette.positive)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    (isBehind ? FIWidgetPalette.destructive : FIWidgetPalette.positive).opacity(0.12),
                    in: Capsule()
                )
        }
    }

    private var bars: some View {
        VStack(alignment: .leading, spacing: 10) {
            flow(
                title: Text("widget.summary.earned"),
                value: FinanceWidgetFormat.compact(snapshot.earnedMinor, currencyCode: ""),
                share: earnedShare,
                tint: FIWidgetPalette.positive
            )

            flow(
                title: Text("widget.summary.spent"),
                value: FinanceWidgetFormat.compact(snapshot.spentMinor, currencyCode: ""),
                share: spentShare,
                tint: FIWidgetPalette.destructive
            )
        }
    }

    private func flow(title: Text, value: String, share: Double, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                title
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase)
                    .kerning(0.3)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                Text(verbatim: value)
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))

                    Capsule()
                        .fill(tint)
                        .frame(width: max(proxy.size.width * share, share > 0 ? 6 : 0))
                }
            }
            .frame(height: 6)
        }
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
        BudgetEntry(date: .now, budget: resolve(configuration) ?? FinanceWidgetSnapshot.placeholder.budgets.first)
    }

    func timeline(for configuration: BudgetWidgetConfigurationIntent, in context: Context) async -> Timeline<BudgetEntry> {
        let entry = BudgetEntry(date: .now, budget: resolve(configuration))
        let next = Calendar.current.date(byAdding: .hour, value: 1, to: .now) ?? .now.addingTimeInterval(3600)
        return Timeline(entries: [entry], policy: .after(next))
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
        Link(destination: URL(string: "financium://budgets")!) {
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
        VStack(spacing: 6) {
            // Two lines at a readable size, and a floor under the shrinking.
            //
            // It was one point smaller with `minimumScaleFactor(0.7)`, so
            // "Мобильный интернет" came out at eight points — legible in a
            // screenshot, not on a Home Screen. Wrapping is the right answer to
            // a long name; shrinking is what you do when there is nowhere to
            // wrap to, and here there is. The reserved height keeps the ring in
            // the same place whether the name takes one line or two.
            Text(verbatim: budget.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.9)
                .frame(height: 34)

            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.12), lineWidth: 8)

                Circle()
                    // Capped at a full turn so an overspent budget reads as a
                    // closed ring rather than winding round to look like a
                    // small one. The percentage in the middle is what says how
                    // far past it went.
                    .trim(from: 0, to: min(budget.progress, 1))
                    .stroke(ringTint(budget), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                Text(verbatim: "\(budget.percent)%")
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .frame(width: 60, height: 60)

            Text(verbatim: FinanceWidgetFormat.compact(budget.spentMinor, currencyCode: budget.currencyCode))
                .font(.system(size: 17, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

import SwiftUI

/// The Budget tab: one card of category limits, each row showing what is left
/// rather than what was set.
///
/// "Left" is the number a budget exists to answer; the limit itself lives on the
/// editor sheet, where it can be changed.
struct BudgetView: View {
    @EnvironmentObject private var store: FinanceStore
    @State private var editor: BudgetEditorTarget?

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: FITheme.Metrics.sectionSpacing) {
                    FinancePeriodRow()

                    if !store.budgets.isEmpty {
                        FICard {
                            ForEach(Array(store.budgets.enumerated()), id: \.element.id) { index, budget in
                                if index > 0 {
                                    FIRowSeparator()
                                }
                                row(budget)
                            }
                        }
                    }
                }
                .fiCardInsets()
                .padding(.top, 4)
                .padding(.bottom, 28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .fiPageBackground()
            .overlay {
                if store.budgets.isEmpty {
                    FIEmptyState(title: "budget.empty", subtitle: "budget.empty.subtitle")
                }
            }
            .navigationTitle(Text("budget.title"))
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    FIToolbarButton(systemImage: "plus", accessibilityLabel: "budget.add") {
                        editor = BudgetEditorTarget(budget: nil)
                    }
                }
            }
            .refreshable { await store.refresh() }
            .sheet(item: $editor) { target in
                BudgetEditorView(budget: target.budget)
            }
            .fiErrorAlert($store.errorMessage)
        }
    }

    private func row(_ budget: Finance_Budget) -> some View {
        Button {
            editor = BudgetEditorTarget(budget: budget)
        } label: {
            FIProgressRow(
                title: Text(verbatim: budget.title.isEmpty ? FinanceCategoryStore.displayName(for: budget.category) : budget.title),
                subtitle: Text(verbatim: spentText(budget)),
                trailing: Text(verbatim: statusText(budget)),
                trailingColor: isOverspent(budget) ? FITheme.Palette.destructive : .secondary,
                progress: progress(budget),
                tint: isOverspent(budget) ? FITheme.Palette.destructive : FITheme.Palette.accent
            )
        }
        .buttonStyle(.plain)
        // Pinned so a reordered list cannot leave a row's menu wired to the
        // budget that used to sit in that slot.
        .id(budget.id)
        .fiRowContextMenu {
            FIDestructiveMenuButton(titleKey: "budget.delete") {
                Task { await store.deleteBudget(budget) }
            }
        }
    }

    private func spentText(_ budget: Finance_Budget) -> String {
        String(
            format: NSLocalizedString("budget.spent_format", comment: "Spent of limit"),
            budget.spent.formatted,
            budget.limit.formatted
        )
    }

    private func isOverspent(_ budget: Finance_Budget) -> Bool {
        budget.spent.decimalValue > budget.limit.decimalValue
    }

    /// "3 000 ₽ left", or "500 ₽ over" once the limit is passed.
    ///
    /// Overspend used to be clamped to "0 left", which hid exactly the case a
    /// budget exists to catch.
    private func statusText(_ budget: Finance_Budget) -> String {
        let difference = budget.limit.decimalValue - budget.spent.decimalValue
        let money = Finance_Money(decimal: abs(difference), currencyCode: budget.limit.currencyCode)
        let key = difference >= 0 ? "budget.left_format" : "budget.over_format"
        return String(format: NSLocalizedString(key, comment: "Budget progress"), money.formatted)
    }

    private func progress(_ budget: Finance_Budget) -> Double {
        let limit = NSDecimalNumber(decimal: budget.limit.decimalValue).doubleValue
        guard limit > 0 else { return 0 }
        return NSDecimalNumber(decimal: budget.spent.decimalValue).doubleValue / limit
    }
}

/// Lets `sheet(item:)` present the editor both for a new budget and an existing
/// one — the id is what makes SwiftUI rebuild the sheet when the target changes.
struct BudgetEditorTarget: Identifiable {
    let budget: Finance_Budget?
    var id: String { budget?.id ?? "new" }
}

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

                    FICard {
                        if store.budgets.isEmpty {
                            FIEmptyState(title: "budget.empty", subtitle: "budget.empty.subtitle")
                        } else {
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
            .navigationTitle(Text("budget.title"))
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editor = BudgetEditorTarget(budget: nil)
                    } label: {
                        Image(systemName: "plus")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                }
            }
            .refreshable { await store.refresh() }
            .sheet(item: $editor) { target in
                BudgetEditorView(budget: target.budget)
            }
        }
    }

    private func row(_ budget: Finance_Budget) -> some View {
        Button {
            editor = BudgetEditorTarget(budget: budget)
        } label: {
            FIListRow(
                title: Text(verbatim: budget.category),
                subtitle: Text(verbatim: remainingText(budget)),
                accessory: .valueChevron(Text("common.edit"))
            )
        }
        .buttonStyle(.plain)
        // Pinned so a reordered list cannot leave a row's menu wired to the
        // budget that used to sit in that slot.
        .id(budget.id)
        .fiRowContextMenu {
            Button(role: .destructive) {
                Task { await store.deleteBudget(budget) }
            } label: {
                Label("budget.delete", systemImage: "trash")
            }
        }
    }

    /// Clamped at zero: an overspent budget has nothing left, and a negative
    /// "left" reads as though the app owed the user money.
    private func remainingText(_ budget: Finance_Budget) -> String {
        let remaining = max(0, budget.limit.decimalValue - budget.spent.decimalValue)
        let money = Finance_Money(decimal: remaining, currencyCode: budget.limit.currencyCode)
        return String(
            format: NSLocalizedString("budget.left_format", comment: "Remaining budget"),
            money.formatted
        )
    }
}

/// Lets `sheet(item:)` present the editor both for a new budget and an existing
/// one — the id is what makes SwiftUI rebuild the sheet when the target changes.
struct BudgetEditorTarget: Identifiable {
    let budget: Finance_Budget?
    var id: String { budget?.id ?? "new" }
}

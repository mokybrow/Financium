import SwiftUI

/// The Budget tab: one card of category limits, each row showing what is left
/// rather than what was set.
///
/// "Left" is the number a budget exists to answer; the limit itself lives on the
/// editor sheet, where it can be changed.
struct BudgetView: View {
    @EnvironmentObject private var store: FinanceStore
    @State private var editor: BudgetEditorTarget?
    /// The budget being read, and the one waiting on a confirmation.
    @State private var viewing: FinanceBudget?
    @State private var pendingDeletion: FinanceBudget?

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
                ToolbarItem(placement: .topBarTrailing) { ProfileToolbarButton() }
            }
            .refreshable { await store.refresh(force: true) }
            .sheet(item: $editor) { target in
                BudgetEditorView(budget: target.budget)
            }
            // While editing, the sheet owns save errors. Presenting the same
            // alert from the covered screen can compete with that presentation.
            .fiErrorAlert(Binding(
                get: { editor == nil ? store.errorMessage : nil },
                set: { store.errorMessage = $0 }
            ))
            .fiConfirmDelete($pendingDeletion) { budget in
                Task { await store.deleteBudget(budget) }
            }
            .sheet(item: $viewing) { budget in
                BudgetDetailView(budget: budget)
                    // Three rows of figures do not need a full screen, and a
                    // sheet the size of its contents leaves the list visible
                    // behind it — which is where the reader came from and is
                    // going back to.
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private func row(_ budget: FinanceBudget) -> some View {
        // A tap looks, a long press acts.
        //
        // Tapping straight into the editor meant the only way to read a budget
        // in full was to open the form that changes it — and the row shows
        // shortened figures, so the exact numbers had nowhere else to be seen.
        Button {
            viewing = budget
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
            Button {
                editor = BudgetEditorTarget(budget: budget)
            } label: {
                Label("common.edit", systemImage: "pencil")
            }

            FIDestructiveMenuButton(titleKey: "budget.delete") {
                pendingDeletion = budget
            }
        }
    }

    private func spentText(_ budget: FinanceBudget) -> String {
        String(
            format: NSLocalizedString("budget.spent_format", comment: "Spent of limit"),
            budget.spent.abbreviated,
            budget.limit.abbreviated
        )
    }

    private func isOverspent(_ budget: FinanceBudget) -> Bool {
        budget.spent.decimalValue > budget.limit.decimalValue
    }

    /// "3 000 ₽ left", or "500 ₽ over" once the limit is passed.
    ///
    /// Overspend used to be clamped to "0 left", which hid exactly the case a
    /// budget exists to catch.
    private func statusText(_ budget: FinanceBudget) -> String {
        let difference = budget.limit.decimalValue - budget.spent.decimalValue
        let money = FinanceMoney(decimal: abs(difference), currencyCode: budget.limit.currencyCode)
        let key = difference >= 0 ? "budget.left_format" : "budget.over_format"
        return String(format: NSLocalizedString(key, comment: "Budget progress"), money.abbreviated)
    }

    private func progress(_ budget: FinanceBudget) -> Double {
        budget.remainingProgress
    }
}

/// Lets `sheet(item:)` present the editor both for a new budget and an existing
/// one — the id is what makes SwiftUI rebuild the sheet when the target changes.
struct BudgetEditorTarget: Identifiable {
    let budget: FinanceBudget?
    var id: String { budget?.id ?? "new" }
}

/// A budget in full, with nothing shortened.
///
/// The row abbreviates — "1,5 млн ₽" — because a list is a glance. This is
/// where the reader comes when the glance was not enough, so every figure is
/// printed exactly as it is stored.
private struct BudgetDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let budget: FinanceBudget

    private var remaining: FinanceMoney {
        FinanceMoney(
            decimal: budget.limit.decimalValue - budget.spent.decimalValue,
            currencyCode: budget.limit.currencyCode
        )
    }

    private var isOverspent: Bool { budget.spent.decimalValue > budget.limit.decimalValue }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: FITheme.Metrics.sectionSpacing) {
                    FICard {
                        FIListRow(
                            title: Text("budget.view.limit"),
                            accessory: .value(Text(verbatim: budget.limit.formatted))
                        )
                        FIRowSeparator()
                        FIListRow(
                            title: Text("budget.view.spent"),
                            accessory: .value(Text(verbatim: budget.spent.formatted))
                        )
                        FIRowSeparator()
                        FIListRow(
                            title: Text(isOverspent ? "budget.over_title" : "budget.view.left"),
                            accessory: .value(
                                Text(verbatim: FinanceMoney(
                                    decimal: abs(remaining.decimalValue),
                                    currencyCode: budget.limit.currencyCode
                                ).formatted)
                            )
                        )
                    }
                }
                .fiCardInsets()
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .fiPageBackground()
            .navigationTitle(Text(verbatim: budget.title.isEmpty
                ? FinanceCategoryStore.displayName(for: budget.category)
                : budget.title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // The label colour, not the accent: `eoSheetChrome` tints
                    // every other sheet's close button this way, and a blue
                    // cross on one screen and a black one on the next reads as
                    // two different controls.
                    Button(role: .close) { dismiss() }
                        .tint(.primary)
                }
            }
        }
    }
}

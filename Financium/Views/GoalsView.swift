import SwiftUI

/// The Goals tab. Same shape as Budget — a card of rows with "X left" and an
/// Edit affordance — because they are the same idea pointed in opposite
/// directions: one caps spending, the other accumulates savings.
struct GoalsView: View {
    @EnvironmentObject private var store: FinanceStore
    @State private var editor: GoalEditorTarget?

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: FITheme.Metrics.sectionSpacing) {
                    FinancePeriodRow()

                    FICard {
                        if store.goals.isEmpty {
                            FIEmptyState(title: "goals.empty", subtitle: "goals.empty.subtitle")
                        } else {
                            ForEach(Array(store.goals.enumerated()), id: \.element.id) { index, goal in
                                if index > 0 {
                                    FIRowSeparator()
                                }
                                row(goal)
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
            .navigationTitle(Text("goals.title"))
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editor = GoalEditorTarget(goal: nil)
                    } label: {
                        Image(systemName: "plus")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                }
            }
            .refreshable { await store.refresh() }
            .sheet(item: $editor) { target in
                GoalEditorView(goal: target.goal)
            }
        }
    }

    private func row(_ goal: Finance_Goal) -> some View {
        Button {
            editor = GoalEditorTarget(goal: goal)
        } label: {
            FIListRow(
                title: Text(verbatim: goal.title.isEmpty ? goal.category : goal.title),
                subtitle: Text(verbatim: remainingText(goal)),
                accessory: .valueChevron(Text("common.edit"))
            )
        }
        .buttonStyle(.plain)
        .id(goal.id)
        .fiRowContextMenu {
            Button(role: .destructive) {
                Task { await store.deleteGoal(goal) }
            } label: {
                Label("goals.delete", systemImage: "trash")
            }
        }
    }

    /// Clamped at zero so a goal that has been met reads as done rather than as
    /// owing a negative amount.
    private func remainingText(_ goal: Finance_Goal) -> String {
        let remaining = max(0, goal.target.decimalValue - goal.saved.decimalValue)
        let money = Finance_Money(decimal: remaining, currencyCode: goal.target.currencyCode)
        return String(
            format: NSLocalizedString("goals.left_format", comment: "Remaining to save"),
            money.formatted
        )
    }
}

struct GoalEditorTarget: Identifiable {
    let goal: Finance_Goal?
    var id: String { goal?.id ?? "new" }
}

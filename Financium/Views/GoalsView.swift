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

                    if !store.goals.isEmpty {
                        FICard {
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
            .overlay {
                if store.goals.isEmpty {
                    FIEmptyState(title: "goals.empty", subtitle: "goals.empty.subtitle")
                }
            }
            .navigationTitle(Text("goals.title"))
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    FIToolbarButton(systemImage: "plus", accessibilityLabel: "goals.add") {
                        editor = GoalEditorTarget(goal: nil)
                    }
                }
            }
            .refreshable { await store.refresh() }
            .sheet(item: $editor) { target in
                GoalEditorView(goal: target.goal)
            }
            .fiErrorAlert($store.errorMessage)
        }
    }

    private func row(_ goal: Finance_Goal) -> some View {
        Button {
            editor = GoalEditorTarget(goal: goal)
        } label: {
            if let problem = problem(with: goal) {
                FIListRow(
                    title: Text(verbatim: name(of: goal)),
                    subtitle: Text(problem),
                    accessory: .valueChevron(Text("common.edit"))
                )
            } else {
                FIProgressRow(
                    title: Text(verbatim: name(of: goal)),
                    subtitle: Text(verbatim: savedText(goal)),
                    trailing: Text(verbatim: statusText(goal)),
                    trailingColor: isMet(goal) ? FITheme.Palette.positive : .secondary,
                    progress: progress(goal),
                    tint: isMet(goal) ? FITheme.Palette.positive : FITheme.Palette.accent
                )
            }
        }
        .buttonStyle(.plain)
        .id(goal.id)
        .fiRowContextMenu {
            FIDestructiveMenuButton(titleKey: "goals.delete") {
                Task { await store.deleteGoal(goal) }
            }
        }
    }

    private func name(of goal: Finance_Goal) -> String {
        goal.title.isEmpty ? FinanceCategoryStore.displayName(for: goal.category) : goal.title
    }

    private func account(of goal: Finance_Goal) -> Finance_Account? {
        store.accounts.first { $0.id == goal.accountID }
    }

    /// A goal only means something while the account it is saved into is still
    /// in reach.
    ///
    /// Progress *is* that account's balance, so an account gone from the list —
    /// deleted or archived, which this screen cannot tell apart — would show a
    /// confident 0%: a wrong number rather than a missing one. A currency that
    /// has since changed is no longer a problem: the goal follows the account,
    /// the way the account's own balance does.
    private func problem(with goal: Finance_Goal) -> LocalizedStringKey? {
        account(of: goal) == nil ? "goals.problem.no_account" : nil
    }

    /// What the account holds towards the goal — the balance the backend
    /// reports as `saved`, which is recomputed from the account on every load.
    private func savedText(_ goal: Finance_Goal) -> String {
        String(
            format: NSLocalizedString("goals.saved_format", comment: "Saved of target"),
            goal.saved.formatted,
            goal.target.formatted
        )
    }

    private func isMet(_ goal: Finance_Goal) -> Bool {
        goal.saved.decimalValue >= goal.target.decimalValue
    }

    /// "38 000 ₽ left" while saving, "3 000 ₽ over" once the target is passed.
    ///
    /// The old row clamped the remainder at zero, so a goal that had been
    /// beaten read "0 left" — indistinguishable from one landing exactly on
    /// target, and it threw away the thing the user most wants to see.
    private func statusText(_ goal: Finance_Goal) -> String {
        let difference = goal.target.decimalValue - goal.saved.decimalValue
        let money = Finance_Money(decimal: abs(difference), currencyCode: goal.target.currencyCode)
        let key = difference >= 0 ? "goals.left_format" : "goals.over_format"
        return String(format: NSLocalizedString(key, comment: "Goal progress"), money.formatted)
    }

    private func progress(_ goal: Finance_Goal) -> Double {
        let target = NSDecimalNumber(decimal: goal.target.decimalValue).doubleValue
        guard target > 0 else { return 0 }
        return NSDecimalNumber(decimal: goal.saved.decimalValue).doubleValue / target
    }
}

struct GoalEditorTarget: Identifiable {
    let goal: Finance_Goal?
    var id: String { goal?.id ?? "new" }
}

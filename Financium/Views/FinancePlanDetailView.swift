import SwiftUI
import Charts

struct FinancePlanDetailView: View {
    @EnvironmentObject private var store: FinanceStore
    @Environment(\.dismiss) private var dismiss
    let initialBudget: FinanceBudget?
    let initialGoal: FinanceGoal?
    let month: Date
    @State private var editing = false
    @State private var deleting = false
    @State private var confirmingDelete = false
    @State private var history: [FinanceTransaction] = []
    @State private var loading = true
    @State private var historyError: String?
    @State private var selectedDate: Date?
    @State private var historyEnd = Date()
    @State private var coverContentInset: CGFloat = 0

    init(budget: FinanceBudget, month: Date) {
        initialBudget = budget; initialGoal = nil; self.month = month
    }
    init(goal: FinanceGoal) {
        initialBudget = nil; initialGoal = goal; month = .now
    }

    private var budget: FinanceBudget? { initialBudget.map { original in store.budgets.first { $0.id == original.id } ?? original } }
    private var goal: FinanceGoal? { initialGoal.map { original in store.goals.first { $0.id == original.id } ?? original } }
    private var isBudget: Bool { initialBudget != nil }
    private var title: String {
        if let budget { return budget.title.isEmpty ? FinanceCategoryStore.displayName(for: budget.category) : budget.title }
        return goal?.title ?? ""
    }
    private var current: FinanceMoney { budget?.spent ?? goal?.saved ?? FinanceMoney() }
    private var target: FinanceMoney { budget?.limit ?? goal?.target ?? FinanceMoney() }
    private var accountID: String { budget?.accountID ?? goal?.accountID ?? "" }
    private var cover: FinancePlanCover { FinancePlanCover.decode(budget?.coverJSON ?? goal?.coverJSON ?? "") }
    private var shared: Bool { FinancePlanCollaboration.decode(budget?.collaborationJSON ?? goal?.collaborationJSON ?? "")?.isShared == true }
    private var progress: Double {
        guard target.minorUnits > 0 else { return 0 }
        return NSDecimalNumber(decimal: current.decimalValue / target.decimalValue).doubleValue
    }
    private var dataVersion: String {
        "\(store.transactions.hashValue).\(store.accounts.hashValue).\(accountID).\(budget?.category ?? "").\(target.currencyCode)"
    }

    var body: some View {
        GeometryReader { safeArea in
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GeometryReader { proxy in
                    FIPlanCoverTile(title: title, amount: target.abbreviated, progress: progress, cover: cover,
                                    size: proxy.size.width, showsAmount: false, cornerRadius: 24,
                                    contentTopInset: coverContentInset, showsCredit: true,
                                    showsProgress: false, titleAtBottom: true)
                }.aspectRatio(1, contentMode: .fit)
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("plan.progress").font(.title3.bold())
                        Spacer()
                        if shared { Label("plan.shared", systemImage: "person.2.fill").font(.caption) }
                    }
                    progressCard
                    Text("plan.dynamics").font(.title3.bold())
                    dynamicsCard
                }.padding(.horizontal, 20).padding(.bottom, 20)
            }
        }
        .ignoresSafeArea(edges: .top)
        .onGeometryChange(for: CGFloat.self) { viewport in
            // Measure the native toolbar exclusion against the fixed viewport,
            // not the scrolling cover, so its content does not drift on scroll.
            max(0, safeArea.frame(in: .global).minY - viewport.frame(in: .global).minY)
        } action: { coverContentInset = $0 }
        }
        .fiPageBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar(.hidden, for: .bottomBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme((cover.photo == nil && !FIPlanBackgroundCatalog.isDark(cover)) ? .light : .dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("common.edit", systemImage: "pencil") { editing = true }
                    Divider()
                    FIDestructiveMenuButton(titleKey: "common.delete") { confirmingDelete = true }
                } label: { Image(systemName: "ellipsis") }
                .tint(.primary)
                .disabled(deleting)
            }

        }
        .sheet(isPresented: $editing) {
            if let budget { BudgetEditorView(budget: budget) }
            else if let goal { GoalEditorView(goal: goal) }
        }
        .confirmationDialog("common.delete", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("common.delete", role: .destructive) {
                deleting = true
                Task {
                    if let budget { await store.deleteBudget(budget) }
                    else if let goal { await store.deleteGoal(goal) }
                    deleting = false
                    let exists = isBudget ? store.budgets.contains { $0.id == initialBudget?.id } : store.goals.contains { $0.id == initialGoal?.id }
                    if !exists { dismiss() }
                }
            }
            Button("common.cancel", role: .cancel) {}
        }
        .fiErrorAlert($store.errorMessage)
        .task(id: dataVersion) { await loadHistory() }
    }

    private var progressCard: some View {
        FICard {
            VStack(spacing: 14) {
                ProgressView(value: min(1, max(0, progress))).tint(.blue)
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(isBudget ? "plan.spent" : "plan.saved").font(.caption).foregroundStyle(.secondary)
                        Text(current.formatted).font(.headline)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(isBudget ? "plan.limit" : "plan.target").font(.caption).foregroundStyle(.secondary)
                        Text(target.formatted).font(.headline)
                    }
                }.monospacedDigit()
                if isBudget {
                    LabeledContent(current.minorUnits > target.minorUnits ? "plan.over_budget" : "plan.remaining",
                                   value: money(abs(target.decimalValue - current.decimalValue)))
                        .font(.caption).foregroundStyle(current.minorUnits > target.minorUnits ? Color.red : .secondary)
                }
            }.padding(18)
        }
    }

    private struct Point: Identifiable {
        let date: Date
        let value: Decimal
        var id: Date { date }
    }
    private var period: DateInterval {
        if isBudget {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let parts = Calendar.current.dateComponents([.year, .month], from: month)
            let start = calendar.date(from: parts) ?? month
            return DateInterval(start: start, end: calendar.date(byAdding: .month, value: 1, to: start) ?? start)
        }
        let end = historyEnd
        let start = Calendar.current.date(byAdding: .day, value: -30, to: Calendar.current.startOfDay(for: end)) ?? end
        return DateInterval(start: start, end: end)
    }
    private var relevant: [FinanceTransaction] {
        history.filter { transaction in
            guard transaction.occurredAt.date >= period.start, transaction.occurredAt.date < period.end else { return false }
            if let budget {
                return transaction.kind == .expense && transaction.category == budget.category &&
                    transaction.amount.currencyCode == target.currencyCode &&
                    (accountID.isEmpty || transaction.fromAccountID == accountID)
            }
            return delta(transaction) != 0
        }
    }
    private func delta(_ transaction: FinanceTransaction) -> Decimal {
        let ids: Set<String> = accountID.isEmpty
            ? Set(store.accounts.filter { $0.balance.currencyCode == target.currencyCode }.map(\.id)) : [accountID]
        var result = Decimal.zero
        if ids.contains(transaction.toAccountID), transaction.kind == .income || transaction.kind == .transfer {
            let received = transaction.kind == .transfer && transaction.hasDestinationAmount && transaction.destinationAmount.minorUnits > 0
                ? transaction.destinationAmount : transaction.amount
            result += received.decimalValue
        }
        if ids.contains(transaction.fromAccountID), transaction.kind == .expense || transaction.kind == .transfer {
            result -= transaction.amount.decimalValue
        }
        return result
    }
    private var points: [Point] {
        let rows = relevant.sorted { $0.occurredAt.date < $1.occurredAt.date }
        guard !rows.isEmpty else { return [] }
        var calendar = Calendar.current
        if isBudget { calendar.timeZone = TimeZone(secondsFromGMT: 0)! }
        let grouped = Dictionary(grouping: rows) { calendar.startOfDay(for: $0.occurredAt.date) }
        let net = rows.reduce(Decimal.zero) { $0 + delta($1) }
        let actualBalance = store.accounts.filter { accountID.isEmpty ? $0.balance.currencyCode == target.currencyCode : $0.id == accountID }
            .reduce(Decimal.zero) { $0 + $1.balance.decimalValue }
        var value = isBudget ? Decimal.zero : actualBalance - net
        var output = [Point(date: period.start, value: value)]
        for day in grouped.keys.sorted() {
            let change = (grouped[day] ?? []).reduce(Decimal.zero) { total, transaction in
                total + (isBudget ? transaction.amount.decimalValue : delta(transaction))
            }
            value += change
            output.append(Point(date: min(period.end, calendar.date(byAdding: .day, value: 1, to: day) ?? day).addingTimeInterval(-1), value: value))
        }
        if let last = output.last, last.date < min(Date(), period.end) {
            output.append(Point(date: min(Date(), period.end), value: value))
        }
        return output
    }
    private var dynamicsCard: some View {
        let values = points
        let selected = selectedDate.flatMap { date in values.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) } }
        return FICard {
            VStack(alignment: .leading, spacing: 10) {
                Text(isBudget ? month.formatted(.dateTime.month(.wide).year()) : NSLocalizedString("plan.last30", comment: ""))
                    .font(.subheadline).foregroundStyle(.secondary)
                if let selected {
                    Text(selected.date, format: .dateTime.day().month()).font(.caption)
                    Text(money(selected.value)).font(.headline).monospacedDigit()
                }
                Chart(values) { point in
                    LineMark(x: .value("home.chart.date", point.date), y: .value("home.chart.amount", NSDecimalNumber(decimal: point.value).doubleValue))
                        .interpolationMethod(.stepEnd).foregroundStyle(.blue)
                    PointMark(x: .value("home.chart.date", point.date), y: .value("home.chart.amount", NSDecimalNumber(decimal: point.value).doubleValue))
                        .foregroundStyle(.blue).symbolSize(25)
                }
                .chartXScale(domain: period.start...period.end)
                .chartXSelection(value: $selectedDate)
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in AxisValueLabel(format: .dateTime.day().month()) } }
                .frame(height: 180)
                .overlay {
                    if loading { ProgressView() }
                    else if let historyError {
                        VStack {
                            Text(historyError).font(.caption).multilineTextAlignment(.center)
                            Button("common.retry") { Task { await loadHistory() } }
                        }.padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    } else if values.isEmpty {
                        Text("plan.history.empty").font(.subheadline).foregroundStyle(.secondary)
                            .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
                if !isBudget { Text("plan.history.estimate").font(.caption).foregroundStyle(.secondary) }
            }.padding(18)
        }
    }
    private func money(_ value: Decimal) -> String { FinanceMoney(decimal: value, currencyCode: target.currencyCode).formatted }
    private func loadHistory() async {
        loading = true; historyError = nil; historyEnd = .now
        do {
            let rows = try await store.transactionsForPlan(from: period.start.addingTimeInterval(-86400), through: period.end)
            guard !Task.isCancelled else { return }
            history = rows
        } catch {
            guard !Task.isCancelled else { return }
            historyError = error.localizedDescription
        }
        loading = false
    }
}

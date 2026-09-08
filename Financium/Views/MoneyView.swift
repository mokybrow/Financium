import SwiftUI
import UIKit

struct MoneyView: View {
    @EnvironmentObject private var store: FinanceStore
    @EnvironmentObject private var rates: ExchangeRates
    @EnvironmentObject private var profile: ProfileStore
    /// The wallet card animation is fully hand-driven — no `matchedGeometryEffect`
    /// (too fragile with a scroll view and transitions). One `FIAccountCard`
    /// lives in a full-screen layer and its position is interpolated between the
    /// stack slot and the detail spot.
    @State private var cardProgress: CGFloat = 0   // 0 = in the stack, 1 = detail
    @State private var detailCardVisible = false
    @State private var transactionsReady = false
    @State private var draggingCard = false
    @State private var detailCardY: CGFloat?
    // Presentation samples are read only when a finger takes over. They must
    // not invalidate the entire home view on every animation frame.
    @State private var flightPosition = WalletFlightPosition()
    @State private var openingInterrupted = false
    @State private var dragStartTranslation: CGFloat = 0
    @State private var cardDrag: CGFloat = 0        // interactive dismiss
    @State private var cardFrames: [String: CGRect] = [:]
    @State private var closingCard = false
    @State private var selectedCardIndex = 0
    @State private var openedY: CGFloat = 0
    @State private var slotY: CGFloat = 0           // global minY of the opened slot
    @State private var contentTopY: CGFloat = 100   // global Y just below the nav bar
    @State private var showList = false             // the detail list, faded separately
    @State private var cardsAway = false            // the *other* cards, cleared out of the way
    private var walletSpring: Animation { .timingCurve(0.25, 0.1, 0.25, 1, duration: 0.58) }
    private var openingStack: Animation { .timingCurve(0.25, 0.1, 0.25, 1, duration: 0.82) }
    // Start together, settle in stack order: rear, selected, foreground.
    private var rearReturn: Animation { .timingCurve(0.25, 0.1, 0.25, 1, duration: 0.46) }
    private var selectedReturn: Animation { .timingCurve(0.25, 0.1, 0.25, 1, duration: 0.64) }
    private var foregroundReturn: Animation { .timingCurve(0.32, 0.05, 0.25, 1, duration: 0.88) }
    /// Where the card sits once open — just below the navigation bar.
    private var detailY: CGFloat { openedY }
    @State private var sheet: MoneySheet?
    @State private var activityKind: ActivityKind?
    @State private var accountActivity: FinanceAccount?
    /// Waiting on a confirmation. Deleting is one tap in a menu that opens on
    /// a long press, and none of it can be undone.
    @State private var pendingAccountDeletion: FinanceAccount?
    @State private var pendingBudgetDeletion: FinanceBudget?
    @State private var pendingGoalDeletion: FinanceGoal?
    /// The plain delete was refused because the account still has
    /// transactions — asking whether to take them with it.
    @State private var accountDeletionNeedsCascade: FinanceAccount?

    var body: some View {
        NavigationStack {
            ZStack {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        FinanceDashboardHeader()
                            .opacity(accountActivity == nil ? 1 : 0)
                            .transaction { $0.animation = nil }
                            .accessibilityHidden(accountActivity != nil)
                        accountsSection.padding(.horizontal, 20)
                        plansSection
                            // Inherit the active phase so plans and returning cards move together.
                            .offset(y: cardsAway ? 1100 : 0)
                    }
                    .padding(.bottom, 20)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .scrollEdgeEffectHidden(true, for: .top)
                .scrollDisabled(accountActivity != nil)
                .allowsHitTesting(accountActivity == nil)
                .refreshable {
                    await rates.refresh()
                    // A pull is a request for the truth now, so it does not
                    // settle for an answer that was already on its way.
                    await store.refresh(force: true)
                }

                if let account = accountActivity, showList {
                    AccountActivityView(
                        account: account, overlay: true,
                        cardVisible: detailCardVisible && !draggingCard,
                        transactionsHidden: draggingCard || !transactionsReady,
                        onCardFrame: { position in
                            guard !draggingCard && !closingCard else { return }
                            detailCardY = position
                            // Use the actual slot below the system toolbar.
                            if !detailCardVisible && !openingInterrupted { openedY = position }
                        },
                        onCardDrag: { value in
                            guard !closingCard, value > 0 else { return }
                            if !draggingCard { openedY = detailCardY ?? openedY }
                            draggingCard = true
                            cardDrag = value
                        },
                        onCardEnd: { distance, predicted in
                            guard draggingCard else { return }
                            if distance > 90 || predicted > 180 { closeCard() }
                            else {
                                withAnimation(walletSpring) { cardDrag = 0 } completion: {
                                    draggingCard = false
                                }
                            }
                        },
                        onClose: { closeCard() }
                    )
                        .zIndex(1)
                        .transition(.identity)
                }
            }
            .overlay(alignment: .top) {
                // Probe pinned to the top of the content area — its global Y is
                // where the nav bar ends, i.e. where the opened card should sit.
                Color.clear
                    .frame(height: 1)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { contentTopY = $0 }
            }
            .overlay { walletCardLayer }
            .fiPageBackground()
            .navigationTitle(showList ? Text("") : Text("app.title"))
            .toolbarTitleDisplayMode(showList ? .inline : .inlineLarge)
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                if !showList {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink { HomeStatisticsView() } label: {
                            Image(systemName: "chart.pie")
                        }.tint(.primary).accessibilityLabel(Text("home.statistics"))
                    }
                    ToolbarItem(placement: .bottomBar) {
                        Button { profile.isPresented = true } label: {
                            Image(systemName: "gear")
                        }
                        .tint(.primary)
                        .accessibilityLabel(Text("home.settings"))
                    }
                    ToolbarItem(placement: .bottomBar) { Spacer() }
                    ToolbarItem(placement: .bottomBar) { addMenu }
                }
            }
            .navigationDestination(item: $activityKind) { kind in
                AccountActivityView(kind: kind)
            }
            // One sheet, chosen by case. Stacked `.sheet` modifiers on the same
            // view fight over the presentation and only the last one reliably
            // wins — a bug that shows up as a tap doing nothing.
            .sheet(item: $sheet) { destination in
                switch destination {
                case .transaction(let kind):
                    TransactionEditorView(kind: kind)
                case .account(let account):
                    AccountEditorView(account: account)
                case .correction(let account):
                    BalanceCorrectionView(account: account)
                case .budget(let budget): BudgetEditorView(budget: budget)
                case .goal(let goal): GoalEditorView(goal: goal)
                }
            }
            .fiErrorAlert($store.errorMessage)
            .fiConfirmDelete($pendingBudgetDeletion) { budget in Task { await store.deleteBudget(budget) } }
            .fiConfirmDelete($pendingGoalDeletion) { goal in Task { await store.deleteGoal(goal) } }
            .fiConfirmDelete($pendingAccountDeletion) { account in
                Task {
                    if await store.deleteAccount(account) == .hasTransactions {
                        accountDeletionNeedsCascade = account
                    }
                }
            }
            .alert(
                Text("money.account.delete.has_transactions.title"),
                isPresented: Binding(
                    get: { accountDeletionNeedsCascade != nil },
                    set: { if !$0 { accountDeletionNeedsCascade = nil } }
                )
            ) {
                Button("money.account.delete.force", role: .destructive) {
                    if let account = accountDeletionNeedsCascade {
                        Task { await store.deleteAccount(account, cascade: true) }
                    }
                }
                Button("common.cancel", role: .cancel) {}
            } message: {
                Text("money.account.delete.has_transactions.message")
            }
            .onChange(of: store.pendingQuickAdd) { _, kind in
                guard kind != nil else { return }
                presentPendingQuickAdd()
            }
            .task {
                // A tile tapped from a cold start sets this before this screen
                // exists, so the change above never fires. Checked once on
                // appearance for that case.
                presentPendingQuickAdd()
            }
        }

    }

    /// Opens the editor a widget asked for, once there is something to open it
    /// from.
    ///
    /// Deferred by one turn of the run loop. A tile tapped from a cold start
    /// sets this while the tab bar is still being assembled, and presenting a
    /// sheet from a `TabHostingController` that is not yet in the view
    /// hierarchy is what produced "Presenting view controller from detached
    /// view controller" — a warning today, a crash in a future release, and in
    /// the meantime a sheet with the wrong safe-area insets.
    private func presentPendingQuickAdd() {
        guard let kind = store.pendingQuickAdd else { return }
        store.pendingQuickAdd = nil
        Task { @MainActor in
            sheet = .transaction(kind)
        }
    }


    /// Every other card clears straight down off the screen while a card is open.
    private func cardsSlideAway(_ index: Int) -> CGFloat {
        guard cardsAway else { return 0 }
        return 1100
    }

    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.accounts.isEmpty {
                if let failure = store.loadFailure {
                    accountsNotice(title: Text("money.accounts.failed"), detail: Text(failure)) {
                        Button("common.retry") { Task { await store.refresh(force: true) } }
                    }
                } else if store.hasLoaded {
                    Button { sheet = .account(nil) } label: {
                        VStack {
                            HStack { Text("account.name.placeholder"); Spacer(); Text("account.currency") }.font(.title3.bold()).foregroundStyle(.white)
                            Spacer()
                            Image(systemName: "plus").font(.title2).frame(width: 48, height: 48).background(.white.opacity(0.5), in: Circle())
                            Spacer()
                        }.padding(12).frame(height: FIHomeStyle.cardHeight)
                            .background(Color.gray.opacity(0.65), in: RoundedRectangle(cornerRadius: FIHomeStyle.radius))
                    }.buttonStyle(.plain).accessibilityLabel(Text("money.accounts.add"))
                } else { ProgressView().frame(maxWidth: .infinity).frame(height: 225) }
            } else {
                VStack(spacing: -(FIHomeStyle.cardHeight - FIHomeStyle.cardPeek)) {
                    ForEach(Array(store.accounts.enumerated()), id: \.element.id) { index, account in
                        // Keep the source view and its layout identity throughout the flight.
                        accountRow(account)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                                if accountActivity == nil { cardFrames[account.id] = $0 }
                            }
                            .zIndex(Double(index))
                            .opacity(accountActivity != nil && index >= selectedCardIndex ? 0 : 1)
                            .offset(y: accountActivity?.id == account.id ? 0 : cardsSlideAway(index))
                            .animation(closingCard ? rearReturn : openingStack, value: cardsAway)
                    }
                }
            }
        }
    }

    /// Budgets and goals share one list on the home screen — both are "a target
    /// and how far along it is".
    private enum PlanItem: Identifiable {
        case budget(FinanceBudget)
        case goal(FinanceGoal)
        var id: String {
            switch self {
            case .budget(let budget): "budget.\(budget.id)"
            case .goal(let goal): "goal.\(goal.id)"
            }
        }
    }

    private var planItems: [PlanItem] {
        store.budgets.map(PlanItem.budget) + store.goals.map(PlanItem.goal)
    }

    private var plansSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("home.plans").font(.headline).padding(.horizontal, 20)
            if planItems.isEmpty {
                VStack(spacing: 14) {
                    Image("AppIconPreview").resizable().scaledToFit()
                        .frame(width: 80, height: 80).clipShape(RoundedRectangle(cornerRadius: 20))
                    Text("plans.empty.title").font(.title3.bold())
                    Text("plans.empty.hint").font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.horizontal, 40).padding(.vertical, 40)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(planItems) { item in planRow(item) }
                    }.scrollTargetLayout()
                }
                .contentMargins(.horizontal, 20, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func planRow(_ item: PlanItem) -> some View {
        switch item {
        case .budget(let budget):
            NavigationLink { FinancePlanDetailView(budget: budget, month: store.period.anchorMonth) } label: {
                planTile(title: budget.title.isEmpty ? FinanceCategoryStore.displayName(for: budget.category) : budget.title,
                         amount: budget.limit, current: budget.spent.decimalValue, target: budget.limit.decimalValue,
                         coverJSON: budget.coverJSON, shared: FinancePlanCollaboration.decode(budget.collaborationJSON)?.isShared == true, kind: "budget.title")
            }
        case .goal(let goal):
            NavigationLink { FinancePlanDetailView(goal: goal) } label: {
                planTile(title: goal.title, amount: goal.target, current: goal.saved.decimalValue,
                         target: goal.target.decimalValue, coverJSON: goal.coverJSON, shared: FinancePlanCollaboration.decode(goal.collaborationJSON)?.isShared == true, kind: "goals.title")
            }
        }
    }

    private func planTile(title: String, amount: FinanceMoney, current: Decimal, target: Decimal,
                          coverJSON: String, shared: Bool, kind: LocalizedStringKey) -> some View {
        let progress = target > 0 ? NSDecimalNumber(decimal: current / target).doubleValue : 0
        return FIPlanCoverTile(title: title, amount: amount.abbreviated, progress: progress,
                               cover: FinancePlanCover.decode(coverJSON), shared: shared)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(Text(kind)): \(title)"))
            .accessibilityHint(shared ? Text("plan.shared") : Text(""))
            .accessibilityValue(Text(current.formatted() + " / " + amount.formatted))
    }

    private func remainingText(_ amount: Decimal, code: String) -> String {
        String(
            format: NSLocalizedString("plans.remaining", comment: "How much is left of a budget or goal"),
            FinanceMoney(decimal: max(0, amount), currencyCode: code).formatted
        )
    }

    private var placeholderHeight: CGFloat { 200 }

    /// What stands in for the accounts card when there is no card to draw.
    ///
    /// Not `FIEmptyState`, which is built to be laid over a scroll view with
    /// `.overlay` and sizes itself to whatever it covers. Used as a sibling in
    /// this stack — which is what it was — its `maxHeight: .infinity` measures
    /// the viewport *plus* the rows already above it, so the text lands below
    /// the fold and a reader with no accounts sees an empty screen and no
    /// explanation. A stated height puts it directly under the header, where
    /// the card would have been.
    private func accountsNotice(
        title: Text,
        detail: Text,
        @ViewBuilder action: () -> some View
    ) -> some View {
        VStack(spacing: 8) {
            title
                .font(.system(.title3, design: .default).weight(.bold))
                .foregroundStyle(.secondary)

            detail
                .font(FITheme.Typography.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            action()
        }
        .frame(maxWidth: .infinity)
        .frame(height: placeholderHeight)
        .padding(.horizontal, FITheme.Metrics.cardInset)
    }

    private func openCard(_ account: FinanceAccount) {
        guard accountActivity == nil, let frame = cardFrames[account.id] else { return }
        selectedCardIndex = store.accounts.firstIndex { $0.id == account.id } ?? 0
        slotY = frame.minY
        openedY = contentTopY + 8
        cardProgress = 0
        cardDrag = 0
        detailCardVisible = false
        transactionsReady = false
        draggingCard = false
        detailCardY = nil
        flightPosition.y = frame.minY
        openingInterrupted = false
        dragStartTranslation = 0
        closingCard = false
        accountActivity = account
        // The overlay starts its animation on appear, after the source position
        // has been rendered. Both endpoints stay fixed until the flight ends.
    }

    private func closeCard() {
        guard accountActivity != nil, !closingCard else { return }
        if !draggingCard { openedY = detailCardY ?? openedY }
        closingCard = true
        // All cards start together. Foreground cards are drawn above the flying
        // card in the overlay, so correct stacking does not require waiting.
        withAnimation(foregroundReturn, completionCriteria: .logicallyComplete) {
            showList = false
            cardsAway = false
            cardProgress = 0
            cardDrag = 0
        } completion: {
            var handoff = Transaction()
            handoff.disablesAnimations = true
            withTransaction(handoff) {
                accountActivity = nil
                closingCard = false
            }
        }
    }

    /// The full-screen layer that carries the one live card between the stack
    /// and the detail.
    @ViewBuilder
    private var walletCardLayer: some View {
        if let account = accountActivity {
            let live = store.accounts.first(where: { $0.id == account.id }) ?? account
            GeometryReader { geo in
                let width = geo.size.width - 2 * FITheme.Metrics.screenInset
                let y = slotY + (detailY - slotY) * cardProgress + cardDrag - geo.frame(in: .global).minY
                FIAccountCard(account: live, shared: store.isShared(live), showsBalance: true)
                    .frame(width: width, height: FIHomeStyle.cardHeight)
                    .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: -3)
                    .modifier(WalletCardPosition(
                        x: geo.size.width / 2,
                        y: y + FIHomeStyle.cardHeight / 2,
                        onPosition: { centerY in
                            if !draggingCard && !closingCard {
                                flightPosition.y = centerY + geo.frame(in: .global).minY - FIHomeStyle.cardHeight / 2
                            }
                        }
                    ))
                    .animation(closingCard ? selectedReturn : walletSpring, value: cardProgress)
                    .opacity(detailCardVisible && !draggingCard && !closingCard ? 0 : 1)
                    .allowsHitTesting(!detailCardVisible)
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard !closingCard else { return }
                                if !draggingCard {
                                    // Freeze the rendered position, not the animation's
                                    // destination, before handing movement to the finger.
                                    var freeze = Transaction()
                                    freeze.disablesAnimations = true
                                    withTransaction(freeze) {
                                        openingInterrupted = true
                                        draggingCard = true
                                        openedY = flightPosition.y ?? slotY
                                        cardProgress = 1
                                        dragStartTranslation = value.translation.height
                                        cardDrag = 0
                                    }
                                }
                                cardDrag = value.translation.height - dragStartTranslation
                            }
                            .onEnded { value in
                                if value.translation.height > 90 || value.predictedEndTranslation.height > 180 {
                                    closeCard()
                                } else {
                                    withAnimation(walletSpring) {
                                        openedY = contentTopY + 8
                                        cardDrag = 0
                                    } completion: {
                                        guard !closingCard else { return }
                                        draggingCard = false
                                        detailCardVisible = true
                                    }
                                }
                            }
                    )
                // Later cards cover the selected card in both directions, just
                // as they do in the stack. Their original slots stay hidden.
                ForEach(Array(store.accounts.enumerated()), id: \.element.id) { index, foreground in
                    if index > selectedCardIndex, let frame = cardFrames[foreground.id] {
                        FIAccountCard(account: foreground, shared: store.isShared(foreground))
                            .frame(width: width, height: FIHomeStyle.cardHeight)
                            .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: -3)
                            .position(
                                x: geo.size.width / 2,
                                y: frame.minY - geo.frame(in: .global).minY
                                    + FIHomeStyle.cardHeight / 2 + (cardsAway ? 1100 : 0)
                            )
                            .animation(closingCard ? foregroundReturn : openingStack, value: cardsAway)
                            .allowsHitTesting(false)
                    }
                }
            }
            .ignoresSafeArea()
            .transition(.identity)
            .allowsHitTesting(!closingCard)
            .onAppear {
                withAnimation(openingStack) { cardsAway = true }
                withAnimation(walletSpring, completionCriteria: .logicallyComplete) {
                    showList = true
                    cardProgress = 1
                } completion: {
                    guard accountActivity?.id == account.id, !closingCard else { return }
                    transactionsReady = true
                    if !openingInterrupted { detailCardVisible = true }
                }
            }
        }
    }

    private func accountRow(_ account: FinanceAccount) -> some View {
        WalletCardInteraction(open: { openCard(account) }) {
            // Always drawn with the balance so the card the wallet lifts into
            // the detail is the exact same view — no content crossfade mid
            // animation. Covered cards only show their name row anyway.
            FIAccountCard(
                account: account,
                shared: store.isShared(account),
                showsBalance: true
            )
            .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: -3)
        }
        .id(account.id)
    }

    /// The mark at the trailing edge of an account row.
    ///
    /// The icon the user picked, if they picked one. Otherwise the currency's
    /// own SF Symbol — and where the currency has none, its sign as text rather
    /// than a generic banknote glyph, which looked the same for every exotic
    /// currency and so said nothing about any of them.
    @ViewBuilder
    private func accountGlyph(_ account: FinanceAccount) -> some View {
        let code = account.balance.currencyCode.isEmpty ? store.mainCurrencyCode : account.balance.currencyCode

        if !account.symbolName.isEmpty {
            Image(systemName: account.symbolName)
        } else if let logo = FinanceCurrencies.logo(for: code) {
            Image(systemName: logo)
        } else {
            Text(verbatim: FinanceCurrencies.symbol(for: code))
                .font(FITheme.Typography.rowValue)
                .lineLimit(1)
        }
    }

    /// The month's figures: what is held, what it came to, and the two rows
    /// that produced it.
    ///
    /// No header — the chip above already says which period and which currency.
    /// The balance is converted into that currency; spend and income are not,
    /// because each is already a total in one currency and converting them
    /// would hide which.
    private var activitySection: some View {
        VStack(alignment: .leading, spacing: FITheme.Metrics.headerSpacing) {
            FICard {
                FIListRow(title: Text("money.total_balance")) {
                    Text(verbatim: totalBalanceText)
                        .font(FITheme.Typography.rowValue)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                FIRowSeparator()

                FIListRow(title: Text("money.net")) {
                    Text(verbatim: netText)
                        .font(FITheme.Typography.rowValue)
                        .foregroundStyle(netColor)
                        .lineLimit(1)
                }

                FIRowSeparator()

                Button { activityKind = .expenses } label: {
                    FIListRow(
                        title: Text("money.spended"),
                        accessory: .valueChevron(Text(verbatim: selectedTotals.spent.formatted))
                    )
                }
                .buttonStyle(.plain)

                FIRowSeparator()

                Button { activityKind = .incoming } label: {
                    FIListRow(
                        title: Text("money.earned"),
                        accessory: .valueChevron(Text(verbatim: selectedTotals.earned.formatted))
                    )
                }
                .buttonStyle(.plain)
            }

            if let note = conversionNote {
                FIFootnote(verbatim: note)
            }
        }
    }

    private var selectedTotals: FinanceCurrencyTotal {
        store.totals(for: store.effectiveDisplayCurrency)
    }

    /// Every account, converted into the currency on screen.
    ///
    /// Accounts the rates cannot reach are left out rather than added in at face
    /// value — a rouble counted as a dollar is a wrong total, and the footnote
    /// below says which ones were skipped.
    private var convertedBalance: (amount: Decimal, skipped: [String]) {
        let target = store.effectiveDisplayCurrency
        var total: Decimal = 0
        var skipped: Set<String> = []

        for account in store.accounts {
            let code = account.balance.currencyCode.isEmpty ? target : account.balance.currencyCode
            if let converted = rates.convert(account.balance.decimalValue, from: code, to: target) {
                total += converted
            } else {
                skipped.insert(code)
            }
        }
        return (total, skipped.sorted())
    }

    private var totalBalanceText: String {
        let result = convertedBalance
        let money = FinanceMoney(decimal: result.amount, currencyCode: store.effectiveDisplayCurrency)
        // "≈" only when something was actually converted: a single-currency
        // total is exact, and hedging an exact number teaches the reader to
        // ignore the mark where it matters.
        let target = store.effectiveDisplayCurrency
        let converted = store.accounts.contains { !$0.balance.currencyCode.isEmpty && $0.balance.currencyCode != target }
        return converted ? "≈ " + money.formatted : money.formatted
    }

    /// Earned minus spent for the period, in the currency on screen.
    private var netText: String {
        let net = selectedTotals.earned.decimalValue - selectedTotals.spent.decimalValue
        let money = FinanceMoney(decimal: abs(net), currencyCode: store.effectiveDisplayCurrency)
        return (net < 0 ? "−" : "+") + money.formatted
    }

    private var netColor: Color {
        let net = selectedTotals.earned.decimalValue - selectedTotals.spent.decimalValue
        if net > 0 { return FITheme.Palette.positive }
        if net < 0 { return FITheme.Palette.destructive }
        return .secondary
    }

    /// Says how old the rates are, and names anything that could not be
    /// converted — a total quietly missing an account is worse than a total
    /// that explains itself.
    private var conversionNote: String? {
        let target = store.effectiveDisplayCurrency
        let needsRates = store.accounts.contains {
            !$0.balance.currencyCode.isEmpty && $0.balance.currencyCode != target
        }
        guard needsRates else { return nil }

        // Checked first: with no rates at all, *every* foreign currency lands in
        // `skipped`, so listing them would report a dozen missing currencies
        // when the real answer is that nothing has been fetched yet.
        guard rates.isReady else {
            return NSLocalizedString("money.rates.unavailable", comment: "No rates at all")
        }

        // Named, not just counted: knowing it is the yen account that is missing
        // tells the reader how far off the total is.
        let skipped = convertedBalance.skipped
        if !skipped.isEmpty {
            return String(
                format: NSLocalizedString("money.rates.missing", comment: "Currencies left out of the total"),
                skipped.joined(separator: ", ")
            )
        }
        // Yesterday's rates are still worth using — they are far closer than no
        // total at all — but the reader is told which day they are from rather
        // than left to assume the figure is current.
        guard rates.isStale, let published = rates.publishedOn else { return nil }
        return String(
            format: NSLocalizedString("money.rates.stale", comment: "Rates are from an earlier day"),
            published.formatted(.dateTime.day().month(.abbreviated).year())
        )
    }

    private var addMenu: some View {
        Menu {
            Button { sheet = .account(nil) } label: { Label("money.accounts.add", systemImage: "creditcard") }
            Button { sheet = .budget(nil) } label: { Label("budget.add", systemImage: "chart.pie") }
            Button { sheet = .goal(nil) } label: { Label("goals.add", systemImage: "target") }
            Divider()
            Button { sheet = .transaction(.income) } label: { Label("money.add.incoming", systemImage: "plus") }
            Button { sheet = .transaction(.expense) } label: { Label("money.add.expense", systemImage: "minus") }
            Button { sheet = .transaction(.transfer) } label: { Label("money.add.transfer", systemImage: "arrow.left.arrow.right") }
                .disabled(store.accounts.count < 2)
        } label: {
            Image(systemName: "plus")
        }
        .tint(.primary)
        .accessibilityLabel(Text("common.add"))
    }
}

/// What the Money screen can put in front of you.
///
/// One type for all of them so a single `sheet(item:)` drives the presentation.
/// The id distinguishes cases as well as accounts, so going straight from
/// editing an account to correcting it rebuilds the sheet.
enum MoneySheet: Identifiable {
    case transaction(TransactionEditorKind)
    case account(FinanceAccount?)
    case correction(FinanceAccount)
    case budget(FinanceBudget?)
    case goal(FinanceGoal?)

    var id: String {
        switch self {
        case .transaction(let kind): "transaction.\(kind.id)"
        case .account(let account): "account.\(account?.id ?? "new")"
        case .correction(let account): "correction.\(account.id)"
        case .budget(let budget): "budget.\(budget?.id ?? "new")"
        case .goal(let goal): "goal.\(goal?.id ?? "new")"
        }
    }
}

enum ActivityKind: String, Identifiable, Hashable {
    case expenses
    case incoming

    var id: String { rawValue }
    var titleKey: LocalizedStringKey {
        self == .expenses ? "activity.expenses.title" : "activity.incoming.title"
    }
}

private enum ActivitySort: String, CaseIterable, Identifiable {
    case dateDescending, dateAscending, valueDescending, valueAscending

    var id: String { rawValue }
    var titleKey: LocalizedStringKey {
        switch self {
        case .dateDescending: "activity.sort.date_desc"
        case .dateAscending: "activity.sort.date_asc"
        case .valueDescending: "activity.sort.value_desc"
        case .valueAscending: "activity.sort.value_asc"
        }
    }
}

private enum ActivityAccountFilter: String, CaseIterable, Identifiable {
    case all, cash, banks

    var id: String { rawValue }
    var titleKey: LocalizedStringKey {
        switch self {
        case .all: "activity.filter.all"
        case .cash: "activity.filter.cash"
        case .banks: "activity.filter.banks"
        }
    }

    /// Drawn as icons in the menu's palette row, so each option needs a glyph
    /// that reads at a glance without its label.
    var symbol: String {
        switch self {
        case .all: "chart.pie"
        case .cash: "wallet.bifold"
        case .banks: "building.columns"
        }
    }
}

struct AccountActivityView: View {
    @EnvironmentObject private var categories: FinanceCategoryStore
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: FinanceStore
    private let kind: ActivityKind?
    private let account: FinanceAccount?

    @State private var editingAccount = false
    @State private var correctingAccount = false
    @State private var deletingAccount: FinanceAccount?
    @State private var cascadeAccount: FinanceAccount?
    @State private var sort: ActivitySort = .dateDescending
    @State private var accountFilter: ActivityAccountFilter = .all
    /// Seeded from the Money screen's currency picker on appear, so tapping a
    /// total opens the transactions that add up to it rather than all of them.
    @State private var currencyFilter = ""
    @State private var editingTransaction: FinanceTransaction?
    @State private var pendingTransactionDeletion: FinanceTransaction?
    /// A new transaction being added from this account's own list.
    @State private var addKind: TransactionEditorKind?
    /// Days the reader has folded away. Keyed by start-of-day.
    @State private var collapsedDays: Set<Date> = []
    /// The wallet's expanded state: this renders only the list and its
    /// controls; `MoneyView` owns and animates the card itself.
    private var isOverlay = false
    private var onClose: (() -> Void)?
    private var cardVisible = true
    private var transactionsHidden = false
    private var onCardFrame: ((CGFloat) -> Void)?
    private var onCardDrag: ((CGFloat) -> Void)?
    private var onCardEnd: ((CGFloat, CGFloat) -> Void)?

    init(kind: ActivityKind) {
        self.kind = kind
        self.account = nil
    }

    init(account: FinanceAccount, overlay: Bool = false,
         cardVisible: Bool = true, transactionsHidden: Bool = false,
         onCardFrame: ((CGFloat) -> Void)? = nil,
         onCardDrag: ((CGFloat) -> Void)? = nil,
         onCardEnd: ((CGFloat, CGFloat) -> Void)? = nil,
         onClose: (() -> Void)? = nil) {
        self.kind = nil
        self.account = account
        self.isOverlay = overlay
        self.onClose = onClose
        self.cardVisible = cardVisible
        self.transactionsHidden = transactionsHidden
        self.onCardFrame = onCardFrame
        self.onCardDrag = onCardDrag
        self.onCardEnd = onCardEnd
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    private var liveAccount: FinanceAccount? {
        guard let account else { return nil }
        return store.accounts.first { $0.id == account.id } ?? account
    }

    private var transactions: [FinanceTransaction] {
        let scoped = store.transactions.filter { transaction in
            if let account {
                return transaction.fromAccountID == account.id || transaction.toAccountID == account.id
            }
            switch kind {
            case .expenses: return transaction.kind == .expense
            case .incoming: return transaction.kind == .income
            case nil: return true
            }
        }
        let filtered = scoped.filter { transaction in
            guard account == nil else { return true }
            if !currencyFilter.isEmpty && transaction.amount.currencyCode != currencyFilter { return false }
            guard accountFilter != .all else { return true }
            guard let transactionAccount = account(for: transaction) else { return false }
            return accountFilter == .cash ? isCash(transactionAccount) : !isCash(transactionAccount)
        }
        return filtered.sorted(by: sortPredicate)
    }

    /// One day of transactions, for the collapsible sections. Empty when the
    /// list is sorted by value — grouping by day only makes sense in date
    /// order.
    private struct DayGroup: Identifiable {
        let day: Date
        let items: [FinanceTransaction]
        var id: Date { day }
    }

    private var dayGroups: [DayGroup] {
        // Grouping by day only makes sense in date order.
        guard sort == .dateDescending || sort == .dateAscending else { return [] }
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: transactions) {
            calendar.startOfDay(for: $0.occurredAt.date)
        }
        let ascending = sort == .dateAscending
        return grouped.keys
            .sorted { ascending ? $0 < $1 : $0 > $1 }
            .map { DayGroup(day: $0, items: grouped[$0] ?? []) }
    }

    var body: some View {
        Group {
            if isOverlay { overlayBody } else { pageBody }
        }
        .onAppear {
            // Only when that currency actually has transactions here: seeding a
            // code the picker has no option for would leave nothing selected
            // and an empty list with no visible reason.
            if currencyFilter.isEmpty, account == nil,
               availableCurrencies.contains(store.effectiveDisplayCurrency) {
                currencyFilter = store.effectiveDisplayCurrency
            }
        }
        .sheet(isPresented: $editingAccount) { AccountEditorView(account: liveAccount) }
        .sheet(isPresented: $correctingAccount) { if let account { BalanceCorrectionView(account: account) } }
        .fiConfirmDelete($deletingAccount) { account in
            Task {
                switch await store.deleteAccount(account) {
                case .deleted: close()
                case .hasTransactions: cascadeAccount = account
                case .failed: break
                }
            }
        }
        .alert(Text("money.account.delete.has_transactions.title"), isPresented: Binding(
            get: { cascadeAccount != nil }, set: { if !$0 { cascadeAccount = nil } }
        )) {
            Button("money.account.delete.force", role: .destructive) {
                if let account = cascadeAccount {
                    Task { if await store.deleteAccount(account, cascade: true) == .deleted { close() } }
                }
            }
            Button("common.cancel", role: .cancel) {}
        } message: { Text("money.account.delete.has_transactions.message") }
        .fiErrorAlert($store.errorMessage)
        .sheet(item: $editingTransaction) { TransactionEditorView(transaction: $0) }
        .sheet(item: $addKind) { kind in
            TransactionEditorView(kind: kind, accountID: account?.id ?? "")
        }
        .fiConfirmDelete($pendingTransactionDeletion) { transaction in
            Task { await store.deleteTransaction(transaction) }
        }
    }

    // MARK: - Pushed page (combined lists, and account fallback)

    private var pageBody: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: FITheme.Metrics.sectionSpacing) {
                if let initial = account, let live = store.accounts.first(where: { $0.id == initial.id }) {
                    FIAccountCard(account: live, shared: store.isShared(live), add: { addKind = .expense })
                }
                listBody
            }
            .fiCardInsets()
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .fiPageBackground()
        .overlay {
            if transactions.isEmpty && account == nil {
                FIEmptyState(title: "activity.empty", subtitle: "activity.empty.subtitle")
            }
        }
        .navigationTitle(account.map { Text(verbatim: $0.name) } ?? Text(kind?.titleKey ?? "activity.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let account { accountMenu(account) }
                if account == nil {
                    sortMenu
                    filterMenu
                }
            }
        }
    }

    // MARK: - Wallet detail — card and transactions share native scrolling.
    // MoneyView carries the card only during opening and interactive dismissal.

    private var overlayBody: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: FITheme.Metrics.sectionSpacing) {
                if let liveAccount {
                    FIAccountCard(account: liveAccount, shared: store.isShared(liveAccount))
                        .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: -3)
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { onCardFrame?($0) }
                        .opacity(cardVisible ? 1 : 0)
                        .simultaneousGesture(DragGesture(minimumDistance: 6)
                            .onChanged { value in
                                if value.translation.height > abs(value.translation.width) {
                                    onCardDrag?(value.translation.height)
                                }
                            }
                            .onEnded { onCardEnd?($0.translation.height, $0.predictedEndTranslation.height) })
                }
                listBody
                    .allowsHitTesting(!transactionsHidden)
            }
            .fiCardInsets()
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .scrollDisabled(transactionsHidden)
        .overlay {
            if transactions.isEmpty {
                // Centred in the empty space under the card.
                VStack(spacing: 0) {
                    Color.clear.frame(height: FIHomeStyle.cardHeight + 8)
                    ContentUnavailableView {
                        Label("activity.empty", systemImage: "list.bullet.rectangle")
                    } description: {
                        Text("activity.empty.subtitle")
                    }
                    .frame(maxHeight: .infinity)
                }
                .allowsHitTesting(false)
                .modifier(TransactionReveal(visible: !transactionsHidden, index: 0))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if transactions.isEmpty && !transactionsHidden {
                // A hand-drawn arrow curling toward the "+" in the toolbar.
                FIWalletHintArrow()
                    .frame(width: 124, height: 150)
                    .padding(.trailing, 38)
                    .padding(.bottom, 2)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { close() } label: { Image(systemName: "xmark") }
                    .tint(.primary)
                    .accessibilityLabel(Text("common.close"))
            }
            if let account {
                ToolbarItem(placement: .topBarTrailing) {
                    accountMenu(account)
                }
                ToolbarItem(placement: .bottomBar) { Spacer() }
                ToolbarItem(placement: .bottomBar) {
                    Menu {
                        Button { addKind = .income } label: {
                            Label("money.add.incoming", systemImage: "plus")
                        }
                        Button { addKind = .expense } label: {
                            Label("money.add.expense", systemImage: "minus")
                        }
                        Button { addKind = .transfer } label: {
                            Label("money.add.transfer", systemImage: "arrow.left.arrow.right")
                        }
                        .disabled(store.accounts.count < 2)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .tint(.primary)
                    .accessibilityLabel(Text("common.add"))
                }
            }
        }
    }

    @ViewBuilder
    private func accountMenu(_ account: FinanceAccount) -> some View {
        Menu {
            Button { editingAccount = true } label: { Label("common.edit", systemImage: "pencil") }
            Button { correctingAccount = true } label: { Label("money.account.correct", systemImage: "plusminus") }
            if store.isOwner(of: account) {
                shareControl(for: account)
                if store.hasShareInvite(account) {
                    Button { Task { await store.makeAccountPrivate(account) } } label: { Label("money.account.make_private", systemImage: "lock") }
                }
            } else {
                Button { Task { await store.stopSharingAccount(account, memberID: store.currentUserID) } } label: { Label("money.account.leave", systemImage: "person.badge.minus") }
            }
            Divider()
            Button("common.delete", role: .destructive) { deletingAccount = account }
        } label: {
            Image(systemName: "ellipsis")
        }
        .tint(.primary)
    }

    /// The toolbar's share control.
    ///
    /// A native `ShareLink` lives in the toolbar itself. Its transferable loads
    /// the invite only after the system menu is already on screen.
    private func shareControl(for account: FinanceAccount) -> some View {
        AccountShareLinkButton(
            accountID: account.id,
            accountName: account.name,
            existingShare: store.cachedShare(for: account),
            accessibilityLabel: store.hasShareInvite(account)
                ? "money.account.share.again"
                : "money.account.share"
        )
    }

    @ViewBuilder
    private var listBody: some View {
        if dayGroups.isEmpty {
            if !transactions.isEmpty {
                FICard {
                    ForEach(Array(transactions.enumerated()), id: \.element.id) { index, transaction in
                        if index > 0 { FIRowSeparator() }
                        row(transaction)
                    }
                }
                .modifier(TransactionReveal(visible: !isOverlay || !transactionsHidden, index: 0))
            }
        } else {
            ForEach(Array(dayGroups.enumerated()), id: \.element.id) { index, group in
                daySection(group)
                    .modifier(TransactionReveal(visible: !isOverlay || !transactionsHidden, index: index))
            }
        }
    }

    @ViewBuilder
    private func daySection(_ group: DayGroup) -> some View {
        let collapsed = collapsedDays.contains(group.day)
        VStack(alignment: .leading, spacing: FITheme.Metrics.headerSpacing) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    if collapsed { collapsedDays.remove(group.day) } else { collapsedDays.insert(group.day) }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(collapsed ? -90 : 0))
                    Text(verbatim: dayLabel(group.day))
                        .font(FITheme.Typography.sectionHeader)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    Text(verbatim: "\(group.items.count)")
                        .font(FITheme.Typography.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.horizontal, FITheme.Metrics.textInset)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: dayLabel(group.day)))
            .accessibilityHint(Text(collapsed
                ? LocalizedStringKey("activity.group.expand")
                : LocalizedStringKey("activity.group.collapse")))

            if !collapsed {
                FICard {
                    ForEach(Array(group.items.enumerated()), id: \.element.id) { index, transaction in
                        if index > 0 { FIRowSeparator() }
                        row(transaction)
                    }
                }
            }
        }
    }

    private func dayLabel(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return NSLocalizedString("activity.today", comment: "Today") }
        if calendar.isDateInYesterday(day) { return NSLocalizedString("activity.yesterday", comment: "Yesterday") }
        let sameYear = calendar.isDate(day, equalTo: Date(), toGranularity: .year)
        return sameYear
            ? day.formatted(.dateTime.weekday(.abbreviated).day().month(.wide))
            : day.formatted(.dateTime.day().month(.wide).year())
    }

    /// Account scope and currency, both as named rows.
    ///
    /// The palette style drew the mock-up's icon row, but it renders glyphs
    /// only — the captions under them in the design do not exist in a real
    /// menu, leaving three unlabelled shapes to guess at. An inline picker
    /// shows icon, name and checkmark together, which is what the sort menu
    /// beside it already does. Currency stays a submenu because the list is as
    /// long as the user has currencies.
    private var filterMenu: some View {
        FIToolbarMenu(systemImage: "line.3.horizontal.decrease", accessibilityLabel: "activity.filter") {
            Picker(selection: $accountFilter) {
                ForEach(ActivityAccountFilter.allCases) { option in
                    Label(option.titleKey, systemImage: option.symbol).tag(option)
                }
            } label: {
                Text("activity.filter.account")
            }
            .pickerStyle(.inline)

            Menu {
                Picker(selection: $currencyFilter) {
                    Text("activity.filter.all").tag("")
                    ForEach(availableCurrencies, id: \.self) { code in
                        Text(verbatim: code).tag(code)
                    }
                } label: {
                    Text("activity.filter.currency")
                }
                .pickerStyle(.inline)
            } label: {
                Label("activity.filter.currency", systemImage: "coloncurrencysign.circle")
            }
        }
    }

    private var sortMenu: some View {
        FIToolbarMenu(systemImage: "arrow.up.arrow.down", accessibilityLabel: "activity.sort") {
            Picker(selection: $sort) {
                ForEach(ActivitySort.allCases) { option in
                    Text(option.titleKey).tag(option)
                }
            } label: {
                Text("activity.sort")
            }
            .pickerStyle(.inline)
        }
    }

    private func row(_ transaction: FinanceTransaction) -> some View {
        Button { editingTransaction = transaction } label: {
            FIListRow(
                title: Text(verbatim: title(for: transaction)),
                subtitle: Text(verbatim: subtitle(for: transaction)),
                icon: transaction.kind == .transfer ? "arrow.left.arrow.right" : categories.symbol(
                    for: transaction.category, kind: transaction.kind == .income ? .income : .expense
                ),
                iconColor: FITheme.Palette.accent
            ) {
                HStack(spacing: 10) {
                    Text(verbatim: amountText(for: transaction))
                        .foregroundStyle(amountColor(for: transaction))
                        // The amount is the one thing that must stay on one
                        // line: "−5 000,00 RUB" wrapping mid-figure is unreadable
                        // and drags the row's height around. The title above it
                        // is what gives way instead.
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    FIChevron()
                }
            }
        }
        .buttonStyle(.plain)
        .id(transaction.id)
        .fiRowContextMenu {
            Button { editingTransaction = transaction } label: {
                Label("common.edit", systemImage: "pencil")
            }
            FIDestructiveMenuButton(titleKey: "transaction.delete") {
                pendingTransactionDeletion = transaction
            }
        }
    }

    /// Which way the money moved, seen from the account being viewed.
    ///
    /// A transfer is an expense to one account and income to the other, so the
    /// direction cannot come from `kind` alone — it depends on which side of
    /// the transfer this screen is standing on. `nil` on the combined Expenses
    /// and Incoming lists, where every row already moves the same way and a
    /// column of identical signs would be noise.
    private enum Direction { case outgoing, incoming }

    private func direction(for transaction: FinanceTransaction) -> Direction? {
        guard let account else { return nil }
        switch transaction.kind {
        case .expense: return .outgoing
        case .income: return .incoming
        case .transfer: return transaction.toAccountID == account.id ? .incoming : .outgoing
        default: return nil
        }
    }

    /// What the row shows on the right.
    ///
    /// A transfer between currencies carries two amounts. Looking at the
    /// receiving account, the money that left the other one is the wrong
    /// number — and in the wrong currency — so the destination amount is shown
    /// instead.
    private func amountText(for transaction: FinanceTransaction) -> String {
        var money = transaction.amount
        if let account,
           transaction.kind == .transfer,
           transaction.toAccountID == account.id,
           transaction.hasDestinationAmount,
           transaction.destinationAmount.minorUnits > 0 {
            money = transaction.destinationAmount
        }

        switch direction(for: transaction) {
        // A true minus sign rather than a hyphen: it lines up with the digits
        // and is what a currency formatter would print.
        case .outgoing: return "−" + money.formatted
        case .incoming: return "+" + money.formatted
        case nil: return money.formatted
        }
    }

    private func amountColor(for transaction: FinanceTransaction) -> Color {
        switch direction(for: transaction) {
        case .outgoing: FITheme.Palette.destructive
        case .incoming: FITheme.Palette.positive
        case nil: .primary
        }
    }

    /// The row's name.
    ///
    /// Transfers created before they stopped borrowing a spend category were
    /// *saved* with that category as their title — the old editor wrote
    /// `title: categoryLabel`. So a stored title is only trusted on a transfer
    /// when it differs from the category; otherwise it is that old default and
    /// the row is named after the other account, which is what a transfer
    /// actually is.
    private func title(for transaction: FinanceTransaction) -> String {
        let stored = transaction.title
        let isLegacyDefault = transaction.kind == .transfer
            && !transaction.category.isEmpty
            && stored == transaction.category

        if !stored.isEmpty, !isLegacyDefault { return stored }

        guard transaction.kind == .transfer else {
            // A row written by an older build can have neither, and a blank
            // title reads as a rendering fault rather than as missing data.
            return transaction.category.isEmpty
                ? NSLocalizedString("transaction.untitled", comment: "No title or category")
                : FinanceCategoryStore.displayName(for: transaction.category)
        }
        let incoming = direction(for: transaction) == .incoming
        let otherID = incoming ? transaction.fromAccountID : transaction.toAccountID
        guard let other = store.accounts.first(where: { $0.id == otherID }) else {
            return NSLocalizedString("transaction.transfer", comment: "Transfer")
        }
        // Money arriving is named after where it came from, with no preamble:
        // the row already carries a "+", a green amount and the word "Transfer"
        // in its subtitle, so "Incoming from Cash" was the fourth thing on one
        // line saying the same thing. Outgoing keeps its preposition, which is
        // what distinguishes "to Sber" from a plain account name.
        guard !incoming else { return other.name }
        return String(
            format: NSLocalizedString("transaction.transfer_to_format", comment: "Transfer destination"),
            other.name
        )
    }

    /// Date, counterparty account, and the word "Transfer" when it is one.
    ///
    /// The transfer marker lives on this line rather than beside the amount:
    /// squeezed in next to the figure it pushed "−5 000,00 RUB" onto two lines,
    /// and an icon sitting between a date and a number reads as decoration. In
    /// the subtitle it is a word, in the reader's language, next to the other
    /// facts about the row.
    private func subtitle(for transaction: FinanceTransaction) -> String {
        if account != nil, transaction.kind != .transfer {
            // The day is the group header now, so the row just names the
            // category.
            return FinanceCategoryStore.displayName(for: transaction.category)
        }
        let day = transaction.hasOccurredAt ? transaction.occurredAt.date.formatted(.dateTime.day().month(.abbreviated)) : ""
        let accountName = account == nil ? account(for: transaction)?.name ?? "" : ""
        let marker = transaction.kind == .transfer
            ? NSLocalizedString("transaction.transfer", comment: "Transfer")
            : ""
        return [day, accountName, marker].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func account(for transaction: FinanceTransaction) -> FinanceAccount? {
        let id = transaction.kind == .income ? transaction.toAccountID : transaction.fromAccountID
        return store.accounts.first { $0.id == id }
    }

    private func isCash(_ account: FinanceAccount) -> Bool {
        let value = (account.name + " " + account.symbolName).lowercased()
        return value.contains("cash") || value.contains("налич") || value.contains("wallet") || value.contains("banknote")
    }

    private var availableCurrencies: [String] {
        Array(Set(store.transactions.map(\.amount.currencyCode).filter { !$0.isEmpty })).sorted()
    }

    private func sortPredicate(_ lhs: FinanceTransaction, _ rhs: FinanceTransaction) -> Bool {
        switch sort {
        case .dateDescending: return lhs.occurredAt.date > rhs.occurredAt.date
        case .dateAscending: return lhs.occurredAt.date < rhs.occurredAt.date
        case .valueDescending: return lhs.amount.minorUnits > rhs.amount.minorUnits
        case .valueAscending: return lhs.amount.minorUnits < rhs.amount.minorUnits
        }
    }
}

/// Non-observable presentation cache: storing a sample does not redraw views.
private final class WalletFlightPosition {
    var y: CGFloat?
}

/// Reports the interpolated flight position rather than GeometryReader's target
/// layout. A touch can take over the animation without snapping to its endpoint.
private struct WalletCardPosition: AnimatableModifier {
    var x: CGFloat
    var y: CGFloat
    let onPosition: (CGFloat) -> Void

    var animatableData: CGFloat {
        get { y }
        set { y = newValue }
    }

    func body(content: Content) -> some View {
        content.position(x: x, y: y)
            .onChange(of: y, initial: true) { _, value in onPosition(value) }
    }
}

/// Reveal day groups in reading order; interruption hides them immediately.
/// A casual, hand-drawn arrow that curls once and points down toward the "+"
/// in the toolbar — shown on an account with no transactions yet.
struct FIWalletHintArrow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draw: CGFloat = 0

    var body: some View {
        ArrowShape()
            .trim(from: 0, to: draw)
            .stroke(style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
            .foregroundStyle(.secondary)
            .onAppear {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.55)) { draw = 1 }
            }
            .accessibilityHidden(true)
    }

    private struct ArrowShape: Shape {
        func path(in r: CGRect) -> Path {
            // Draw inside a square so the loop stays round.
            let s = min(r.width, r.height)
            let ox = (r.width - s) / 2
            let oy = r.height - s
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: ox + x * s, y: oy + y * s)
            }

            var p = Path()
            // Continuous tangents through the loop and a short, balanced tip.
            p.move(to: pt(0.08, 0.06))
            p.addCurve(to: pt(0.44, 0.45), control1: pt(0.02, 0.29), control2: pt(0.26, 0.49))
            p.addCurve(to: pt(0.59, 0.29), control1: pt(0.55, 0.43), control2: pt(0.62, 0.38))
            p.addCurve(to: pt(0.44, 0.20), control1: pt(0.56, 0.20), control2: pt(0.48, 0.17))
            p.addCurve(to: pt(0.49, 0.48), control1: pt(0.34, 0.27), control2: pt(0.37, 0.38))
            let tip = pt(0.88, 0.98)
            p.addCurve(to: tip, control1: pt(0.73, 0.68), control2: pt(0.88, 0.80))
            p.move(to: pt(0.81, 0.86))
            p.addLine(to: tip)
            p.addLine(to: pt(0.95, 0.86))
            return p
        }
    }
}

private struct TransactionReveal: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let visible: Bool
    let index: Int

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible || reduceMotion ? 0 : 8)
            .animation(
                visible ? .easeOut(duration: 0.30).delay(reduceMotion ? 0 : Double(min(index, 5)) * 0.045) : nil,
                value: visible
            )
            .accessibilityHidden(!visible)
    }
}

/// Touch observation leaves gesture recognition to the enclosing scroll view.
private struct WalletCardInteraction<Content: View>: View {
    let open: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var lifted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content()
            .contentShape(Rectangle())
            .offset(y: lifted ? -12 : 0)
            .animation(reduceMotion ? nil : .smooth(duration: 0.36), value: lifted)
            .overlay {
                WalletCardTouchSurface(onTap: open, onHold: { lifted = $0 })
                    .accessibilityHidden(true)
            }
            .onDisappear { lifted = false }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { open() }
    }
}

private struct WalletCardTouchSurface: UIViewRepresentable {
    let onTap: () -> Void
    let onHold: (Bool) -> Void

    func makeUIView(context: Context) -> WalletCardTouchView { WalletCardTouchView() }

    func updateUIView(_ view: WalletCardTouchView, context: Context) {
        view.onTap = onTap
        view.onHold = onHold
    }

    static func dismantleUIView(_ view: WalletCardTouchView, coordinator: ()) {
        view.cancelPress()
    }
}

/// Observe ordinary touches, without installing a recognizer that competes
/// with UIScrollView. Its pan cancels these touches as scrolling begins.
private final class WalletCardTouchView: UIView {
    var onTap: () -> Void = {}
    var onHold: (Bool) -> Void = { _ in }
    private var holdTask: Task<Void, Never>?
    private var origin: CGPoint?
    private var held = false
    private var moved = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        guard let touch = touches.first else { return }
        cancelPress()
        origin = touch.location(in: window)
        held = false
        moved = false
        holdTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) }
            catch { return }
            guard let self, !Task.isCancelled, self.origin != nil, !self.moved else { return }
            self.held = true
            self.onHold(true)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        guard let origin, let touch = touches.first else { return }
        let point = touch.location(in: window)
        if abs(point.x - origin.x) > 12 || abs(point.y - origin.y) > 12 {
            moved = true
            holdTask?.cancel()
            onHold(false)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        let tapped = origin != nil && !held && !moved
        cancelPress()
        if tapped { onTap() }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        cancelPress()
    }

    func cancelPress() {
        holdTask?.cancel()
        holdTask = nil
        origin = nil
        if held { onHold(false) }
        held = false
    }
}

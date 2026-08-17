import AppIntents
import Foundation

/// A budget as something the widget editor can offer in a list.
///
/// The tile used to show whichever budget was most spent, which is a sensible
/// default and a poor rule: the budget somebody wants on their Home Screen is
/// the one they are trying to keep to, not whichever is currently worst. This
/// makes it a choice, with that rule as the fallback.
struct BudgetWidgetEntity: AppEntity {
    let id: String
    let title: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "widget.budget.entity")
    }

    static var defaultQuery = BudgetWidgetEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }
}

/// Reads the choices out of the shared snapshot.
///
/// The extension has no session and cannot ask the backend what budgets exist,
/// so the list it offers is the list the app last wrote — which is also the
/// only list it could draw from anyway.
struct BudgetWidgetEntityQuery: EntityQuery {
    func entities(for identifiers: [BudgetWidgetEntity.ID]) async throws -> [BudgetWidgetEntity] {
        all().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [BudgetWidgetEntity] {
        all()
    }

    /// The most-spent budget, which is what the tile showed before there was
    /// anything to choose.
    func defaultResult() async -> BudgetWidgetEntity? {
        all().first
    }

    private func all() -> [BudgetWidgetEntity] {
        (FinanceWidgetStore.load()?.budgets ?? []).map {
            BudgetWidgetEntity(id: $0.id, title: $0.title)
        }
    }
}

struct BudgetWidgetConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "widget.budget.title"
    static let description = IntentDescription("widget.budget.description")

    @Parameter(title: "widget.budget.entity")
    var budget: BudgetWidgetEntity?

    init() {}

    init(budget: BudgetWidgetEntity?) {
        self.budget = budget
    }
}

import SwiftUI
import WidgetKit

@main
struct FinanciumWidgetsBundle: WidgetBundle {
    var body: some Widget {
        FinanciumQuickAddWidget()
        FinanciumSummaryWidget()
        FinanciumBudgetWidget()
    }
}

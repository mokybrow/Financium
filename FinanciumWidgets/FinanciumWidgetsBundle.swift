import SwiftUI
import WidgetKit

@main
struct FinanciumWidgetsBundle: WidgetBundle {
    var body: some Widget {
        FinanciumQuickAddWidget()
        FinanciumSummaryWidget()
        FinanciumBudgetWidget()
        FinanciumMonthlyWidget(metric: .difference)
        FinanciumMonthlyWidget(metric: .income)
        FinanciumMonthlyWidget(metric: .expense)
    }
}

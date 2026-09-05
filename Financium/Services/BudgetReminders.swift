import Foundation
import UserNotifications

/// Reminders for money that is about to go out.
///
/// Entirely on the device: a budget with a payment date and a recurrence is
/// already everything a reminder needs, so there is nothing for a server to
/// push. That also means reminders work the same with an account and without
/// one.
///
/// Occurrences are scheduled as explicit dates rather than as one repeating
/// trigger. A repeating calendar trigger is a fixed day of the month, and that
/// cannot say "the 31st" (February has no such day, so the notification is
/// skipped) nor "the day before the 1st", which is the 28th, 29th, 30th or 31st
/// depending on the month. Dates computed by the calendar have neither problem;
/// the cost is that the list has to be topped up, which happens whenever the app
/// loads.
@MainActor
final class BudgetReminders {
    /// iOS keeps at most 64 pending notifications per app and silently drops
    /// the rest, so the horizon is bounded and the nearest dates win.
    private nonisolated static let maxPending = 60
    /// How far ahead to schedule. A year of monthly payments fits comfortably.
    private nonisolated static let occurrencesPerBudget = 12
    /// Reminders arrive the day before, mid-morning — early enough to move money
    /// before the payment, late enough not to be a 9am alarm.
    private nonisolated static let leadDays = 1
    private nonisolated static let hour = 10
    private nonisolated static let minute = 0

    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    /// Asks for permission, returning whether reminders can be delivered.
    ///
    /// Asked when a reminder is first switched on rather than at launch: a
    /// permission prompt makes sense next to the thing that needs it.
    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    /// Replaces every scheduled reminder with what the current budgets imply.
    ///
    /// Wholesale rather than incremental: budgets are few, working out which
    /// single notification a given edit invalidated is more code than redoing
    /// the lot, and a stale reminder for a deleted budget is a bug the user
    /// notices.
    func reschedule(budgets: [FinanceBudget], enabled: Bool) async {
        center.removeAllPendingNotificationRequests()
        guard enabled else { return }

        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }

        let planned = Self.occurrences(for: budgets)
            .sorted { $0.fireAt < $1.fireAt }
            .prefix(Self.maxPending)

        for occurrence in planned {
            let content = UNMutableNotificationContent()
            content.title = occurrence.title
            content.body = occurrence.body
            content.sound = .default

            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: occurrence.fireAt
            )
            let request = UNNotificationRequest(
                identifier: occurrence.id,
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            )
            try? await center.add(request)
        }
    }

    // MARK: - Planning

    nonisolated struct Occurrence {
        let id: String
        let title: String
        let body: String
        let fireAt: Date
    }

    /// Every reminder the budgets imply, from now to the horizon.
    ///
    /// Separated from scheduling so the dates can be reasoned about — and
    /// tested — without a notification centre.
    nonisolated static func occurrences(
        for budgets: [FinanceBudget],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [Occurrence] {
        budgets.flatMap { budget -> [Occurrence] in
            guard budget.reminderEnabled,
                  let payment = date(fromKey: budget.paymentDate, calendar: calendar) else { return [] }

            return paymentDates(from: payment, recurrence: budget.recurrence, calendar: calendar)
                .compactMap { due -> Occurrence? in
                    guard let fireAt = reminderDate(before: due, calendar: calendar), fireAt > now else { return nil }
                    let name = budget.title.isEmpty
                        ? FinanceCategoryStore.displayName(for: budget.category)
                        : budget.title
                    return Occurrence(
                        // Dated, so re-scheduling the same budget replaces the
                        // same notification instead of stacking duplicates.
                        id: "budget.\(budget.id).\(Self.key(for: due, calendar: calendar))",
                        title: name,
                        body: String(
                            format: NSLocalizedString("reminder.body", comment: "Payment due tomorrow"),
                            budget.limit.formatted
                        ),
                        fireAt: fireAt
                    )
                }
        }
    }

    /// The payment dates a recurrence produces, starting at the first one that
    /// has not already passed.
    private nonisolated static func paymentDates(
        from first: Date,
        recurrence: FinanceBudgetRecurrence,
        calendar: Calendar
    ) -> [Date] {
        guard let step = stride(for: recurrence) else { return [first] }

        return (0..<occurrencesPerBudget).compactMap { index in
            calendar.date(byAdding: step.unit, value: step.amount * index, to: first)
        }
    }

    private nonisolated static func stride(
        for recurrence: FinanceBudgetRecurrence
    ) -> (unit: Calendar.Component, amount: Int)? {
        switch recurrence {
        case .weekly: (.weekOfYear, 1)
        case .monthly: (.month, 1)
        case .quarterly: (.month, 3)
        case .yearly: (.year, 1)
        // "Once" has exactly one payment, so there is nothing to step by.
        default: nil
        }
    }

    /// The day before the payment, at a fixed hour.
    private nonisolated static func reminderDate(before due: Date, calendar: Calendar) -> Date? {
        guard let day = calendar.date(byAdding: .day, value: -leadDays, to: calendar.startOfDay(for: due)) else {
            return nil
        }
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
    }

    private nonisolated static func key(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private nonisolated static func date(fromKey value: String, calendar: Calendar) -> Date? {
        guard value.count == 10 else { return nil }
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

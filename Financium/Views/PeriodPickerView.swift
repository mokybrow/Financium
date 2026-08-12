import SwiftUI

/// The window the app is looking at.
///
/// A month is not just a special case of a range: budgets are stored per month
/// on the backend and there is no such thing as a budget for "3–17 April". The
/// two cases are kept apart so the Budget tab can ask which month it is in and
/// get an honest answer.
nonisolated enum FinancePeriod: Equatable {
    case month(Date)
    case range(start: Date, end: Date)

    static var currentMonth: Self {
        .month(Calendar.current.startOfMonth(for: Date()))
    }

    /// Half-open `[start, end)`, which is what both the backend and
    /// `DateInterval` mean by a period.
    var interval: DateInterval {
        switch self {
        case .month(let month):
            let calendar = Calendar.current
            let start = calendar.startOfMonth(for: month)
            let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start
            return DateInterval(start: start, end: end)

        case .range(let start, let end):
            let calendar = Calendar.current
            let from = calendar.startOfDay(for: start)
            // Through the end of the chosen day: a user picking 3–17 means the
            // whole of the 17th, not up to midnight that morning.
            let to = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)) ?? from
            return DateInterval(start: from, end: max(to, from))
        }
    }

    /// The month a budget for this period belongs to — the one it starts in.
    var anchorMonth: Date {
        Calendar.current.startOfMonth(for: interval.start)
    }

    /// The window to send to the server, or `nil` to let it derive one.
    ///
    /// A month is deliberately *not* sent. The client's month runs on the
    /// device's timezone while the server reads budget spend from a UTC month,
    /// so sending local boundaries put a three-hour sliver of transactions on
    /// one screen and not the other. Letting the server derive the month from
    /// the same string budgets use keeps the two screens telling one story. A
    /// range has no server-side equivalent, so it travels as picked.
    var explicitRange: DateInterval? {
        switch self {
        case .month: nil
        case .range: interval
        }
    }

    /// "Apr 2025", or "3 Apr – 17 Apr".
    var label: String {
        switch self {
        case .month(let month):
            return month.formatted(.dateTime.month(.abbreviated).year())
        case .range:
            let interval = interval
            let last = Calendar.current.date(byAdding: .day, value: -1, to: interval.end) ?? interval.start
            // The year is spelled out only when the range crosses one, so
            // "10 Dec – 3 Jan" cannot be read as the same winter.
            let calendar = Calendar.current
            let sameYear = calendar.component(.year, from: interval.start)
                == calendar.component(.year, from: last)
            let format = sameYear
                ? Date.FormatStyle.dateTime.day().month(.abbreviated)
                : Date.FormatStyle.dateTime.day().month(.abbreviated).year()

            if calendar.isDate(interval.start, inSameDayAs: last) {
                return interval.start.formatted(format)
            }
            return "\(interval.start.formatted(format)) – \(last.formatted(format))"
        }
    }
}

// Used from `FinancePeriod` and `FinanceLedger`, both of which run off the main
// actor.
nonisolated extension Calendar {
    func startOfMonth(for date: Date) -> Date {
        self.date(from: dateComponents([.year, .month], from: date)) ?? date
    }
}

// MARK: - Picker

/// The period chooser behind the month chip.
///
/// Two wheels and nothing else. The unit being chosen is a month, and a calendar
/// grid of days invites picking one — it shows thirty things that are not the
/// answer. The wheels are also the whole sheet: a card behind them, a footnote
/// and a list of presets were all explaining a control that explains itself.
struct PeriodPickerView: View {
    @Environment(\.dismiss) private var dismiss

    let period: FinancePeriod
    let onSelect: (FinancePeriod) -> Void

    @State private var year = Calendar.current.component(.year, from: Date())
    @State private var monthNumber = Calendar.current.component(.month, from: Date())

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                Picker(selection: $monthNumber) {
                    ForEach(1...12, id: \.self) { number in
                        Text(verbatim: Self.monthName(number)).tag(number)
                    }
                } label: {
                    Text("period.month")
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)

                Picker(selection: $year) {
                    ForEach(Self.years, id: \.self) { value in
                        // Verbatim so the year is not grouped as "2 025".
                        Text(verbatim: String(value)).tag(value)
                    }
                } label: {
                    Text("period.year")
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .fiPageBackground()
            .fiSheetChrome(
                title: Text("period.title"),
                confirm: .confirm(isEnabled: true) { commit() },
                onClose: { dismiss() }
            )
        }
        // Sized to the wheels: the sheet holds one control, so it should not
        // open at half a screen of empty space below it.
        .presentationDetents([.height(300)])
        .presentationDragIndicator(.visible)
        .onAppear(perform: prefill)
    }

    private static func monthName(_ number: Int) -> String {
        // The app's locale, not the device's: on a phone set to English with
        // the app in Russian the wheel would otherwise disagree with every other
        // month name on screen.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        let symbols = formatter.standaloneMonthSymbols ?? []
        guard symbols.indices.contains(number - 1) else { return String(number) }
        return symbols[number - 1].capitalized
    }

    /// Wide enough to cover a lifetime of records without pretending to be
    /// unbounded: a wheel needs a list, and one that ends is easier to reach the
    /// end of than one that never does.
    private static var years: [Int] {
        let current = Calendar.current.component(.year, from: Date())
        return Array((current - 30)...(current + 5))
    }

    private func prefill() {
        let anchor = period.anchorMonth
        year = Calendar.current.component(.year, from: anchor)
        monthNumber = Calendar.current.component(.month, from: anchor)
    }

    private func commit() {
        let components = DateComponents(year: year, month: monthNumber)
        onSelect(.month(Calendar.current.date(from: components) ?? Date()))
        dismiss()
    }
}

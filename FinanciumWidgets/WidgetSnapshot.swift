import Foundation
import WidgetKit

/// What the app leaves for the widgets to read.
///
/// A widget extension is a separate process with its own container: it cannot
/// call the backend on the app's behalf — it has no session — and it must draw
/// something within a few milliseconds of being asked. So the app writes the
/// few figures the tiles need into the shared group whenever it refreshes, and
/// the widgets only ever read.
///
/// Deliberately small and already resolved. Everything here is a number the
/// tile prints or a fraction it draws; no balances to sum, no budgets to match
/// against transactions. Work done once in the app is work not repeated on
/// every timeline reload, and a widget that computes is a widget that can
/// disagree with the app about the same day.
///
/// The app writes the same JSON from its own side — `FinanceStore` has a
/// matching private encoder. Two declarations rather than one shared file
/// because the widget folder is synchronised into the extension target alone,
/// and the two are held together by the field names, which is also how
/// Eatometer's widget and app agree. If a field is added here it has to be
/// added there; that is the price of not editing target membership by hand.
struct FinanceWidgetSnapshot: Codable, Sendable {
    /// Everything across every account, in the main currency.
    var totalBalanceMinor: Int64
    var spentMinor: Int64
    var earnedMinor: Int64
    var currencyCode: String

    /// The budgets worth putting on a tile, most urgent first.
    var budgets: [Budget]

    var updatedAt: Date

    /// Earned minus spent for the period. Stored rather than derived so the
    /// tile and the app cannot round it differently.
    var differenceMinor: Int64 { earnedMinor - spentMinor }

    struct Budget: Codable, Sendable, Identifiable {
        var id: String
        var title: String
        var spentMinor: Int64
        var limitMinor: Int64
        var currencyCode: String

        /// How much of the limit is used. Uncapped: past 1 the tile says so,
        /// and a budget quietly pinned at 100% is the one thing a budget widget
        /// must never do.
        var progress: Double {
            guard limitMinor > 0 else { return 0 }
            return Double(spentMinor) / Double(limitMinor)
        }

        var percent: Int { Int((progress * 100).rounded()) }
        var isOverspent: Bool { spentMinor > limitMinor }
    }

    static let empty = FinanceWidgetSnapshot(
        totalBalanceMinor: 0,
        spentMinor: 0,
        earnedMinor: 0,
        currencyCode: "RUB",
        budgets: [],
        updatedAt: .distantPast
    )
}

/// The shared container, and the two operations either side of it.
enum FinanceWidgetStore {
    static let appGroupID = "group.com.gofinancium.Financium.shared"
    static let kind = "FinanciumWidgets"
    static let budgetKind = "FinanciumBudgetWidget"
    static let quickAddKind = "FinanciumQuickAddWidget"

    private static let snapshotKey = "Financium.widget.snapshot"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    static func load() -> FinanceWidgetSnapshot? {
        guard let data = defaults?.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(FinanceWidgetSnapshot.self, from: data)
    }

    /// Writes the snapshot and asks the tiles to redraw.
    ///
    /// Only when something changed. `reloadAllTimelines` is a request to the
    /// system, and the system keeps count: an app that asks after every refresh
    /// — four of which can happen on one launch — gets its later requests
    /// ignored, including the one that mattered.
    static func save(_ snapshot: FinanceWidgetSnapshot) {
        guard let defaults, let data = try? JSONEncoder().encode(snapshot) else { return }
        guard defaults.data(forKey: snapshotKey) != data else { return }
        defaults.set(data, forKey: snapshotKey)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Cleared on sign-out, or the next person to open the phone reads the
    /// last one's balances off the Home Screen.
    static func clear() {
        defaults?.removeObject(forKey: snapshotKey)
        WidgetCenter.shared.reloadAllTimelines()
    }
}

/// Minor units as money, in the way the tiles want it.
///
/// Grouped thousands and no decimals: the mock-ups print "376 846", and a tile
/// is too narrow to spend two characters on kopecks nobody reads at a glance.
enum FinanceWidgetFormat {
    static func amount(_ minor: Int64, currencyCode: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.groupingSeparator = "\u{00A0}"
        let value = Double(minor) / 100
        let number = formatter.string(from: NSNumber(value: value)) ?? "\(Int(value))"
        guard let symbol = symbol(for: currencyCode) else { return number }
        return "\(number)\u{00A0}\(symbol)"
    }

    /// Bare number, for the summary tile where the currency is stated once.
    static func plain(_ minor: Int64) -> String {
        amount(minor, currencyCode: "")
    }

    /// The same amount, shortened once it stops fitting.
    ///
    /// "1,5 млн ₽" instead of "1 500 000 ₽". The tiles used to print the whole
    /// figure and let `minimumScaleFactor` deal with the consequences, which
    /// meant a seven-digit sum was rendered at nine points — technically on
    /// screen, and unreadable at arm's length on a Home Screen. Shortening the
    /// text is the fix; shrinking it was the symptom.
    ///
    /// Nothing below ten thousand is touched: "9,4 тыс." takes longer to read
    /// than "9 400" even though it prints shorter, and at that size the exact
    /// figure still fits.
    static func compact(_ minor: Int64, currencyCode: String) -> String {
        let value = Double(minor) / 100
        let magnitude = abs(value)
        guard magnitude >= 10_000 else { return amount(minor, currencyCode: currencyCode) }

        let (scaled, unitKey): (Double, String) = if magnitude >= 1_000_000_000 {
            (magnitude / 1_000_000_000, "unit.billion")
        } else if magnitude >= 1_000_000 {
            (magnitude / 1_000_000, "unit.million")
        } else {
            (magnitude / 1_000, "unit.thousand")
        }

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        // One decimal, and none once the integer part is three digits: "847
        // тыс." says as much as "846,9 тыс." in less room.
        formatter.maximumFractionDigits = scaled >= 100 ? 0 : 1
        let number = formatter.string(from: NSNumber(value: scaled)) ?? "\(Int(scaled))"

        let unit = NSLocalizedString(unitKey, comment: "Abbreviated magnitude")
        let sign = value < 0 ? "−" : ""
        let tail = symbol(for: currencyCode).map { "\u{00A0}" + $0 } ?? ""
        return sign + number + "\u{00A0}" + unit + tail
    }

    /// Signed and shortened, for the difference on the summary tile.
    static func compactSigned(_ minor: Int64) -> String {
        let text = compact(abs(minor), currencyCode: "")
        if minor > 0 { return "+\(text)" }
        if minor < 0 { return "−\(text)" }
        return text
    }

    /// Signed, for a difference that means something opposite either way.
    static func signed(_ minor: Int64) -> String {
        let text = plain(abs(minor))
        if minor > 0 { return "+\(text)" }
        if minor < 0 { return "−\(text)" }
        return text
    }

    private static func symbol(for code: String) -> String? {
        switch code.uppercased() {
        case "": return nil
        case "RUB": return "₽"
        case "USD": return "$"
        case "EUR": return "€"
        case "GBP": return "£"
        default: return code.uppercased()
        }
    }
}

import Foundation

@main
struct SnapshotChecks {
    static func main() throws {
        var snapshot = FinanceWidgetSnapshot.empty
        snapshot.earnedMinor = 450_000
        snapshot.spentMinor = 320_000
        snapshot.updatedAt = .now
        assert(!snapshot.isCurrentMonth, "Legacy UI-period snapshots must not appear as current-month data")
        snapshot.monthStart = .now
        assert(snapshot.isCurrentMonth)
        assert(snapshot.differenceMinor == 130_000)
        snapshot.monthStart = Calendar.current.date(byAdding: .month, value: -1, to: .now)
        assert(!snapshot.isCurrentMonth)
        snapshot.earnedMinor = .max
        snapshot.spentMinor = -1
        assert(snapshot.differenceMinor == .max)
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(FinanceWidgetSnapshot.self, from: encoded)
        assert(decoded.monthStart == snapshot.monthStart)
        var old = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        old.removeValue(forKey: "monthStart")
        let legacy = try JSONDecoder().decode(FinanceWidgetSnapshot.self, from: JSONSerialization.data(withJSONObject: old))
        assert(!legacy.isCurrentMonth)
        let budget = FinanceWidgetSnapshot.Budget(id: "test", title: "Budget", spentMinor: 150_000, limitMinor: 100_000, currencyCode: "EUR")
        assert(budget.isOverspent && budget.remainingMinor == 50_000 && budget.percent == 150)
        assert(FinanceWidgetFormat.compactSigned(100, currencyCode: "EUR").hasPrefix("+"))
        _ = FinanceWidgetFormat.compactSigned(.min, currencyCode: "RUB")
        print("PASS: widget month validity, legacy decoding, net, overspend and signed formatting")
    }
}

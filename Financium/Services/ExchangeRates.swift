import Combine
import Foundation

/// Daily exchange rates from the Central Bank of Russia.
///
/// Fetched on the device rather than through `money-service`: without an account
/// there is no service to ask, and a total that only converts when signed in
/// would be a different app in each mode.
///
/// One published set per day, so this is cached and re-read rather than
/// requested per screen. Nothing here is a market rate — the CBR publishes an
/// official daily fixing — which is why every converted figure on screen is
/// marked approximate.
@MainActor
final class ExchangeRates: ObservableObject {
    /// Roubles per one unit of a currency, keyed by ISO code — the direction the
    /// source publishes in. RUB is 1.
    ///
    /// Named for what it holds. It was `perRouble`, which is the reciprocal of
    /// the value and an invitation to "fix" the arithmetic in the wrong
    /// direction.
    @Published private(set) var roublesPerUnit: [String: Decimal] = [:]
    /// The day the published set is for, as the source states it.
    @Published private(set) var publishedOn: Date?
    @Published private(set) var isLoading = false

    private static let endpoint = URL(string: "https://www.cbr-xml-daily.ru/daily_json.js")!
    private static let cacheKey = "finance.exchange_rates"

    private let defaults: UserDefaults
    private let session: URLSession

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session
        restoreCache()
    }

    /// True once there is something to convert with, cached or fresh.
    var isReady: Bool { !roublesPerUnit.isEmpty }

    /// Whether the figures on screen are older than today's publication.
    var isStale: Bool {
        guard let publishedOn else { return true }
        return !Calendar.current.isDateInToday(publishedOn)
    }

    /// Converts between two currencies, or `nil` when either is unknown.
    ///
    /// `nil` rather than a silent pass-through: an amount left unconverted and
    /// added to a total in another currency is a wrong number, and a wrong
    /// number is worse than a missing one.
    func convert(_ amount: Decimal, from source: String, to target: String) -> Decimal? {
        let from = source.uppercased()
        let to = target.uppercased()
        if from == to { return amount }
        guard let fromRate = rate(for: from), let toRate = rate(for: to), toRate != 0 else { return nil }
        // Both legs go through the rouble, which is the base the source publishes.
        return amount * fromRate / toRate
    }

    private func rate(for code: String) -> Decimal? {
        code == "RUB" ? 1 : roublesPerUnit[code]
    }

    /// Refreshes at most once a day; a cached set published today is enough.
    func refresh(force: Bool = false) async {
        guard force || isStale, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let (data, _) = try await session.data(from: Self.endpoint)
            let payload = try JSONDecoder().decode(Payload.self, from: data)

            var rates: [String: Decimal] = [:]
            for (code, entry) in payload.Valute {
                guard entry.Nominal > 0 else { continue }
                // The source quotes "Value roubles for Nominal units", so one
                // unit is Value / Nominal roubles.
                rates[code.uppercased()] = Decimal(entry.Value) / Decimal(entry.Nominal)
            }
            guard !rates.isEmpty else { return }

            roublesPerUnit = rates
            publishedOn = ISO8601DateFormatter().date(from: payload.Date) ?? Date()
            cache(rates: rates, date: publishedOn)
        } catch {
            // Kept quiet on purpose: a failed rate fetch is not something the
            // user did, and the screen already says its totals are approximate
            // and how old they are.
        }
    }

    // MARK: - Cache

    private struct Cached: Codable {
        var rates: [String: Double]
        var publishedOn: Date?
    }

    private struct Payload: Decodable {
        struct Entry: Decodable {
            let Nominal: Int
            let Value: Double
        }
        let Date: String
        let Valute: [String: Entry]
    }

    private func restoreCache() {
        guard let data = defaults.data(forKey: Self.cacheKey),
              let cached = try? JSONDecoder().decode(Cached.self, from: data) else { return }
        roublesPerUnit = cached.rates.mapValues { Decimal($0) }
        publishedOn = cached.publishedOn
    }

    private func cache(rates: [String: Decimal], date: Date?) {
        let payload = Cached(
            rates: rates.mapValues { NSDecimalNumber(decimal: $0).doubleValue },
            publishedOn: date
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: Self.cacheKey)
    }
}

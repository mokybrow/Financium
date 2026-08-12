import Foundation
import SwiftProtobuf

/// The last answer the account backend gave, kept on disk.
///
/// Without it the app opens on an empty screen and stays there for as long as
/// the network takes — which, on a train or a cold morning, is long enough for
/// the reader to conclude their money is gone. Restoring the last known figures
/// means the first frame is already their accounts; the request that follows
/// replaces the lot.
///
/// This is a cache and behaves like one. It is never merged with a fresh
/// response, never written to by the app's own edits, and never consulted by
/// anything that decides — every mutation goes to the backend and the screen is
/// redrawn from what comes back. The worst it can do is show figures that are a
/// few seconds old.
///
/// Only the account mode is cached. Local mode already keeps the ledger in a
/// file of its own, so a second copy would be a copy of the original.
nonisolated struct FinanceCache: Sendable {
    /// Bumped when the stored shape changes, so an old file is ignored rather
    /// than half-decoded.
    private static let version = 1
    private static let fileName = "finance-cache-v\(version).json"

    /// Protobuf messages travel as their own wire format rather than through
    /// Codable: the generated types already serialise, and hand-writing Codable
    /// mirrors of them is a second definition to keep in step.
    private struct Stored: Codable {
        var monthKey: String
        var savedAt: Date
        var overview: Data
        var accounts: [Data]
        var transactions: [Data]
        var budgets: [Data]
        var goals: [Data]
        var settings: Data
    }

    private let url: URL?

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
        url = base?.appendingPathComponent(Self.fileName)
    }

    /// Reads the cache back, or nil when there is nothing usable.
    ///
    /// A snapshot taken for a different month is discarded rather than shown:
    /// the figures would be real but would answer a question nobody asked, and
    /// a total for the wrong month is worse than no total.
    func load(monthKey: String) -> FinanceSnapshot? {
        guard let url,
              let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.monthKey == monthKey else { return nil }

        do {
            var snapshot = FinanceSnapshot()
            snapshot.overview = try Finance_GetOverviewResponse(serializedBytes: stored.overview)
            snapshot.accounts = try stored.accounts.map { try Finance_Account(serializedBytes: $0) }
            snapshot.transactions = try stored.transactions.map { try Finance_Transaction(serializedBytes: $0) }
            snapshot.budgets = try stored.budgets.map { try Finance_Budget(serializedBytes: $0) }
            snapshot.goals = try stored.goals.map { try Finance_Goal(serializedBytes: $0) }
            snapshot.settings = try Finance_FinanceSettings(serializedBytes: stored.settings)
            return snapshot
        } catch {
            // A file that will not decode is a file worth forgetting.
            clear()
            return nil
        }
    }

    func save(_ snapshot: FinanceSnapshot, monthKey: String) {
        guard let url else { return }

        do {
            let stored = Stored(
                monthKey: monthKey,
                savedAt: Date(),
                overview: try snapshot.overview.serializedData(),
                accounts: try snapshot.accounts.map { try $0.serializedData() },
                transactions: try snapshot.transactions.map { try $0.serializedData() },
                budgets: try snapshot.budgets.map { try $0.serializedData() },
                goals: try snapshot.goals.map { try $0.serializedData() },
                settings: try snapshot.settings.serializedData()
            )
            let data = try JSONEncoder().encode(stored)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Protected on write rather than by a separate call afterwards:
            // balances should not be readable while the device is locked, and a
            // window between writing and protecting is a window.
            try data.write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            // A cache that cannot be written is a cache that is not there. The
            // app is correct either way, so there is nothing to report.
        }
    }

    /// Called on sign-out. Leaving the previous account's balances on disk — and
    /// on screen for whoever signs in next — is not a cache, it is a leak.
    func clear() {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

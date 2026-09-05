import Foundation

/// Versioned native JSON. A budget's month stays beside its model so existing
/// CloudKit records and their IDs keep the same contract.
nonisolated struct FinanceArchive: Codable, Equatable {
    var version = 2
    var accounts: [FinanceAccount] = []
    var transactions: [FinanceTransaction] = []
    var budgets: [Budget] = []
    var goals: [FinanceGoal] = []
    var settings = FinanceSettings()

    struct Budget: Codable, Equatable {
        var month: String
        var budget: FinanceBudget
    }

    enum Failure: Error { case unsupportedVersion(Int) }

    static func decode(_ data: Data) throws -> Self {
        struct Header: Decodable { var version: Int? }
        let decoder = JSONDecoder()
        if let version = try decoder.decode(Header.self, from: data).version {
            guard version == 2 else { throw Failure.unsupportedVersion(version) }
            return try decoder.decode(Self.self, from: data)
        }
        let old = try decoder.decode(LegacyArchive.self, from: data)
        var archive = try old.records.decode()
        archive.budgets = try old.budgets.map {
            Budget(month: $0.month, budget: try LegacyFinanceCodec.decode(FinanceBudget.self, from: $0.payload))
        }
        return archive
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Decode every record before touching disk. A corrupt/unsupported file
    /// must never become an empty ledger, or be overwritten by a later save.
    /// Keep the exact old bytes as a one-time backup before atomically migrating.
    static func load(from url: URL) throws -> Self? {
        guard let data = try readIfPresent(url) else { return nil }
        let archive = try decode(data)
        struct Header: Decodable { var version: Int? }
        if try JSONDecoder().decode(Header.self, from: data).version == nil {
            let backup = url.appendingPathExtension("v1.backup")
            if !FileManager.default.fileExists(atPath: backup.path) {
                try FileManager.default.copyItem(at: url, to: backup)
            }
            try archive.encoded().write(to: url, options: .atomic)
        }
        return archive
    }

    static func recoverCache(from url: URL) throws -> Self? {
        guard let data = try readIfPresent(url) else { return nil }
        let cache = try JSONDecoder().decode(LegacyCache.self, from: data)
        var archive = try cache.records.decode()
        archive.budgets = try cache.budgets.map {
            Budget(month: cache.monthKey, budget: try LegacyFinanceCodec.decode(FinanceBudget.self, from: $0))
        }
        return archive
    }

    private static func readIfPresent(_ url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch CocoaError.fileReadNoSuchFile { return nil }
    }

    private struct LegacyRecords: Decodable {
        var accounts: [Data]
        var transactions: [Data]
        var goals: [Data]
        var settings: Data?

        func decode() throws -> FinanceArchive {
            var archive = FinanceArchive()
            archive.accounts = try accounts.map { try LegacyFinanceCodec.decode(FinanceAccount.self, from: $0) }
            archive.transactions = try transactions.map { try LegacyFinanceCodec.decode(FinanceTransaction.self, from: $0) }
            archive.goals = try goals.map { try LegacyFinanceCodec.decode(FinanceGoal.self, from: $0) }
            if let settings { archive.settings = try LegacyFinanceCodec.decode(FinanceSettings.self, from: settings) }
            return archive
        }
    }

    private struct LegacyArchive: Decodable {
        struct Budget: Decodable { var month: String; var payload: Data }
        var records: LegacyRecords
        var budgets: [Budget]

        private enum CodingKeys: String, CodingKey { case budgets }
        init(from decoder: any Decoder) throws {
            records = try LegacyRecords(from: decoder)
            budgets = try decoder.container(keyedBy: CodingKeys.self).decode([Budget].self, forKey: .budgets)
        }
    }

    private struct LegacyCache: Decodable {
        var records: LegacyRecords
        var monthKey: String
        var budgets: [Data]

        private enum CodingKeys: String, CodingKey { case monthKey, budgets }
        init(from decoder: any Decoder) throws {
            records = try LegacyRecords(from: decoder)
            let values = try decoder.container(keyedBy: CodingKeys.self)
            monthKey = try values.decode(String.self, forKey: .monthKey)
            budgets = try values.decode([Data].self, forKey: .budgets)
        }
    }
}

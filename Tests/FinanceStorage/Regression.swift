import Foundation

// Run Scripts/check-finance-storage.sh. These checks compile the production
// Foundation-only models/codec/archive, with no package or CloudKit account.
@main
struct FinanceStorageRegression {
    static func main() throws {
        func check(_ condition: Bool) { precondition(condition) }
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let fixtures = try JSONDecoder().decode([String: [Data]].self, from: data)

        func roundTrip<T: LegacyFinanceRecord & Equatable>(_ type: T.Type) throws {
            for original in fixtures[String(describing: type)]! {
                let model = try LegacyFinanceCodec.decode(type, from: original)
                precondition(LegacyFinanceCodec.encode(model) == original, "Legacy bytes changed: \(type)")
                let json = try JSONEncoder().encode(model)
                let restored = try JSONDecoder().decode(type, from: json)
                precondition(restored == model)
                precondition(LegacyFinanceCodec.encode(restored) == original)
            }
        }

        try roundTrip(FinanceMoney.self)
        try roundTrip(FinanceAccount.self)
        try roundTrip(FinanceTransaction.self)
        try roundTrip(FinanceBudget.self)
        try roundTrip(FinanceGoal.self)
        try roundTrip(FinanceSettings.self)

        let intervals: [Double] = [0, -0.25, -1, 0.123456789, 123456789.1234, -978307200.25, 999999999.99]
        for (index, interval) in intervals.enumerated() {
            let date = Date(timeIntervalSinceReferenceDate: interval)
            let stamp = FinanceTimestamp(date: date)
            precondition(LegacyFinanceCodec.encode(stamp) == fixtures["FinanceTimestampFromDate"]![index])
            precondition(abs(stamp.date.timeIntervalSinceReferenceDate - interval) < 0.000_001)
        }

        let minMoney = try LegacyFinanceCodec.decode(FinanceMoney.self, from: fixtures["FinanceMoney"]![4])
        precondition(minMoney.minorUnits == Int64.min)
        let transaction = try LegacyFinanceCodec.decode(FinanceTransaction.self, from: fixtures["FinanceTransaction"]![1])
        precondition(transaction.hasOccurredAt && transaction.hasDestinationAmount)
        precondition(transaction.occurredAt.seconds == -1 && transaction.occurredAt.nanos == 999_999_999)
        let missing = try LegacyFinanceCodec.decode(FinanceTransaction.self, from: Data())
        precondition(!missing.hasOccurredAt && !missing.hasDestinationAmount)
        let explicitEmpty = try LegacyFinanceCodec.decode(FinanceTransaction.self, from: Data([0x52, 0x00]))
        precondition(explicitEmpty.hasOccurredAt && explicitEmpty.occurredAt.seconds == 0)

        // A repeated singular message merges its fields; a repeated scalar is last-wins.
        let repeated = Data([0x22, 0x02, 0x08, 0x01, 0x22, 0x05, 0x12, 0x03, 0x52, 0x55, 0x42])
        let merged = try LegacyFinanceCodec.decode(FinanceAccount.self, from: repeated)
        precondition(merged.balance.minorUnits == 1 && merged.balance.currencyCode == "RUB")
        let scalar = try LegacyFinanceCodec.decode(FinanceMoney.self, from: Data([0x08, 0x01, 0x08, 0x02]))
        precondition(scalar.minorUnits == 2)

        // Unknown fixed-width fields and groups must survive as well as varints/strings.
        for raw: [UInt8] in [
            [0xA5, 0x06, 1, 2, 3, 4],
            [0xA1, 0x06, 1, 2, 3, 4, 5, 6, 7, 8],
            [0xA3, 0x06, 0x08, 0x01, 0xA4, 0x06]
        ] {
            let model = try LegacyFinanceCodec.decode(FinanceMoney.self, from: Data(raw))
            precondition(LegacyFinanceCodec.encode(model) == Data(raw))
        }
        for raw: [UInt8] in [
            [0], [0x08, 0x80], [0x12, 0xFF, 0x7F], [0x12, 0x01, 0xFF],
            [0x0F], [0xA4, 0x06], [0xA3, 0x06, 0xAC, 0x06],
            [0x08] + Array(repeating: 0xFF, count: 10)
        ] {
            do {
                _ = try LegacyFinanceCodec.decode(FinanceMoney.self, from: Data(raw))
                preconditionFailure("Malformed payload accepted")
            } catch LegacyFinanceCodec.Failure.malformedPayload {}
        }

        let old: [String: Any] = [
            "accounts": fixtures["FinanceAccount"]!.map { $0.base64EncodedString() },
            "transactions": fixtures["FinanceTransaction"]!.map { $0.base64EncodedString() },
            "goals": fixtures["FinanceGoal"]!.map { $0.base64EncodedString() },
            "settings": fixtures["FinanceSettings"]![7].base64EncodedString(),
            "budgets": fixtures["FinanceBudget"]!.enumerated().map {
                ["month": $0.offset % 2 == 0 ? "2025-12" : "2026-01", "payload": $0.element.base64EncodedString()]
            }
        ]
        let legacy = try JSONSerialization.data(withJSONObject: old)
        let archive = try FinanceArchive.decode(legacy)
        precondition(archive.accounts.count == 10 && archive.transactions.count == 10 && archive.goals.count == 10)
        precondition(archive.budgets[0].month == "2025-12" && archive.budgets[1].month == "2026-01")
        check(try FinanceArchive.decode(archive.encoded()) == archive)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ledger.json")
        check(try FinanceArchive.load(from: url) == nil)
        try legacy.write(to: url)
        check(try FinanceArchive.load(from: url) == archive)
        check(try Data(contentsOf: url.appendingPathExtension("v1.backup")) == legacy)
        check(try FinanceArchive.load(from: url) == archive)

        var corrupt = old
        corrupt["accounts"] = [Data([0x80]).base64EncodedString()]
        let corruptBytes = try JSONSerialization.data(withJSONObject: corrupt)
        try corruptBytes.write(to: url)
        do {
            _ = try FinanceArchive.load(from: url)
            preconditionFailure("Corrupt migration accepted")
        } catch LegacyFinanceCodec.Failure.malformedPayload {}
        check(try Data(contentsOf: url) == corruptBytes)

        var future = archive
        future.version = 3
        do {
            _ = try FinanceArchive.decode(future.encoded())
            preconditionFailure("Unsupported version accepted")
        } catch FinanceArchive.Failure.unsupportedVersion(3) {}

        var cache = old
        cache["monthKey"] = "2024-02"
        cache["budgets"] = fixtures["FinanceBudget"]!.map { $0.base64EncodedString() }
        let cacheURL = directory.appendingPathComponent("cache.json")
        try JSONSerialization.data(withJSONObject: cache).write(to: cacheURL)
        let recovered = try FinanceArchive.recoverCache(from: cacheURL)!
        precondition(recovered.budgets.count == 10 && recovered.budgets.allSatisfy { $0.month == "2024-02" })

        print("PASS: 67 legacy fixtures, native JSON, exact money/timestamps, field presence, unknown fields/enums, malformed payloads, atomic migration/backup, month preservation and legacy cache recovery")
    }
}

import Foundation

// Only persisted entities need the legacy CloudKit representation. Field
// numbers are the existing on-disk/CloudKit contract; never renumber them.

nonisolated extension FinanceMoney: LegacyFinanceRecord {
    static var legacyFields: [LegacyFinanceField<Self>] {
        [
            .int64(1, \.minorUnits),
            .string(2, \.currencyCode),
        ]
    }
}

nonisolated extension FinanceAccount: LegacyFinanceRecord {
    static var legacyFields: [LegacyFinanceField<Self>] {
        [
            .string(1, \.id),
            .string(2, \.name),
            .string(3, \.symbolName),
            .message(4, \.storedBalance),
            .bool(5, \.isArchived),
            .message(6, \.storedCreatedAt),
            .message(7, \.storedUpdatedAt),
            .string(8, \.ownerUserID),
            .int32(9, \.memberCount),
        ]
    }
}

nonisolated extension FinanceTransaction: LegacyFinanceRecord {
    static var legacyFields: [LegacyFinanceField<Self>] {
        [
            .string(1, \.id),
            .enumeration(2, \.kind),
            .string(3, \.fromAccountID),
            .string(4, \.toAccountID),
            .string(5, \.category),
            .string(6, \.title),
            .message(7, \.storedAmount),
            .message(8, \.storedDestinationAmount),
            .string(9, \.note),
            .message(10, \.storedOccurredAt),
            .message(11, \.storedCreatedAt),
            .message(12, \.storedUpdatedAt),
        ]
    }
}

nonisolated extension FinanceBudget: LegacyFinanceRecord {
    static var legacyFields: [LegacyFinanceField<Self>] {
        [
            .string(1, \.id),
            .string(2, \.category),
            .message(3, \.storedLimit),
            .message(4, \.storedSpent),
            .bool(5, \.reminderEnabled),
            .message(7, \.storedCreatedAt),
            .message(8, \.storedUpdatedAt),
            .string(9, \.title),
            .string(10, \.paymentDate),
            .enumeration(11, \.recurrence),
        ]
    }
}

nonisolated extension FinanceGoal: LegacyFinanceRecord {
    static var legacyFields: [LegacyFinanceField<Self>] {
        [
            .string(1, \.id),
            .string(2, \.title),
            .string(3, \.accountID),
            .string(4, \.category),
            .message(5, \.storedTarget),
            .message(6, \.storedSaved),
            .message(7, \.storedCreatedAt),
            .message(8, \.storedUpdatedAt),
        ]
    }
}

nonisolated extension FinanceSettings: LegacyFinanceRecord {
    static var legacyFields: [LegacyFinanceField<Self>] {
        [
            .string(1, \.mainCurrencyCode),
            .enumeration(2, \.walletPlan),
            .bool(3, \.monthlyRemindersEnabled),
            .bool(4, \.promoEmailEnabled),
            .bool(5, \.promoPushEnabled),
        ]
    }
}

nonisolated extension FinanceTimestamp: LegacyFinanceRecord {
    static var legacyFields: [LegacyFinanceField<Self>] {
        [
            .int64(1, \.seconds),
            .int32(2, \.nanos),
        ]
    }
}

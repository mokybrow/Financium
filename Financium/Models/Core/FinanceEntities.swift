import Foundation

// Native value models shared by UI, the local ledger and CloudKit. Optional
// stored values preserve the distinction between absent and explicitly empty
// legacy fields. Unknown legacy data survives a read/edit/write by older apps.

nonisolated enum FinanceTransactionKind: RawRepresentable, Codable, Hashable, CaseIterable, Sendable {
    case unspecified, expense, income, transfer
    case unrecognized(Int)

    init(rawValue: Int) {
        switch rawValue {
        case 0: self = .unspecified
        case 1: self = .expense
        case 2: self = .income
        case 3: self = .transfer
        default: self = .unrecognized(rawValue)
        }
    }

    var rawValue: Int {
        switch self {
        case .unspecified: 0
        case .expense: 1
        case .income: 2
        case .transfer: 3
        case .unrecognized(let value): value
        }
    }

    static let allCases: [FinanceTransactionKind] = [.unspecified, .expense, .income, .transfer]

    init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(Int.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

nonisolated enum FinanceWalletPlan: RawRepresentable, Codable, Hashable, CaseIterable, Sendable {
    case unspecified, free, premium
    case unrecognized(Int)

    init(rawValue: Int) {
        switch rawValue {
        case 0: self = .unspecified
        case 1: self = .free
        case 2: self = .premium
        default: self = .unrecognized(rawValue)
        }
    }

    var rawValue: Int {
        switch self {
        case .unspecified: 0
        case .free: 1
        case .premium: 2
        case .unrecognized(let value): value
        }
    }

    static let allCases: [FinanceWalletPlan] = [.unspecified, .free, .premium]

    init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(Int.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

nonisolated enum FinanceBudgetRecurrence: RawRepresentable, Codable, Hashable, CaseIterable, Sendable {
    case unspecified, once, weekly, monthly, quarterly, yearly
    case unrecognized(Int)

    init(rawValue: Int) {
        switch rawValue {
        case 0: self = .unspecified
        case 1: self = .once
        case 2: self = .weekly
        case 3: self = .monthly
        case 4: self = .quarterly
        case 5: self = .yearly
        default: self = .unrecognized(rawValue)
        }
    }

    var rawValue: Int {
        switch self {
        case .unspecified: 0
        case .once: 1
        case .weekly: 2
        case .monthly: 3
        case .quarterly: 4
        case .yearly: 5
        case .unrecognized(let value): value
        }
    }

    static let allCases: [FinanceBudgetRecurrence] = [.unspecified, .once, .weekly, .monthly, .quarterly, .yearly]

    init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(Int.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

nonisolated struct FinanceMoney: Codable, Hashable, Sendable {
    var minorUnits: Int64 = 0
    var currencyCode: String = ""
    var legacyUnknownFields = Data()

    init() {}

    private enum CodingKeys: String, CodingKey {
        case minorUnits, currencyCode, legacyUnknownFields
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        minorUnits = try values.decodeIfPresent(Int64.self, forKey: .minorUnits) ?? 0
        currencyCode = try values.decodeIfPresent(String.self, forKey: .currencyCode) ?? ""
        legacyUnknownFields = try values.decodeIfPresent(Data.self, forKey: .legacyUnknownFields) ?? Data()
    }
}

nonisolated struct FinanceAccount: Codable, Hashable, Sendable {
    var id: String = ""
    var name: String = ""
    var symbolName: String = ""
    var storedBalance: FinanceMoney?
    var balance: FinanceMoney {
        get { storedBalance ?? FinanceMoney() }
        set { storedBalance = newValue }
    }
    var hasBalance: Bool { storedBalance != nil }
    var isArchived: Bool = false
    var storedCreatedAt: FinanceTimestamp?
    var createdAt: FinanceTimestamp {
        get { storedCreatedAt ?? FinanceTimestamp() }
        set { storedCreatedAt = newValue }
    }
    var hasCreatedAt: Bool { storedCreatedAt != nil }
    var storedUpdatedAt: FinanceTimestamp?
    var updatedAt: FinanceTimestamp {
        get { storedUpdatedAt ?? FinanceTimestamp() }
        set { storedUpdatedAt = newValue }
    }
    var hasUpdatedAt: Bool { storedUpdatedAt != nil }
    var ownerUserID: String = ""
    var memberCount: Int32 = 0
    var legacyUnknownFields = Data()

    init() {}

    private enum CodingKeys: String, CodingKey {
        case id, name, symbolName, storedBalance, isArchived, storedCreatedAt, storedUpdatedAt, ownerUserID, memberCount, legacyUnknownFields
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        symbolName = try values.decodeIfPresent(String.self, forKey: .symbolName) ?? ""
        storedBalance = try values.decodeIfPresent(FinanceMoney.self, forKey: .storedBalance)
        isArchived = try values.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        storedCreatedAt = try values.decodeIfPresent(FinanceTimestamp.self, forKey: .storedCreatedAt)
        storedUpdatedAt = try values.decodeIfPresent(FinanceTimestamp.self, forKey: .storedUpdatedAt)
        ownerUserID = try values.decodeIfPresent(String.self, forKey: .ownerUserID) ?? ""
        memberCount = try values.decodeIfPresent(Int32.self, forKey: .memberCount) ?? 0
        legacyUnknownFields = try values.decodeIfPresent(Data.self, forKey: .legacyUnknownFields) ?? Data()
    }
}

nonisolated struct FinanceTransaction: Codable, Hashable, Sendable {
    var id: String = ""
    var kind: FinanceTransactionKind = .unspecified
    var fromAccountID: String = ""
    var toAccountID: String = ""
    var category: String = ""
    var title: String = ""
    var storedAmount: FinanceMoney?
    var amount: FinanceMoney {
        get { storedAmount ?? FinanceMoney() }
        set { storedAmount = newValue }
    }
    var hasAmount: Bool { storedAmount != nil }
    var storedDestinationAmount: FinanceMoney?
    var destinationAmount: FinanceMoney {
        get { storedDestinationAmount ?? FinanceMoney() }
        set { storedDestinationAmount = newValue }
    }
    var hasDestinationAmount: Bool { storedDestinationAmount != nil }
    var note: String = ""
    var storedOccurredAt: FinanceTimestamp?
    var occurredAt: FinanceTimestamp {
        get { storedOccurredAt ?? FinanceTimestamp() }
        set { storedOccurredAt = newValue }
    }
    var hasOccurredAt: Bool { storedOccurredAt != nil }
    var storedCreatedAt: FinanceTimestamp?
    var createdAt: FinanceTimestamp {
        get { storedCreatedAt ?? FinanceTimestamp() }
        set { storedCreatedAt = newValue }
    }
    var hasCreatedAt: Bool { storedCreatedAt != nil }
    var storedUpdatedAt: FinanceTimestamp?
    var updatedAt: FinanceTimestamp {
        get { storedUpdatedAt ?? FinanceTimestamp() }
        set { storedUpdatedAt = newValue }
    }
    var hasUpdatedAt: Bool { storedUpdatedAt != nil }
    var legacyUnknownFields = Data()

    init() {}

    private enum CodingKeys: String, CodingKey {
        case id, kind, fromAccountID, toAccountID, category, title, storedAmount, storedDestinationAmount, note, storedOccurredAt, storedCreatedAt, storedUpdatedAt, legacyUnknownFields
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? ""
        kind = try values.decodeIfPresent(FinanceTransactionKind.self, forKey: .kind) ?? .unspecified
        fromAccountID = try values.decodeIfPresent(String.self, forKey: .fromAccountID) ?? ""
        toAccountID = try values.decodeIfPresent(String.self, forKey: .toAccountID) ?? ""
        category = try values.decodeIfPresent(String.self, forKey: .category) ?? ""
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
        storedAmount = try values.decodeIfPresent(FinanceMoney.self, forKey: .storedAmount)
        storedDestinationAmount = try values.decodeIfPresent(FinanceMoney.self, forKey: .storedDestinationAmount)
        note = try values.decodeIfPresent(String.self, forKey: .note) ?? ""
        storedOccurredAt = try values.decodeIfPresent(FinanceTimestamp.self, forKey: .storedOccurredAt)
        storedCreatedAt = try values.decodeIfPresent(FinanceTimestamp.self, forKey: .storedCreatedAt)
        storedUpdatedAt = try values.decodeIfPresent(FinanceTimestamp.self, forKey: .storedUpdatedAt)
        legacyUnknownFields = try values.decodeIfPresent(Data.self, forKey: .legacyUnknownFields) ?? Data()
    }
}

nonisolated struct FinanceBudget: Codable, Hashable, Sendable {
    var id: String = ""
    var category: String = ""
    var storedLimit: FinanceMoney?
    var limit: FinanceMoney {
        get { storedLimit ?? FinanceMoney() }
        set { storedLimit = newValue }
    }
    var hasLimit: Bool { storedLimit != nil }
    var storedSpent: FinanceMoney?
    var spent: FinanceMoney {
        get { storedSpent ?? FinanceMoney() }
        set { storedSpent = newValue }
    }
    var hasSpent: Bool { storedSpent != nil }
    var reminderEnabled: Bool = false
    var storedCreatedAt: FinanceTimestamp?
    var createdAt: FinanceTimestamp {
        get { storedCreatedAt ?? FinanceTimestamp() }
        set { storedCreatedAt = newValue }
    }
    var hasCreatedAt: Bool { storedCreatedAt != nil }
    var storedUpdatedAt: FinanceTimestamp?
    var updatedAt: FinanceTimestamp {
        get { storedUpdatedAt ?? FinanceTimestamp() }
        set { storedUpdatedAt = newValue }
    }
    var hasUpdatedAt: Bool { storedUpdatedAt != nil }
    var title: String = ""
    var paymentDate: String = ""
    var recurrence: FinanceBudgetRecurrence = .unspecified
    var legacyUnknownFields = Data()

    init() {}

    private enum CodingKeys: String, CodingKey {
        case id, category, storedLimit, storedSpent, reminderEnabled, storedCreatedAt, storedUpdatedAt, title, paymentDate, recurrence, legacyUnknownFields
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? ""
        category = try values.decodeIfPresent(String.self, forKey: .category) ?? ""
        storedLimit = try values.decodeIfPresent(FinanceMoney.self, forKey: .storedLimit)
        storedSpent = try values.decodeIfPresent(FinanceMoney.self, forKey: .storedSpent)
        reminderEnabled = try values.decodeIfPresent(Bool.self, forKey: .reminderEnabled) ?? false
        storedCreatedAt = try values.decodeIfPresent(FinanceTimestamp.self, forKey: .storedCreatedAt)
        storedUpdatedAt = try values.decodeIfPresent(FinanceTimestamp.self, forKey: .storedUpdatedAt)
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
        paymentDate = try values.decodeIfPresent(String.self, forKey: .paymentDate) ?? ""
        recurrence = try values.decodeIfPresent(FinanceBudgetRecurrence.self, forKey: .recurrence) ?? .unspecified
        legacyUnknownFields = try values.decodeIfPresent(Data.self, forKey: .legacyUnknownFields) ?? Data()
    }
}

nonisolated struct FinanceGoal: Codable, Hashable, Sendable {
    var id: String = ""
    var title: String = ""
    var accountID: String = ""
    var category: String = ""
    var storedTarget: FinanceMoney?
    var target: FinanceMoney {
        get { storedTarget ?? FinanceMoney() }
        set { storedTarget = newValue }
    }
    var hasTarget: Bool { storedTarget != nil }
    var storedSaved: FinanceMoney?
    var saved: FinanceMoney {
        get { storedSaved ?? FinanceMoney() }
        set { storedSaved = newValue }
    }
    var hasSaved: Bool { storedSaved != nil }
    var storedCreatedAt: FinanceTimestamp?
    var createdAt: FinanceTimestamp {
        get { storedCreatedAt ?? FinanceTimestamp() }
        set { storedCreatedAt = newValue }
    }
    var hasCreatedAt: Bool { storedCreatedAt != nil }
    var storedUpdatedAt: FinanceTimestamp?
    var updatedAt: FinanceTimestamp {
        get { storedUpdatedAt ?? FinanceTimestamp() }
        set { storedUpdatedAt = newValue }
    }
    var hasUpdatedAt: Bool { storedUpdatedAt != nil }
    var legacyUnknownFields = Data()

    init() {}

    private enum CodingKeys: String, CodingKey {
        case id, title, accountID, category, storedTarget, storedSaved, storedCreatedAt, storedUpdatedAt, legacyUnknownFields
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
        accountID = try values.decodeIfPresent(String.self, forKey: .accountID) ?? ""
        category = try values.decodeIfPresent(String.self, forKey: .category) ?? ""
        storedTarget = try values.decodeIfPresent(FinanceMoney.self, forKey: .storedTarget)
        storedSaved = try values.decodeIfPresent(FinanceMoney.self, forKey: .storedSaved)
        storedCreatedAt = try values.decodeIfPresent(FinanceTimestamp.self, forKey: .storedCreatedAt)
        storedUpdatedAt = try values.decodeIfPresent(FinanceTimestamp.self, forKey: .storedUpdatedAt)
        legacyUnknownFields = try values.decodeIfPresent(Data.self, forKey: .legacyUnknownFields) ?? Data()
    }
}

nonisolated struct FinanceSettings: Codable, Hashable, Sendable {
    var mainCurrencyCode: String = ""
    var walletPlan: FinanceWalletPlan = .unspecified
    var monthlyRemindersEnabled: Bool = false
    var promoEmailEnabled: Bool = false
    var promoPushEnabled: Bool = false
    var legacyUnknownFields = Data()

    init() {}

    private enum CodingKeys: String, CodingKey {
        case mainCurrencyCode, walletPlan, monthlyRemindersEnabled, promoEmailEnabled, promoPushEnabled, legacyUnknownFields
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mainCurrencyCode = try values.decodeIfPresent(String.self, forKey: .mainCurrencyCode) ?? ""
        walletPlan = try values.decodeIfPresent(FinanceWalletPlan.self, forKey: .walletPlan) ?? .unspecified
        monthlyRemindersEnabled = try values.decodeIfPresent(Bool.self, forKey: .monthlyRemindersEnabled) ?? false
        promoEmailEnabled = try values.decodeIfPresent(Bool.self, forKey: .promoEmailEnabled) ?? false
        promoPushEnabled = try values.decodeIfPresent(Bool.self, forKey: .promoPushEnabled) ?? false
        legacyUnknownFields = try values.decodeIfPresent(Data.self, forKey: .legacyUnknownFields) ?? Data()
    }
}

nonisolated struct FinanceTimestamp: Codable, Hashable, Sendable {
    var seconds: Int64 = 0
    var nanos: Int32 = 0
    var legacyUnknownFields = Data()

    init() {}

    private enum CodingKeys: String, CodingKey {
        case seconds, nanos, legacyUnknownFields
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        seconds = try values.decodeIfPresent(Int64.self, forKey: .seconds) ?? 0
        nanos = try values.decodeIfPresent(Int32.self, forKey: .nanos) ?? 0
        legacyUnknownFields = try values.decodeIfPresent(Data.self, forKey: .legacyUnknownFields) ?? Data()
    }

    init(date: Date) {
        self.init()
        // Date's native epoch avoids losing fractional precision in an extra
        // floating-point conversion to 1970. Normalize rounded nanoseconds.
        let interval = date.timeIntervalSinceReferenceDate
        let whole = Int64(interval)
        seconds = whole + Int64(Date.timeIntervalBetween1970AndReferenceDate)
        nanos = Int32(((interval - Double(whole)) * 1_000_000_000).rounded())
        if nanos < 0 {
            seconds -= 1
            nanos += 1_000_000_000
        } else if nanos == 1_000_000_000 {
            seconds += 1
            nanos = 0
        }
    }

    var date: Date {
        Date(timeIntervalSinceReferenceDate:
            Double(seconds - Int64(Date.timeIntervalBetween1970AndReferenceDate)) + Double(nanos) / 1_000_000_000
        )
    }
}

nonisolated struct FinanceOverview: Equatable, Sendable {
    var totalBalance = FinanceMoney()
    var spent = FinanceMoney()
    var earned = FinanceMoney()
    var accounts: [FinanceAccount] = []
    var recentTransactions: [FinanceTransaction] = []
    var currencies: [FinanceCurrencyTotal] = []
}

nonisolated struct FinanceCurrencyTotal: Equatable, Sendable {
    var currencyCode = ""
    var balance = FinanceMoney()
    var spent = FinanceMoney()
    var earned = FinanceMoney()
}

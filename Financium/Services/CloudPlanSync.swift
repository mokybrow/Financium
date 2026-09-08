import CloudKit
import Foundation
import os

nonisolated struct FinancePlanShareStatus: Sendable {
    var isOwner: Bool
    var isShared: Bool
    var needsBinding: Bool
}

/// Plan zones share definitions and absolute member totals, never account records.
/// CKSyncEngine owns scheduling/retries; this actor persists the local outbox.
actor CloudPlanSync {
    nonisolated static let schemaZoneName = "FinanciumSchema"
    nonisolated static let unbound = "__shared_plan_unbound__"
    private let local: LocalFinanceBackend
    private let container: CKContainer
    private let url: URL
    private var state: State
    private var loadError: Error?
    private var persisted: Data?
    private var loaded = false
    private var selfID = ""
    private var preparing: [String: Task<CKShare, Error>] = [:]

    nonisolated private struct Definition: Codable, Equatable {
        var key: String
        var title: String
        var category: String
        var amount: FinanceMoney
        var coverJSON: String
        var month: String
        var id: String { String(key.dropFirst(key.hasPrefix("budget:") ? 7 : 5)) }
        var isBudget: Bool { key.hasPrefix("budget:") }
    }
    nonisolated private struct Contribution: Codable, Equatable {
        var participantID: String
        var month: String
        var amount: FinanceMoney
        var revision: Int64
    }
    nonisolated private struct Session: Codable {
        var zone: String
        var zoneOwner: String
        var guest: Bool
        var share: Data?
        var records: [String: Data] = [:]
        var dirty: Set<String> = []
        var closing = false
        var zoneID: CKRecordZone.ID { .init(zoneName: zone, ownerName: zoneOwner) }
    }
    nonisolated private struct State: Codable { var sessions: [String: Session] = [:]; var userID: String? }
    nonisolated struct Pending: Sendable {
        var owned: [CKSyncEngine.PendingRecordZoneChange] = []
        var shared: [CKSyncEngine.PendingRecordZoneChange] = []
    }

    init(local: LocalFinanceBackend, container: CKContainer) {
        self.local = local; self.container = container
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        url = directory.appendingPathComponent("financium-plan-sync.json")
        state = State()
    }
    #if DEBUG
    /// Development learns record types from writes. Use isolated, synthetic
    /// records so creating the schema neither shares nor changes a real plan.
    /// Release/TestFlight builds do not contain this initializer.
    func initializeDevelopmentSchema() async throws {
        let database = container.privateCloudDatabase
        let zoneID = CKRecordZone.ID(zoneName: Self.schemaZoneName)
        let zones = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        guard let result = zones.saveResults[zoneID] else { throw CKError(.internalError) }
        _ = try result.get()

        let amount = FinanceMoney(minorUnits: 0, currencyCode: "RUB")
        let definition = Definition(key: "goal:schema", title: "Schema", category: "", amount: amount, coverJSON: "", month: "")
        let contribution = Contribution(participantID: "schema", month: "", amount: amount, revision: 0)
        var sample = Session(zone: Self.schemaZoneName, zoneOwner: CKCurrentUserDefaultName, guest: false)
        try put(definition, type: "PlanDefinition", name: "schema_definition", session: &sample)
        try put(contribution, type: "PlanContribution", name: "schema_contribution", session: &sample)
        let records = sample.records.values.compactMap { Self.record($0) }
        // Stable IDs + changedKeys make repeated developer launches idempotent.
        let results = try await database.modifyRecords(saving: records, deleting: [], savePolicy: .changedKeys, atomically: true)
        let failures: [Error] = results.saveResults.values.compactMap { result in
            if case .failure(let error) = result { return FinanceLog.rootCause(error) }
            return nil
        }
        if let failure = FinanceLog.primaryError(in: failures) { throw failure }
        for record in records {
            guard let result = results.saveResults[record.recordID] else { throw CKError(.internalError) }
            _ = try result.get()
        }
        FinanceLog.store.info("Shared plan schema initialized. Deploy Schema Changes before testing in TestFlight.")
    }
    #endif

    private func ensureState() throws {
        if let loadError { throw loadError }
        guard !loaded else { return }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let data = try Data(contentsOf: url)
                state = try JSONDecoder().decode(State.self, from: data)
            }
            loaded = true
        } catch { loadError = error; throw error }
    }
    private func persist() throws {
        if let loadError { throw loadError }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        guard data != persisted else { return }
        try data.write(to: url, options: .atomic)
        persisted = data
    }
    private func identify() async throws {
        try ensureState()
        if let loadError { throw loadError }
        if selfID.isEmpty { selfID = try await container.userRecordID().recordName }
        if let previous = state.userID, previous != selfID {
            for key in state.sessions.keys { try await local.clearSharedPlan(key: key, remove: false) }
            state = State()
        }
        state.userID = selfID
        await local.setSelfUserID(selfID)
    }
    nonisolated private static func archive(_ record: CKRecord) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: record, requiringSecureCoding: true)
    }
    nonisolated private static func record(_ data: Data?) -> CKRecord? {
        guard let data else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: data)
    }
    private func definition(_ session: Session) -> Definition? {
        for data in session.records.values {
            guard let record = Self.record(data), record.recordType == "PlanDefinition",
                  let payload = record["payload"] as? Data else { continue }
            guard let value = try? JSONDecoder().decode(Definition.self, from: payload),
                  value.key.hasPrefix("budget:") || value.key.hasPrefix("goal:"), !value.id.isEmpty,
                  record.recordID.recordName == "planmeta_" + value.id else { continue }
            let owner = (Self.record(session.share) as? CKShare)?.owner.userIdentity.userRecordID?.recordName
            let author = record.lastModifiedUserRecordID?.recordName
            if author == owner && owner != nil || (!session.guest && session.dirty.contains(record.recordID.recordName)) { return value }
        }
        return nil
    }
    private func members(_ session: Session) -> Set<String> {
        guard let share = Self.record(session.share) as? CKShare else { return [] }
        var ids = Set(share.participants.filter { $0.acceptanceStatus == .accepted }.compactMap { $0.userIdentity.userRecordID?.recordName })
        if let owner = share.owner.userIdentity.userRecordID?.recordName { ids.insert(owner) }
        return ids
    }
    func shares() -> [String: CKShare] {
        state.sessions.compactMapValues { $0.closing ? nil : Self.record($0.share) as? CKShare }
    }
    func statuses() async throws -> [String: FinancePlanShareStatus] {
        try ensureState()
        let raw = try await local.rawLedger()
        var result: [String: FinancePlanShareStatus] = [:]
        for (key, session) in state.sessions where !session.closing {
            let binding = definition(session).map { def in
                def.isBudget ? raw.budgets.first { $0.budget.id == def.id }?.budget.accountID : raw.goals.first { $0.id == def.id }?.accountID
            } ?? nil
            result[key] = .init(isOwner: !session.guest, isShared: session.guest || members(session).count > 1,
                                needsBinding: session.guest && !raw.accounts.contains { $0.id == binding && !$0.isArchived })
        }
        return result
    }
    private func fromLocal(key: String, raw: RawLedger) -> Definition? {
        if key.hasPrefix("budget:"), let stored = raw.budgets.first(where: { "budget:" + $0.budget.id == key }) {
            let budget = stored.budget
            return Definition(key: key, title: budget.title, category: budget.category, amount: budget.limit, coverJSON: budget.coverJSON, month: stored.month)
        }
        if let goal = raw.goals.first(where: { "goal:" + $0.id == key }) {
            return Definition(key: key, title: goal.title, category: "", amount: goal.target, coverJSON: goal.coverJSON, month: "")
        }
        return nil
    }
    private func put<T: Encodable>(_ value: T, type: String, name: String, session: inout Session) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(value)
        let record = Self.record(session.records[name]) ?? CKRecord(recordType: type, recordID: .init(recordName: name, zoneID: session.zoneID))
        if record["payload"] as? Data == payload { return }
        record["payload"] = payload as CKRecordValue
        record["updatedAt"] = Date() as CKRecordValue
        session.records[name] = try Self.archive(record)
        session.dirty.insert(name)
    }
    private func localAmount(_ def: Definition, raw: RawLedger) -> FinanceMoney? {
        if def.isBudget {
            guard let budget = raw.budgets.first(where: { $0.budget.id == def.id })?.budget,
                  budget.accountID != Self.unbound else { return nil }
            let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM"; formatter.locale = Locale(identifier: "en_US_POSIX")
            guard let month = formatter.date(from: def.month) else { return nil }
            let rows = raw.transactions.filter { budget.accountID.isEmpty || $0.fromAccountID == budget.accountID }
            return FinanceMoney(minorUnits: FinanceLedger.spent(onCategory: budget.category, month: month, currency: def.amount.currencyCode, transactions: rows), currencyCode: def.amount.currencyCode)
        }
        guard let goal = raw.goals.first(where: { $0.id == def.id }), goal.accountID != Self.unbound else { return nil }
        let accounts = raw.accounts.filter { !$0.isArchived && $0.balance.currencyCode == def.amount.currencyCode && (goal.accountID.isEmpty || $0.id == goal.accountID) }
        return FinanceMoney(decimal: max(0, accounts.reduce(Decimal.zero) { $0 + $1.balance.decimalValue }), currencyCode: def.amount.currencyCode)
    }
    func reconcile() async throws -> Pending {
        try ensureState()
        guard !state.sessions.isEmpty else { return Pending() }
        try await identify()
        for key in Array(state.sessions.keys) where state.sessions[key]?.closing == true { try await close(key: key) }
        let raw = try await local.rawLedger()
        var pending = Pending()
        for key in Array(state.sessions.keys) {
            guard var session = state.sessions[key], !session.closing else { continue }
            if !session.guest, let def = fromLocal(key: key, raw: raw) {
                try put(def, type: "PlanDefinition", name: "planmeta_" + def.id, session: &session)
            }
            if let def = definition(session), let amount = localAmount(def, raw: raw) {
                let name = "planvalue_" + def.id + "_" + selfID
                let old = Self.record(session.records[name]).flatMap { record in (record["payload"] as? Data).flatMap { try? JSONDecoder().decode(Contribution.self, from: $0) } }
                if old?.amount != amount || old?.month != def.month {
                    let contribution = Contribution(participantID: selfID, month: def.month, amount: amount, revision: old?.revision == Int64.max ? Int64.max : max(0, old?.revision ?? 0) + 1)
                    try put(contribution, type: "PlanContribution", name: name, session: &session)
                }
            }
            state.sessions[key] = session
            for name in session.dirty {
                let change = CKSyncEngine.PendingRecordZoneChange.saveRecord(.init(recordName: name, zoneID: session.zoneID))
                if session.guest { pending.shared.append(change) } else { pending.owned.append(change) }
            }
        }
        try persist()
        try await materialize()
        return pending
    }
    func record(for id: CKRecord.ID) -> CKRecord? {
        guard let session = state.sessions.values.first(where: { $0.zoneID == id.zoneID && !$0.closing }) else { return nil }
        return Self.record(session.records[id.recordName])
    }
    func prepare(key: String) async throws -> CKShare {
        if let task = preparing[key] { return try await task.value }
        let task = Task {
            do { return try await self.createShare(key: key) }
            catch {
                FinanceLog.store.error("prepare plan share failed: \(FinanceLog.describe(error), privacy: .public)")
                throw FinanceLog.rootCause(error)
            }
        }
        preparing[key] = task
        defer { preparing[key] = nil }
        return try await task.value
    }
    private func createShare(key: String) async throws -> CKShare {
        try await identify()
        if let session = state.sessions[key], let share = Self.record(session.share) as? CKShare, !session.closing { return share }
        let raw = try await local.rawLedger()
        guard let def = fromLocal(key: key, raw: raw) else { throw FinanceLedger.Failure.notFound }
        let zone = "plan_" + def.id + "_" + UUID().uuidString
        var session = Session(zone: zone, zoneOwner: CKCurrentUserDefaultName, guest: false)
        try put(def, type: "PlanDefinition", name: "planmeta_" + def.id, session: &session)
        let database = container.privateCloudDatabase
        let zoneResults = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: session.zoneID)], deleting: [])
        guard let zoneResult = zoneResults.saveResults[session.zoneID] else { throw CKError(.internalError) }
        _ = try zoneResult.get()
        let share = CKShare(recordZoneID: session.zoneID)
        share[CKShare.SystemFieldKey.title] = def.title as CKRecordValue
        share.publicPermission = .none
        let records = session.records.values.compactMap { Self.record($0) } + [share]
        let results = try await database.modifyRecords(saving: records, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
        let failures: [Error] = results.saveResults.values.compactMap { result in
            if case .failure(let error) = result { return FinanceLog.rootCause(error) }
            return nil
        }
        if let error = FinanceLog.primaryError(in: failures) { throw error }
        for record in records {
            guard let result = results.saveResults[record.recordID] else { throw CKError(.internalError) }
            let saved = try result.get()
            if let savedShare = saved as? CKShare { session.share = try Self.archive(savedShare) }
            else { session.records[saved.recordID.recordName] = try Self.archive(saved) }
        }
        session.dirty = []
        state.sessions[key] = session
        try persist()
        _ = try await reconcile()
        guard let saved = Self.record(session.share) as? CKShare else { throw CKError(.internalError) }
        return saved
    }
    func accept(_ metadata: CKShare.Metadata, acceptedShare: CKShare) async throws {
        try await identify()
        // Metadata can still describe an invitation as pending. Persist the
        // accepted server share so materialize can import it on this fetch.
        let zoneID = acceptedShare.recordID.zoneID
        let key = state.sessions.first { $0.value.zoneID == zoneID }?.key ?? "zone:" + zoneID.zoneName
        var session = state.sessions[key] ?? Session(zone: zoneID.zoneName, zoneOwner: zoneID.ownerName, guest: metadata.participantRole != .owner)
        session.share = try Self.archive(acceptedShare)
        // A startup fetch may have delivered the definition before acceptance.
        // Move its temporary zone key now, without waiting for another push.
        let resolvedKey = definition(session)?.key ?? key
        if resolvedKey != key { state.sessions[key] = nil }
        state.sessions[resolvedKey] = session
        try persist()
    }
    func received(_ record: CKRecord, guest: Bool) async throws {
        try await identify()
        let zone = record.recordID.zoneID
        guard zone.zoneName.hasPrefix("plan_") else { return }
        let previousKey = state.sessions.first { $0.value.zoneID == zone }?.key ?? "zone:" + zone.zoneName
        var session = state.sessions[previousKey] ?? Session(zone: zone.zoneName, zoneOwner: zone.ownerName, guest: guest)
        if let share = record as? CKShare { session.share = try Self.archive(share) }
        else {
            // Validate authors against CloudKit metadata, not payload membership claims.
            if record.recordType == "PlanContribution", let data = record["payload"] as? Data,
               let value = try? JSONDecoder().decode(Contribution.self, from: data),
               let creator = record.creatorUserRecordID?.recordName, creator != value.participantID { return }
            if !session.dirty.contains(record.recordID.recordName) {
                session.records[record.recordID.recordName] = try Self.archive(record)
            }
        }
        let key = definition(session)?.key ?? previousKey
        if key != previousKey { state.sessions[previousKey] = nil }
        state.sessions[key] = session
        try persist()
    }
    func materialize() async throws {
        guard !state.sessions.isEmpty else { return }
        try await identify()
        let raw = try await local.rawLedger()
        for (key, session) in state.sessions where !session.closing {
            guard let def = definition(session), let share = Self.record(session.share) as? CKShare,
                  let owner = share.owner.userIdentity.userRecordID?.recordName else { continue }
            let accepted = members(session)
            // A revoked participant must not keep a writable outbox alive.
            if session.guest && !accepted.contains(selfID) { continue }
            var contributions: [FinancePlanCollaboration.Contribution] = []
            for data in session.records.values {
                guard let record = Self.record(data), record.recordType == "PlanContribution", let payload = record["payload"] as? Data,
                      let contribution = try? JSONDecoder().decode(Contribution.self, from: payload),
                      accepted.contains(contribution.participantID) || contribution.participantID == selfID else { continue }
                let createdBy = record.creatorUserRecordID?.recordName
                let modifiedBy = record.lastModifiedUserRecordID?.recordName
                let localPending = contribution.participantID == selfID && session.dirty.contains(record.recordID.recordName)
                guard localPending || (createdBy == contribution.participantID && modifiedBy == contribution.participantID) else { continue }
                contributions.append(.init(participantID: contribution.participantID, monthKey: contribution.month, amount: contribution.amount, revision: contribution.revision))
            }
            contributions.sort { $0.participantID < $1.participantID }
            let collaboration = FinancePlanCollaboration(ownerID: owner, acceptedParticipantIDs: accepted, contributions: contributions, planKey: key, zoneName: session.zone, localParticipantID: selfID)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let json = String(decoding: try encoder.encode(collaboration), as: UTF8.self)
            if def.isBudget {
                var budget = raw.budgets.first { $0.budget.id == def.id }?.budget ?? FinanceBudget()
                let isNew = budget.id.isEmpty
                budget.id = def.id; budget.title = def.title; budget.limit = def.amount; budget.coverJSON = def.coverJSON
                if !session.guest || isNew { budget.category = def.category }
                if isNew && session.guest { budget.accountID = Self.unbound }
                budget.collaborationJSON = json
                try await local.installSharedPlan(budget: budget, month: def.month, goal: nil)
            } else {
                var goal = raw.goals.first { $0.id == def.id } ?? FinanceGoal()
                let isNew = goal.id.isEmpty
                goal.id = def.id; goal.title = def.title; goal.target = def.amount; goal.coverJSON = def.coverJSON
                if isNew && session.guest {
                    goal.accountID = Self.unbound
                    goal.saved = FinanceMoney(minorUnits: 0, currencyCode: def.amount.currencyCode)
                }
                goal.collaborationJSON = json
                try await local.installSharedPlan(budget: nil, month: "", goal: goal)
            }
        }
    }
    func saved(_ record: CKRecord) async throws {
        guard let key = state.sessions.first(where: { $0.value.zoneID == record.recordID.zoneID })?.key,
              var session = state.sessions[key] else { return }
        let name = record.recordID.recordName
        let current = Self.record(session.records[name])
        if current?["payload"] as? Data == record["payload"] as? Data {
            session.records[name] = try Self.archive(record); session.dirty.remove(name)
        } else if let current {
            let rebased = record; rebased["payload"] = current["payload"]; rebased["updatedAt"] = current["updatedAt"]
            session.records[name] = try Self.archive(rebased)
        }
        state.sessions[key] = session; try persist()
    }
    func conflict(_ server: CKRecord) async throws {
        guard let key = state.sessions.first(where: { $0.value.zoneID == server.recordID.zoneID })?.key,
              var session = state.sessions[key] else { return }
        let name = server.recordID.recordName
        let localRecord = Self.record(session.records[name])
        let serverAt = server["updatedAt"] as? Date ?? .distantPast
        let localAt = localRecord?["updatedAt"] as? Date ?? .distantPast
        if session.dirty.contains(name), let localRecord, localAt > serverAt {
            server["payload"] = localRecord["payload"]; server["updatedAt"] = localRecord["updatedAt"]
        } else { session.dirty.remove(name) }
        session.records[name] = try Self.archive(server); state.sessions[key] = session; try persist()
    }
    func missing(_ id: CKRecord.ID) throws {
        guard let key = state.sessions.first(where: { $0.value.zoneID == id.zoneID })?.key,
              var session = state.sessions[key], let old = Self.record(session.records[id.recordName]) else { return }
        let fresh = CKRecord(recordType: old.recordType, recordID: id)
        fresh["payload"] = old["payload"]; fresh["updatedAt"] = old["updatedAt"]
        session.records[id.recordName] = try Self.archive(fresh)
        session.dirty.insert(id.recordName)
        state.sessions[key] = session; try persist()
    }

    func deleted(_ id: CKRecord.ID) async throws {
        guard let key = state.sessions.first(where: { $0.value.zoneID == id.zoneID })?.key else { return }
        if id.recordName.hasPrefix("planmeta_") || id.recordName == CKRecordNameZoneWideShare {
            try await zoneDeleted(id.zoneID); return
        }
        state.sessions[key]?.records[id.recordName] = nil
        state.sessions[key]?.dirty.remove(id.recordName)
        try persist()
    }
    func zoneDeleted(_ zone: CKRecordZone.ID) async throws {
        guard let key = state.sessions.first(where: { $0.value.zoneID == zone })?.key, let session = state.sessions[key] else { return }
        try await local.clearSharedPlan(key: key, remove: session.guest)
        state.sessions[key] = nil; try persist()
    }
    func zone(for key: String) -> CKRecordZone.ID? { state.sessions[key]?.zoneID }
    func close(key: String) async throws {
        guard var session = state.sessions[key] else { return }
        session.closing = true; state.sessions[key] = session; try persist()
        do {
            let database = session.guest ? container.sharedCloudDatabase : container.privateCloudDatabase
            let result = try await database.modifyRecordZones(saving: [], deleting: [session.zoneID])
            if let deletion = result.deleteResults[session.zoneID] { _ = try deletion.get() }
            else { throw CKError(.internalError) }
            try await zoneDeleted(session.zoneID)
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem || error.code == .userDeletedZone {
            try await zoneDeleted(session.zoneID)
        } catch {
            state.sessions[key]?.closing = false; try persist(); throw error
        }
    }
    func reset() async throws {
        try ensureState()
        // Signing out preserves the local ledger while dropping old account credentials and outbox.
        for key in state.sessions.keys { try await local.clearSharedPlan(key: key, remove: false) }
        state = State(); selfID = ""; try persist()
    }
}

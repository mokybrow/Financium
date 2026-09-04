import CloudKit
import CryptoKit
import Foundation
import SwiftProtobuf
import UIKit
import os

/// Keeps the on-device ledger and CloudKit in step.
///
/// The device file (`LocalFinanceBackend`) stays the one source every screen
/// reads. This mirrors it to the user's private CloudKit database and pulls
/// back anything another device — or a shared account — changed. `CKSyncEngine`
/// does the hard parts: the pending-changes queue, server change tokens,
/// retries and scheduling. What is left here is turning the ledger's protobuf
/// messages into records and merging fetched records back in.
///
/// Two engines, one per database: the private one carries this person's own
/// accounts, the shared one carries accounts other people have shared with
/// them. Each account lives in its own record zone, so sharing an account is
/// just adding a `CKShare` to its zone — nothing has to move.
actor CloudKitSyncCoordinator {
    /// The `FinanceBackend` the store writes through in `.icloud` mode.
    nonisolated let backend: CloudKitFinanceBackend

    private let local: LocalFinanceBackend
    private let container: CKContainer
    private let onRemoteChange: @Sendable () async -> Void

    private var privateEngine: CKSyncEngine?
    private var sharedEngine: CKSyncEngine?
    private var started = false

    private var sidecar: SyncSidecar
    private let sidecarURL: URL

    static let ledgerZoneName = "Ledger"

    private let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.gofinancium.Financium",
        category: "cloudkit"
    )

    init(
        local: LocalFinanceBackend,
        container: CKContainer = .default(),
        onRemoteChange: @escaping @Sendable () async -> Void
    ) {
        self.local = local
        self.container = container
        self.onRemoteChange = onRemoteChange
        self.backend = CloudKitFinanceBackend(local: local)

        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.sidecarURL = directory.appendingPathComponent("financium-cloud-sync.json")
        self.sidecar = (try? Data(contentsOf: sidecarURL))
            .flatMap { try? JSONDecoder().decode(SyncSidecar.self, from: $0) }
            ?? SyncSidecar()
    }

    // MARK: - Lifecycle

    /// Builds the engines and queues the local ledger for its first upload.
    /// Safe to call more than once.
    ///
    /// No explicit `fetchChanges` here: `CKSyncEngine` fetches on its own once
    /// it is created and whenever its pending state changes. Calling it by hand
    /// is only needed where the app knows something the engine does not yet — a
    /// silent push, or a share just accepted.
    func start() async {
        guard !started else { return }
        started = true
        await backend.attach(coordinator: self)

        let privateConfig = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: decodeState(sidecar.privateState),
            delegate: self
        )
        let engine = CKSyncEngine(privateConfig)
        privateEngine = engine

        let sharedConfig = CKSyncEngine.Configuration(
            database: container.sharedCloudDatabase,
            stateSerialization: decodeState(sidecar.sharedState),
            delegate: self
        )
        sharedEngine = CKSyncEngine(sharedConfig)

        // The ledger zone holds budgets and settings; per-account zones are
        // created as accounts are reconciled.
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneName: Self.ledgerZoneName))])

        await reconcile()
    }

    /// Accounts this device only *participates* in — shared with it by someone
    /// else and living in the shared database. Everything else (a private
    /// account, one this device shared out, or a stale share inherited from the
    /// old backend) is the local user's to make private again.
    /// The invite link for every account this device has already shared,
    /// keyed by account id — known synchronously, so the UI can offer a real
    /// `ShareLink` instead of minting on tap.
    func inviteURLs() -> [String: URL] {
        sidecar.shareURLs.compactMapValues { URL(string: $0) }
    }

    /// Complete `CKShare` values cached after a save or fetch. A `ShareLink`
    /// can hand these straight to the system without an actor hop or network
    /// request before its menu appears.
    func cachedShares() -> [String: CKShare] {
        sidecar.shareArchives.compactMapValues { data in
            guard let share = Self.decodeShare(data),
                  let thumbnail = share[CKShare.SystemFieldKey.thumbnailImageData] as? Data,
                  thumbnail.starts(with: Self.pngSignature) else { return nil }
            return share
        }
    }

    /// Accounts with a live share — one this device created (a URL is stored)
    /// or one it joined (its zone is in the shared database).
    func sharedAccountIDs() -> Set<String> {
        var ids = Set(sidecar.shareURLs.keys)
        ids.formUnion(participantAccountIDs())
        return ids
    }

    func participantAccountIDs() -> Set<String> {
        var ids: Set<String> = []
        for zoneName in sidecar.sharedZones {
            guard zoneName.hasPrefix("acct_") else { continue }
            ids.insert(String(zoneName.dropFirst("acct_".count)))
        }
        return ids
    }

    /// Makes an account private again: deletes its `CKShare` if this device
    /// owns one, and clears the sharing flags on the local record. For a stale
    /// share from the old backend there is no `CKShare` — just the flags.
    func makePrivate(accountID: String) async {
        let zoneName = Self.accountZoneName(accountID)
        let zoneID = CKRecordZone.ID(zoneName: zoneName)

        // Tear the whole zone down — share, records and all. A zone-wide
        // `CKShare` does not cleanly come back on a zone that has had one; a
        // fresh zone does, and `reconcile()` rebuilds this one from the local
        // ledger.
        _ = try? await container.privateCloudDatabase.modifyRecordZones(saving: [], deleting: [zoneID])

        sidecar.shareURLs[accountID] = nil
        sidecar.shareArchives[accountID] = nil
        sidecar.sharedZones.remove(zoneName)
        // Forget everything that lived in that zone so reconcile re-creates the
        // zone and re-uploads the records instead of thinking they are synced.
        for (name, zone) in sidecar.recordZones where zone == zoneName {
            sidecar.contentHashes[name] = nil
            sidecar.systemFields[name] = nil
            sidecar.recordZones[name] = nil
            sidecar.updatedAt[name] = nil
        }
        await local.setSharing(accountID: accountID, ownerUserID: "", memberCount: 1)
        saveSidecar()
        await reconcile()
        try? await privateEngine?.sendChanges()
        await onRemoteChange()
    }

    /// Deletes every zone this device owns in the private database and forgets
    /// all sync bookkeeping — for "delete account". The local file is cleared
    /// by the caller.
    func deleteAllData() async {
        let defaultZoneID = CKRecordZone.default().zoneID
        let zones = (try? await container.privateCloudDatabase.allRecordZones()) ?? []
        let ids = zones.map(\.zoneID).filter { $0 != defaultZoneID }
        if !ids.isEmpty {
            _ = try? await container.privateCloudDatabase.modifyRecordZones(saving: [], deleting: ids)
        }
        sidecar = SyncSidecar()
        saveSidecar()
    }

    /// Called from the app delegate when a CloudKit push wakes the app.
    func handlePush() async {
        try? await privateEngine?.fetchChanges()
        try? await sharedEngine?.fetchChanges()
    }

    // MARK: - Reconcile (local → pending changes)

    /// Walks the whole ledger and queues every record whose payload changed
    /// since it was last sent, plus deletions for anything gone. Cheap: a few
    /// hundred small hashes.
    func reconcile() async {
        guard let privateEngine else { return }
        let raw = await local.rawLedger()
        let desired = Self.desiredRecords(raw, sidecar: sidecar)

        var privateSaves: [CKSyncEngine.PendingRecordZoneChange] = []
        var sharedSaves: [CKSyncEngine.PendingRecordZoneChange] = []
        var newZones: Set<String> = []
        var seen: Set<String> = []

        for entry in desired {
            seen.insert(entry.recordName)
            let hash = entry.payloadHash
            if sidecar.contentHashes[entry.recordName] == hash { continue }
            sidecar.contentHashes[entry.recordName] = hash
            // A real local edit: stamp the moment, so a later conflict is
            // decided by which side changed last, not by which side synced last.
            sidecar.updatedAt[entry.recordName] = Date()

            let recordID = CKRecord.ID(recordName: entry.recordName, zoneID: entry.zoneID)
            if sidecar.sharedZones.contains(entry.zoneID.zoneName) {
                sharedSaves.append(.saveRecord(recordID))
            } else {
                if entry.zoneID.zoneName != Self.ledgerZoneName { newZones.insert(entry.zoneID.zoneName) }
                privateSaves.append(.saveRecord(recordID))
            }
        }

        var privateDeletes: [CKSyncEngine.PendingRecordZoneChange] = []
        var sharedDeletes: [CKSyncEngine.PendingRecordZoneChange] = []
        for (recordName, _) in sidecar.contentHashes where !seen.contains(recordName) {
            sidecar.contentHashes[recordName] = nil
            guard let zoneName = sidecar.recordZones[recordName] else { continue }
            let recordID = CKRecord.ID(recordName: recordName, zoneID: CKRecordZone.ID(zoneName: zoneName))
            if sidecar.sharedZones.contains(zoneName) {
                sharedDeletes.append(.deleteRecord(recordID))
            } else {
                privateDeletes.append(.deleteRecord(recordID))
            }
        }

        for entry in desired { sidecar.recordZones[entry.recordName] = entry.zoneID.zoneName }
        for name in newZones {
            privateEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneName: name))])
        }
        if !privateSaves.isEmpty || !privateDeletes.isEmpty {
            privateEngine.state.add(pendingRecordZoneChanges: privateSaves + privateDeletes)
        }
        if let sharedEngine, !sharedSaves.isEmpty || !sharedDeletes.isEmpty {
            sharedEngine.state.add(pendingRecordZoneChanges: sharedSaves + sharedDeletes)
        }
        saveSidecar()
    }

    // MARK: - Sharing

    /// The container backing every `CKShare`, for presenting Apple's own
    /// `UICloudSharingController` — a `let`, so reading it needs no hop onto
    /// the actor.
    nonisolated var cloudContainer: CKContainer { container }

    func shareAccount(id: String) async throws -> AccountInvite {
        invite(from: try await ensureShare(forAccountID: id))
    }

    /// The live `CKShare` itself (existing or freshly minted), for the
    /// "Collaborate" screen — participant faces, the public-link toggle, Stop
    /// Sharing — rather than a bare-URL activity sheet.
    func shareRecord(forAccount id: String) async throws -> CKShare {
        try await ensureShare(forAccountID: id)
    }

    /// Clears this device's sharing bookkeeping for an account whose `CKShare`
    /// was removed through `UICloudSharingController`'s own "Stop Sharing"
    /// rather than the app's `makePrivate`. The controller has already deleted
    /// the share; there is nothing left to undo server-side, only our own
    /// idea of who owns what.
    func handleStoppedSharingFromSystemUI(accountID: String) async {
        sidecar.shareURLs[accountID] = nil
        sidecar.shareArchives[accountID] = nil
        saveSidecar()
        await local.setSharing(accountID: accountID, ownerUserID: "", memberCount: 1)
        await reconcile()
        await onRemoteChange()
    }

    private func ensureShare(forAccountID id: String) async throws -> CKShare {
        let database = container.privateCloudDatabase
        let zoneID = CKRecordZone.ID(zoneName: Self.accountZoneName(id))
        let ownerID = (try? await container.userRecordID().recordName) ?? ""

        // The zone may have been torn down by a previous "make private".
        // Recreate it (idempotent when it already exists), push the account's
        // records into it, and only then attach a share.
        await reconcile()
        _ = try? await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        try? await privateEngine?.sendChanges()

        if let existing = try? await existingShare(for: zoneID) {
            var prepared = existing
            if let thumbnail = Self.appIconThumbnailData() {
                existing[CKShare.SystemFieldKey.thumbnailImageData] = thumbnail as CKRecordValue
                if let result = try? await database.modifyRecords(saving: [existing], deleting: []),
                   case .success(let record)? = result.saveResults[existing.recordID],
                   let saved = record as? CKShare {
                    prepared = saved
                }
            }
            sidecar.shareURLs[id] = prepared.url?.absoluteString
            sidecar.shareArchives[id] = Self.archiveShare(prepared)
            saveSidecar()
            await local.setSharing(
                accountID: id, ownerUserID: ownerID,
                memberCount: Self.acceptedMemberCount(prepared)
            )
            await reconcile()
            return prepared
        }

        func makeShare(withThumbnail: Bool) -> CKShare {
            let share = CKShare(recordZoneID: zoneID)
            share[CKShare.SystemFieldKey.title] = accountName(id) as CKRecordValue
            if withThumbnail, let thumbnail = Self.appIconThumbnailData() {
                share[CKShare.SystemFieldKey.thumbnailImageData] = thumbnail as CKRecordValue
            }
            // Anyone the owner sends the link to can open and edit the account —
            // there is no server to hold a guest list, and the link is the invite.
            share.publicPermission = .readWrite
            return share
        }

        func save(_ share: CKShare) async throws -> CKShare {
            let result = try await database.modifyRecords(saving: [share], deleting: [])
            for (_, saveResult) in result.saveResults {
                switch saveResult {
                case .success(let record):
                    if let saved = record as? CKShare { return saved }
                case .failure(let error):
                    throw error
                }
            }
            throw FinanceLedger.Failure.invalidArgument
        }

        func finish(_ saved: CKShare) async -> CKShare {
            sidecar.shareURLs[id] = saved.url?.absoluteString
            sidecar.shareArchives[id] = Self.archiveShare(saved)
            saveSidecar()
            await local.setSharing(
                accountID: id, ownerUserID: ownerID,
                memberCount: Self.acceptedMemberCount(saved)
            )
            await reconcile()
            return saved
        }

        // 1. Straight attempt.
        do {
            return await finish(try await save(makeShare(withThumbnail: true)))
        } catch {
            log.error("shareAccount failed: \(FinanceLog.describe(error), privacy: .public)")

            // 2. "Record too large" — the thumbnail. Share without it.
            if (error as? CKError)?.code == .limitExceeded {
                if let saved = try? await save(makeShare(withThumbnail: false)) {
                    return await finish(saved)
                }
            }

            // 3. A zone still carrying the ghost of a removed share: drop it,
            //    let the engine rebuild a clean one, try once more.
            _ = try? await database.modifyRecordZones(saving: [], deleting: [zoneID])
            for (name, zone) in sidecar.recordZones where zone == zoneID.zoneName {
                sidecar.contentHashes[name] = nil
                sidecar.systemFields[name] = nil
                sidecar.recordZones[name] = nil
                sidecar.updatedAt[name] = nil
            }
            saveSidecar()
            await reconcile()
            _ = try? await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
            try? await privateEngine?.sendChanges()

            if let saved = try? await save(makeShare(withThumbnail: false)) {
                return await finish(saved)
            }
            throw error
        }
    }

    func stopSharingAccount(id: String, memberID: String) async throws {
        let zoneID = CKRecordZone.ID(zoneName: Self.accountZoneName(id))
        guard let share = try await existingShare(for: zoneID) else { return }

        if memberID.isEmpty {
            _ = try await container.privateCloudDatabase.modifyRecords(saving: [], deleting: [share.recordID])
            sidecar.shareURLs[id] = nil
            sidecar.shareArchives[id] = nil
            await local.setSharing(accountID: id, ownerUserID: "", memberCount: 1)
            await reconcile()
        } else if let participant = share.participants.first(where: {
            $0.userIdentity.userRecordID?.recordName == memberID
        }) {
            share.removeParticipant(participant)
            _ = try await container.privateCloudDatabase.modifyRecords(saving: [share], deleting: [])
        }
        saveSidecar()
    }

    /// Called from the app delegate when the user taps a share link.
    func acceptShare(_ metadata: CKShare.Metadata) async {
        do {
            _ = try await container.accept([metadata])
            sidecar.sharedZones.insert(metadata.share.recordID.zoneID.zoneName)
            saveSidecar()
            try? await sharedEngine?.fetchChanges()
            await onRemoteChange()
        } catch {
            log.error("accepting share failed: \(FinanceLog.describe(error), privacy: .public)")
        }
    }

    private func existingShare(for zoneID: CKRecordZone.ID) async throws -> CKShare? {
        let zones = try await container.privateCloudDatabase.recordZones(for: [zoneID])
        guard case .success(let zone)? = zones[zoneID], let shareRef = zone.share else { return nil }
        return try await container.privateCloudDatabase.record(for: shareRef.recordID) as? CKShare
    }

    private func invite(from share: CKShare) -> AccountInvite {
        AccountInvite(code: share.url?.absoluteString ?? "", url: share.url)
    }

    private func accountName(_ id: String) -> String {
        sidecar.accountNames[id] ?? "Financium"
    }

    static func accountZoneName(_ accountID: String) -> String { "acct_\(accountID)" }

    static func accountID(fromZoneName zoneName: String) -> String? {
        guard zoneName.hasPrefix("acct_") else { return nil }
        return String(zoneName.dropFirst("acct_".count))
    }

    /// `participants` also contains the owner and pending invitees. Only an
    /// accepted non-owner means somebody has actually joined through the link.
    private static func acceptedMemberCount(_ share: CKShare) -> Int32 {
        let acceptedGuests = share.participants.filter {
            $0.role != .owner && $0.acceptanceStatus == .accepted
        }.count
        return Int32(1 + acceptedGuests)
    }

    // MARK: - Sidecar

    private func saveSidecar() {
        guard let data = try? JSONEncoder().encode(sidecar) else { return }
        try? data.write(to: sidecarURL, options: .atomic)
    }

    private func decodeState(_ data: Data?) -> CKSyncEngine.State.Serialization? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    private func store(state: CKSyncEngine.State.Serialization, isShared: Bool) {
        let data = try? JSONEncoder().encode(state)
        if isShared { sidecar.sharedState = data } else { sidecar.privateState = data }
        saveSidecar()
    }
}

// MARK: - CKSyncEngineDelegate

extension CloudKitSyncCoordinator: CKSyncEngineDelegate {
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        let isShared = syncEngine === sharedEngine

        switch event {
        case .stateUpdate(let update):
            store(state: update.stateSerialization, isShared: isShared)

        case .accountChange(let change):
            await handleAccountChange(change)

        case .fetchedRecordZoneChanges(let changes):
            await applyFetched(modifications: changes.modifications, deletions: changes.deletions)

        case .fetchedDatabaseChanges(let changes):
            for deletion in changes.deletions {
                sidecar.sharedZones.remove(deletion.zoneID.zoneName)
            }
            saveSidecar()

        case .sentRecordZoneChanges(let sent):
            await handleSent(sent, engine: syncEngine)

        case .sentDatabaseChanges, .willFetchChanges, .willFetchRecordZoneChanges,
             .didFetchRecordZoneChanges, .didFetchChanges, .willSendChanges, .didSendChanges:
            break

        @unknown default:
            break
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !pending.isEmpty else { return nil }

        let raw = await local.rawLedger()
        let systemFields = sidecar.systemFields
        let updatedAt = sidecar.updatedAt

        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            Self.makeRecord(recordID: recordID, raw: raw, systemFields: systemFields, updatedAt: updatedAt)
        }
    }

    // MARK: Event handling

    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) async {
        switch change.changeType {
        case .signIn:
            // A *detached* task, not `Task {}`: CKSyncEngine marks reentrancy
            // with a task-local value that a child task would inherit, tripping
            // its "called back into the delegate" check. `reconcile` only touches
            // `state`, which is allowed, but keep it off the callback for safety.
            Task.detached { [weak self] in await self?.reconcile() }
        case .signOut, .switchAccounts:
            // Never touch the local file here — it is the user's ledger and the
            // one source of truth, not a cache of the cloud. Signing out of
            // iCloud just stops syncing; the data stays on the device. Only the
            // CloudKit bookkeeping is reset, so a different account starts its
            // sync from a clean slate (and gets the local ledger pushed up on
            // the next reconcile).
            sidecar = SyncSidecar()
            saveSidecar()
            await onRemoteChange()
        @unknown default:
            break
        }
    }

    private func applyFetched(
        modifications: [CKDatabase.RecordZoneChange.Modification],
        deletions: [CKDatabase.RecordZoneChange.Deletion]
    ) async {
        guard !modifications.isEmpty || !deletions.isEmpty else { return }

        var accounts: [Finance_Account] = []
        var transactions: [Finance_Transaction] = []
        var budgets: [(month: String, budget: Finance_Budget)] = []
        var goals: [Finance_Goal] = []
        var settings: Finance_FinanceSettings?
        var deleted: Set<String> = []
        var touched: Set<String> = []
        var serverStamps: [String: Date] = [:]
        var sharingUpdates: [(accountID: String, ownerID: String, memberCount: Int32)] = []

        for modification in modifications {
            let record = modification.record
            let name = record.recordID.recordName
            touched.insert(name)
            sidecar.systemFields[name] = Self.encodeSystemFields(record)
            serverStamps[name] = record["updatedAt"] as? Date ?? Date()

            switch record.recordType {
            case CloudRecordMapping.accountType:
                if let account = CloudRecordMapping.account(from: record) {
                    accounts.append(account)
                    sidecar.accountNames[account.id] = account.name
                }
            case CloudRecordMapping.transactionType:
                if let transaction = CloudRecordMapping.transaction(from: record) { transactions.append(transaction) }
            case CloudRecordMapping.budgetType:
                if let decoded = CloudRecordMapping.budget(from: record) { budgets.append(decoded) }
            case CloudRecordMapping.goalType:
                if let goal = CloudRecordMapping.goal(from: record) { goals.append(goal) }
            case CloudRecordMapping.settingsType:
                settings = CloudRecordMapping.settings(from: record)
            case CKRecord.SystemType.share:
                if let share = record as? CKShare,
                   let accountID = Self.accountID(fromZoneName: record.recordID.zoneID.zoneName) {
                    sidecar.shareArchives[accountID] = Self.archiveShare(share)
                    if let url = share.url { sidecar.shareURLs[accountID] = url.absoluteString }
                    sharingUpdates.append((
                        accountID: accountID,
                        ownerID: share.owner.userIdentity.userRecordID?.recordName ?? "",
                        memberCount: Self.acceptedMemberCount(share)
                    ))
                }
            default:
                break
            }
        }

        for deletion in deletions {
            let name = deletion.recordID.recordName
            sidecar.systemFields[name] = nil
            sidecar.contentHashes[name] = nil
            sidecar.recordZones[name] = nil
            sidecar.updatedAt[name] = nil
            if let entity = CloudRecordMapping.entityID(fromRecordName: name), !entity.id.isEmpty {
                deleted.insert(entity.id)
            }
        }

        await local.applyRemote(
            accounts: accounts,
            transactions: transactions,
            budgets: budgets,
            goals: goals,
            settings: settings,
            deleted: deleted
        )
        // Account payloads still carry their previous member count. Apply the
        // current CKShare state afterwards so an acceptance update wins.
        for update in sharingUpdates {
            await local.setSharing(
                accountID: update.accountID,
                ownerUserID: update.ownerID,
                memberCount: update.memberCount
            )
        }
        // Bring the sidecar in line with what was just merged, so the next
        // reconcile does not send these records straight back to the server.
        await refreshBookkeeping(for: touched, serverStamps: serverStamps)
        saveSidecar()
        await onRemoteChange()
    }

    /// Recomputes content hashes and zones for records that were just merged in
    /// from the server, so a reconcile treats them as already synced.
    private func refreshBookkeeping(for names: Set<String>, serverStamps: [String: Date]) async {
        guard !names.isEmpty else { return }
        let raw = await local.rawLedger()
        var desired: [String: DesiredRecord] = [:]
        for entry in Self.desiredRecords(raw, sidecar: sidecar) { desired[entry.recordName] = entry }
        for name in names {
            if let entry = desired[name] {
                sidecar.contentHashes[name] = entry.payloadHash
                sidecar.recordZones[name] = entry.zoneID.zoneName
            }
            if let stamp = serverStamps[name] { sidecar.updatedAt[name] = stamp }
        }
    }

    private func handleSent(_ sent: CKSyncEngine.Event.SentRecordZoneChanges, engine: CKSyncEngine) async {
        for saved in sent.savedRecords {
            sidecar.systemFields[saved.recordID.recordName] = Self.encodeSystemFields(saved)
        }
        for deletedID in sent.deletedRecordIDs {
            sidecar.systemFields[deletedID.recordName] = nil
        }

        var retry: [CKSyncEngine.PendingRecordZoneChange] = []
        for failure in sent.failedRecordSaves {
            let record = failure.record
            let name = record.recordID.recordName
            switch failure.error.code {
            case .serverRecordChanged:
                guard let server = failure.error.serverRecord else { break }
                sidecar.systemFields[name] = Self.encodeSystemFields(server)
                let serverAt = server["updatedAt"] as? Date ?? .distantPast
                let localAt = sidecar.updatedAt[name] ?? .distantPast
                if localAt > serverAt {
                    // Our change is the more recent one — keep our payload, but
                    // on top of the server's change tag so the retry lands.
                    retry.append(.saveRecord(record.recordID))
                } else {
                    await applyServerRecord(server)
                    await refreshBookkeeping(
                        for: [name],
                        serverStamps: [name: serverAt == .distantPast ? Date() : serverAt]
                    )
                }
            case .zoneNotFound, .userDeletedZone:
                engine.state.add(pendingDatabaseChanges: [
                    .saveZone(CKRecordZone(zoneID: record.recordID.zoneID))
                ])
                retry.append(.saveRecord(record.recordID))
            case .unknownItem:
                sidecar.contentHashes[name] = nil
            default:
                log.error("record save failed: \(FinanceLog.describe(failure.error), privacy: .public)")
            }
        }
        if !retry.isEmpty { engine.state.add(pendingRecordZoneChanges: retry) }
        saveSidecar()
    }

    private func applyServerRecord(_ record: CKRecord) async {
        var accounts: [Finance_Account] = []
        var transactions: [Finance_Transaction] = []
        var budgets: [(month: String, budget: Finance_Budget)] = []
        var goals: [Finance_Goal] = []
        var settings: Finance_FinanceSettings?

        switch record.recordType {
        case CloudRecordMapping.accountType:
            if let account = CloudRecordMapping.account(from: record) { accounts = [account] }
        case CloudRecordMapping.transactionType:
            if let transaction = CloudRecordMapping.transaction(from: record) { transactions = [transaction] }
        case CloudRecordMapping.budgetType:
            if let decoded = CloudRecordMapping.budget(from: record) { budgets = [decoded] }
        case CloudRecordMapping.goalType:
            if let goal = CloudRecordMapping.goal(from: record) { goals = [goal] }
        case CloudRecordMapping.settingsType:
            settings = CloudRecordMapping.settings(from: record)
        default:
            return
        }
        await local.applyRemote(
            accounts: accounts, transactions: transactions, budgets: budgets,
            goals: goals, settings: settings, deleted: []
        )
        await onRemoteChange()
    }

    // MARK: Record building

    private struct DesiredRecord {
        let recordName: String
        let zoneID: CKRecordZone.ID
        let payloadHash: String
    }

    /// A stable content hash. `Data.hashValue` is seeded per process run, so a
    /// relaunch would see every record as changed and re-upload the lot.
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func desiredRecords(_ raw: RawLedger, sidecar: SyncSidecar) -> [DesiredRecord] {
        var out: [DesiredRecord] = []
        let ledgerZone = CKRecordZone.ID(zoneName: ledgerZoneName)

        func zone(forAccount accountID: String) -> CKRecordZone.ID {
            CKRecordZone.ID(zoneName: accountZoneName(accountID))
        }

        for account in raw.accounts {
            out.append(DesiredRecord(
                recordName: CloudRecordMapping.recordName(accountID: account.id),
                zoneID: zone(forAccount: account.id),
                payloadHash: digest((try? account.serializedData()) ?? Data())
            ))
        }
        for transaction in raw.transactions {
            let primary = transaction.kind == .income ? transaction.toAccountID : transaction.fromAccountID
            out.append(DesiredRecord(
                recordName: CloudRecordMapping.recordName(transactionID: transaction.id),
                zoneID: primary.isEmpty ? ledgerZone : zone(forAccount: primary),
                payloadHash: digest((try? transaction.serializedData()) ?? Data())
            ))
        }
        for stored in raw.budgets {
            var data = (try? stored.budget.serializedData()) ?? Data()
            data.append(contentsOf: stored.month.utf8)
            out.append(DesiredRecord(
                recordName: CloudRecordMapping.recordName(budgetID: stored.budget.id),
                zoneID: ledgerZone,
                payloadHash: digest(data)
            ))
        }
        for goal in raw.goals {
            out.append(DesiredRecord(
                recordName: CloudRecordMapping.recordName(goalID: goal.id),
                zoneID: goal.accountID.isEmpty ? ledgerZone : zone(forAccount: goal.accountID),
                payloadHash: digest((try? goal.serializedData()) ?? Data())
            ))
        }
        out.append(DesiredRecord(
            recordName: CloudRecordMapping.settingsRecordName,
            zoneID: ledgerZone,
            payloadHash: digest((try? raw.settings.serializedData()) ?? Data())
        ))
        return out
    }

    private static func makeRecord(
        recordID: CKRecord.ID,
        raw: RawLedger,
        systemFields: [String: Data],
        updatedAt: [String: Date]
    ) -> CKRecord? {
        guard let entity = CloudRecordMapping.entityID(fromRecordName: recordID.recordName) else { return nil }
        let stamp = updatedAt[recordID.recordName] ?? Date()

        func base(_ type: String) -> CKRecord {
            if let data = systemFields[recordID.recordName], let restored = decodeSystemFields(data) {
                return restored
            }
            return CKRecord(recordType: type, recordID: recordID)
        }

        switch entity.kind {
        case .account:
            guard let account = raw.accounts.first(where: { $0.id == entity.id }) else { return nil }
            let record = base(CloudRecordMapping.accountType)
            CloudRecordMapping.apply(account: account, updatedAt: stamp, to: record)
            return record
        case .transaction:
            guard let transaction = raw.transactions.first(where: { $0.id == entity.id }) else { return nil }
            let record = base(CloudRecordMapping.transactionType)
            CloudRecordMapping.apply(transaction: transaction, updatedAt: stamp, to: record)
            return record
        case .budget:
            guard let stored = raw.budgets.first(where: { $0.budget.id == entity.id }) else { return nil }
            let record = base(CloudRecordMapping.budgetType)
            CloudRecordMapping.apply(budget: stored.budget, month: stored.month, updatedAt: stamp, to: record)
            return record
        case .goal:
            guard let goal = raw.goals.first(where: { $0.id == entity.id }) else { return nil }
            let record = base(CloudRecordMapping.goalType)
            CloudRecordMapping.apply(goal: goal, updatedAt: stamp, to: record)
            return record
        case .settings:
            let record = base(CloudRecordMapping.settingsType)
            CloudRecordMapping.apply(settings: raw.settings, updatedAt: stamp, to: record)
            return record
        }
    }

    // MARK: System-field archiving

    /// A small square JPEG of the app icon for the `CKShare` — what the
    /// recipient sees on the invitation screen instead of a generic iCloud
    /// glyph. PNG is intentional: the icon asset has transparent rounded
    /// corners, which JPEG used to flatten to black squares.
    ///
    /// Deliberately tiny. The share record has a hard size limit, and a
    /// full-resolution PNG of the 1024² icon blew past it with "record too
    /// large" (CKError 27). 96px at 1× as PNG is a few kilobytes; anything
    /// larger than 40 KB is dropped rather than risking the whole share.
    private static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47])

    static func appIconThumbnailData() -> Data? {
        guard let image = UIImage(named: "AppIconPreviewDollarWallet") else { return nil }
        let side: CGFloat = 96
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        guard let data = rendered.pngData(), data.count <= 40_000 else { return nil }
        return data
    }

    static func encodeSystemFields(_ record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        return coder.encodedData
    }

    static func decodeSystemFields(_ data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        let record = CKRecord(coder: coder)
        coder.finishDecoding()
        return record
    }

    private static func archiveShare(_ share: CKShare) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: share, requiringSecureCoding: true)
    }

    private static func decodeShare(_ data: Data) -> CKShare? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKShare.self, from: data)
    }
}

// MARK: - Sidecar file

/// CloudKit bookkeeping that lives beside the ledger file, not in it.
private nonisolated struct SyncSidecar: Codable {
    /// `CKSyncEngine.State.Serialization`, JSON-encoded, per database.
    var privateState: Data?
    var sharedState: Data?
    /// Archived `CKRecord` system fields (no payload) per record name, for
    /// sending updates with the right change tag.
    var systemFields: [String: Data] = [:]
    /// Stable digest of the last payload synced per record name, so a reconcile
    /// only queues what actually changed.
    var contentHashes: [String: String] = [:]
    /// When each record's payload last changed locally, for last-writer-wins.
    var updatedAt: [String: Date] = [:]
    /// Which zone each record name sits in, for building deletions.
    var recordZones: [String: String] = [:]
    /// Zone names that live in the shared database rather than the private one.
    var sharedZones: Set<String> = []
    /// Account name per id, for a share sheet's title.
    var accountNames: [String: String] = [:]
    /// The share link per shared account id.
    var shareURLs: [String: String] = [:]
    /// Full saved shares per account id, so collaboration UI can open without
    /// fetching the share record first.
    var shareArchives: [String: Data] = [:]

    private enum CodingKeys: String, CodingKey {
        case privateState, sharedState, systemFields, contentHashes, updatedAt
        case recordZones, sharedZones, accountNames, shareURLs, shareArchives
    }

    init() {}

    init(from decoder: any Swift.Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        privateState = try values.decodeIfPresent(Data.self, forKey: .privateState)
        sharedState = try values.decodeIfPresent(Data.self, forKey: .sharedState)
        systemFields = try values.decodeIfPresent([String: Data].self, forKey: .systemFields) ?? [:]
        contentHashes = try values.decodeIfPresent([String: String].self, forKey: .contentHashes) ?? [:]
        updatedAt = try values.decodeIfPresent([String: Date].self, forKey: .updatedAt) ?? [:]
        recordZones = try values.decodeIfPresent([String: String].self, forKey: .recordZones) ?? [:]
        sharedZones = try values.decodeIfPresent(Set<String>.self, forKey: .sharedZones) ?? []
        accountNames = try values.decodeIfPresent([String: String].self, forKey: .accountNames) ?? [:]
        shareURLs = try values.decodeIfPresent([String: String].self, forKey: .shareURLs) ?? [:]
        shareArchives = try values.decodeIfPresent([String: Data].self, forKey: .shareArchives) ?? [:]
    }
}

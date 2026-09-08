import CloudKit
import Combine
import Foundation
import SwiftUI
import os
import UIKit

/// The person behind the ledger: a name, a photo, an avatar colour.
///
/// Kept in a file on the device and mirrored to a single `Profile` record in
/// the user's private CloudKit database, so the same face and name show up on
/// their other devices. This does not go through `CKSyncEngine` — it is one
/// small record with last-writer-wins, and a direct fetch/save is less code
/// than teaching the ledger engine about a record that is not part of the
/// ledger.
@MainActor
final class ProfileStore: ObservableObject {
    enum MonogramStyle: String, CaseIterable, Codable, Identifiable {
        case classic, rounded, serif, mono
        var id: String { rawValue }

        var titleKey: LocalizedStringKey {
            switch self {
            case .classic: "profile.monogram.classic"
            case .rounded: "profile.monogram.rounded"
            case .serif: "profile.monogram.serif"
            case .mono: "profile.monogram.mono"
            }
        }

        func font(size: CGFloat) -> Font {
            switch self {
            case .classic: .system(size: size, weight: .semibold, design: .default)
            case .rounded: .system(size: size, weight: .semibold, design: .rounded)
            case .serif: .system(size: size, weight: .semibold, design: .serif)
            case .mono: .system(size: size, weight: .semibold, design: .monospaced)
            }
        }
    }

    @Published var name: String = ""
    @Published var colorHex: String = "#F2C14E"
    @Published var emoji: String?
    @Published var monogramStyle: MonogramStyle = .classic
    @Published private(set) var photo: UIImage?

    /// Toggled by the toolbar avatar button on the main screens.
    @Published var isPresented = false

    private var updatedAt = Date.distantPast
    private let container: CKContainer
    private let fileURL: URL
    private let photoURL: URL
    private var syncTask: Task<Void, Never>?

    static let defaultColorHex = "#F2C14E"

    /// The colours offered on the avatar editor.
    static let palette: [String] = [
        "#F2C14E", "#E8804B", "#E06C75", "#C878C8",
        "#7C83E8", "#4EA1E8", "#4EC9C0", "#6BBF59", "#8C8C94"
    ]

    private struct Stored: Codable {
        var name: String
        var colorHex: String
        var updatedAt: Date
        var emoji: String?
        var monogramStyle: String?
    }

    init(container: CKContainer = .default()) {
        self.container = container
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.fileURL = directory.appendingPathComponent("financium-profile.json")
        self.photoURL = directory.appendingPathComponent("financium-profile-photo.jpg")
        loadLocal()
    }

    // MARK: - Local

    private func loadLocal() {
        if let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            name = stored.name
            colorHex = stored.colorHex.isEmpty ? Self.defaultColorHex : stored.colorHex
            updatedAt = stored.updatedAt
            emoji = stored.emoji?.isEmpty == false ? stored.emoji : nil
            monogramStyle = stored.monogramStyle.flatMap(MonogramStyle.init) ?? .classic
        }
        if let data = try? Data(contentsOf: photoURL) {
            photo = UIImage(data: data)
        }
    }

    private func persistLocal() {
        let stored = Stored(
            name: name, colorHex: colorHex, updatedAt: updatedAt,
            emoji: emoji, monogramStyle: monogramStyle.rawValue
        )
        if let data = try? JSONEncoder().encode(stored) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - Editing

    /// First-run default: take the name from the Apple account when the user
    /// has not set one of their own.
    func seedNameIfEmpty(_ candidate: String) {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !trimmed.isEmpty else { return }
        name = trimmed
        commit()
    }

    /// Saves a field change and pushes it up. Call after mutating `name`,
    /// `colorHex` or the appearance fields.
    func commit() {
        updatedAt = Date()
        persistLocal()
        scheduleSync(push: true)
    }

    func setPhoto(_ image: UIImage?) {
        photo = image
        if image != nil { emoji = nil }
        updatedAt = Date()
        if let image, let data = Self.encode(image) {
            try? data.write(to: photoURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: photoURL)
        }
        persistLocal()
        scheduleSync(push: true)
    }

    /// An emoji instead of a monogram or photo. Passing "" or nil clears it.
    func setEmoji(_ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespaces)
        emoji = (trimmed?.isEmpty == false) ? trimmed : nil
        if emoji != nil { setPhoto(nil) } else { commit() }
    }

    /// A monogram fallback when there is no photo.
    var monogram: String { Self.monogram(for: name) }

    static func monogram(for name: String) -> String {
        let initials = name.split(whereSeparator: { $0.isWhitespace }).prefix(2).compactMap(\.first)
        return initials.isEmpty ? "?" : String(initials).uppercased()
    }

    // MARK: - CloudKit

    /// Pulls the profile from iCloud on launch and whenever the account
    /// changes.
    func refreshFromCloud() {
        scheduleSync(push: false)
    }

    private func scheduleSync(push: Bool) {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            await self?.sync(push: push)
        }
    }

    private static let recordType = "Profile"
    private static let recordName = "profile"

    private func sync(push: Bool) async {
        let recordID = CKRecord.ID(recordName: Self.recordName)
        let database = container.privateCloudDatabase

        let remote = try? await database.record(for: recordID)

        if let remote {
            let remoteUpdated = remote["updatedAt"] as? Date ?? .distantPast
            if remoteUpdated > updatedAt {
                await adopt(remote)
                return
            }
        }

        guard push else { return }

        let record = remote ?? CKRecord(recordType: Self.recordType, recordID: recordID)
        record["name"] = name as CKRecordValue
        record["colorHex"] = colorHex as CKRecordValue
        record["updatedAt"] = updatedAt as CKRecordValue
        record["emoji"] = emoji as CKRecordValue?
        record["monogramStyle"] = monogramStyle.rawValue as CKRecordValue
        if FileManager.default.fileExists(atPath: photoURL.path) {
            record["photo"] = CKAsset(fileURL: photoURL)
        } else {
            record["photo"] = nil
        }

        do {
            _ = try await database.modifyRecords(
                saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged
            )
        } catch let error as CKError where error.code == .serverRecordChanged {
            if let server = error.serverRecord { await adopt(server) }
        } catch {
            FinanceLog.store.error("profile sync failed: \(FinanceLog.describe(error), privacy: .public)")
        }
    }

    private func adopt(_ record: CKRecord) async {
        name = record["name"] as? String ?? name
        if let hex = record["colorHex"] as? String, !hex.isEmpty { colorHex = hex }
        updatedAt = record["updatedAt"] as? Date ?? updatedAt
        let remoteEmoji = record["emoji"] as? String
        emoji = remoteEmoji?.isEmpty == false ? remoteEmoji : nil
        if let styleRaw = record["monogramStyle"] as? String, let style = MonogramStyle(rawValue: styleRaw) {
            monogramStyle = style
        }

        if let asset = record["photo"] as? CKAsset, let url = asset.fileURL,
           let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
            photo = image
            try? data.write(to: photoURL, options: .atomic)
        } else {
            photo = nil
            try? FileManager.default.removeItem(at: photoURL)
        }
        persistLocal()
    }

    /// Clears everything — for a sign-out.
    func wipe() {
        name = ""
        colorHex = Self.defaultColorHex
        emoji = nil
        monogramStyle = .classic
        photo = nil
        updatedAt = .distantPast
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: photoURL)
    }

    /// Removes the profile record from iCloud too — for "delete account".
    func deleteFromCloud() async {
        syncTask?.cancel()
        _ = try? await container.privateCloudDatabase.deleteRecord(
            withID: CKRecord.ID(recordName: Self.recordName)
        )
        wipe()
    }

    // MARK: - Image

    private static func encode(_ image: UIImage) -> Data? {
        let maxSide: CGFloat = 512
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: 0.82)
    }
}

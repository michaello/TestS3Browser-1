import Foundation

/// The old unscoped snapshot is claimed once. Subsequent accounts can only read
/// their own versioned envelope, never the previous account's widget preview.
@MainActor
struct MetadataSnapshotStore {
    private struct Envelope: Codable {
        let version: Int
        let account: String
        let snapshot: MetadataCatalogSnapshot
    }

    let defaults: UserDefaults
    private let legacyOwnerKey = "s3MetadataLegacyOwner.v1"

    func load(account: String) -> MetadataCatalogSnapshot? {
        guard let data = defaults.data(forKey: key(account)),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.version == 1, envelope.account.utf8.elementsEqual(account.utf8) else { return nil }
        return envelope.snapshot
    }

    func save(_ snapshot: MetadataCatalogSnapshot, account: String) throws {
        let envelope = Envelope(version: 1, account: account, snapshot: snapshot)
        let data = try JSONEncoder().encode(envelope)
        defaults.set(data, forKey: key(account))
    }

    func claimLegacy(_ records: [MetadataRecord], account: String, recordedAccount: String? = nil) throws -> MetadataCatalogSnapshot? {
        if let existing = load(account: account) { return existing }
        if let recordedAccount, !recordedAccount.utf8.elementsEqual(account.utf8) { return nil }
        if let owner = defaults.string(forKey: legacyOwnerKey), !owner.utf8.elementsEqual(account.utf8) { return nil }
        guard !records.isEmpty else { return nil }
        let snapshot = MetadataCatalogSnapshot(records: records,
            failedBuckets: [MetadataBucketFailure(bucket: "saved snapshot", message: "Awaiting a complete refresh")], refreshedAt: nil)
        try save(snapshot, account: account)
        defaults.set(account, forKey: legacyOwnerKey)
        return snapshot
    }

    private func key(_ account: String) -> String { "s3MetadataCatalog.v1." + account }
}

import Foundation
import Darwin

enum RecentUploadDeliveryError: LocalizedError {
    case coordinationUnavailable(Int32)
    case preferencesSynchronizationFailed

    var errorDescription: String? {
        switch self {
        case .coordinationUnavailable(let status):
            "Shared upload snapshot coordination is unavailable (status \(status))."
        case .preferencesSynchronizationFailed:
            "Shared upload snapshot preferences could not be synchronized."
        }
    }
}

/// App, queued/shortcut uploads and Share publish through this same persistence seam.
@MainActor
enum RecentUploadDelivery {
    struct Publication {
        let snapshot: MetadataCatalogSnapshot
        let importedUploads: Bool
    }
    private struct PendingUpload: Codable {
        let account: String
        let record: MetadataRecord
        let deliveredAt: Date
    }

    private static func pendingPrefix(_ account: String) -> String {
        "s3RecentUploads.pending.v1." + Data(account.utf8).base64EncodedString() + "."
    }
    private static func pendingKey(account: String, bucket: String, key: String) -> String {
        pendingPrefix(account) + S3TransferKeys.identifier(bucket: bucket, key: key)
    }
    private static func matches(_ record: MetadataRecord, _ other: MetadataRecord) -> Bool {
        record.bucket.utf8.elementsEqual(other.bucket.utf8) && record.key.utf8.elementsEqual(other.key.utf8)
    }

    /// App and Share are separate processes. Every journal read, retirement and
    /// publication uses the same app-group lock and observes flushed preferences.
    private static func coordinated<T>(defaults: UserDefaults, lockURL: URL,
                                       operation: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = lockURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else { throw RecentUploadDeliveryError.coordinationUnavailable(errno) }
        defer { Darwin.close(descriptor) }
        var status: Int32
        repeat { status = flock(descriptor, LOCK_EX) } while status != 0 && errno == EINTR
        guard status == 0 else { throw RecentUploadDeliveryError.coordinationUnavailable(errno) }
        defer { flock(descriptor, LOCK_UN) }
        guard defaults.synchronize() else { throw RecentUploadDeliveryError.preferencesSynchronizationFailed }
        let result: T
        do { result = try operation() }
        catch {
            // A failed publication can still have written its recovery journal.
            // Flush that state before another process acquires the lock.
            guard defaults.synchronize() else { throw RecentUploadDeliveryError.preferencesSynchronizationFailed }
            throw error
        }
        guard defaults.synchronize() else { throw RecentUploadDeliveryError.preferencesSynchronizationFailed }
        return result
    }

    /// Separate object keys prevent a stale app catalog from overwriting Share's
    /// delivery journal. A scan that started after delivery can retire its entry.
    private static func merging(_ snapshot: MetadataCatalogSnapshot, account: String,
                                defaults: UserDefaults) -> Publication {
        var result = snapshot
        var imported = false
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(pendingPrefix(account)) {
            guard let data = value as? Data, let pending = try? JSONDecoder().decode(PendingUpload.self, from: data),
                  pending.account.utf8.elementsEqual(account.utf8) else { continue }
            let record = pending.record
            if let refreshed = snapshot.refreshedAt, refreshed > pending.deliveredAt,
               snapshot.buckets.contains(where: { $0.utf8.elementsEqual(record.bucket.utf8) }),
               !snapshot.failedBuckets.contains(where: { $0.bucket.utf8.elementsEqual(record.bucket.utf8) }) {
                defaults.removeObject(forKey: key)
                continue
            }
            let existing = result.records.first { matches($0, record) }
            if let existing, existing.size == record.size, existing.modified == record.modified,
               existing.etag.map({ Data($0.utf8) }) == record.etag.map({ Data($0.utf8) }) { continue }
            result.records.removeAll { matches($0, record) }
            result.records.append(record)
            if !result.buckets.contains(where: { $0.utf8.elementsEqual(record.bucket.utf8) }) { result.buckets.append(record.bucket) }
            imported = true
        }
        return Publication(snapshot: result, importedUploads: imported)
    }

    /// An acknowledged app mutation supersedes an earlier Share delivery for the
    /// same exact object. Other pending uploads remain available to cached readers.
    static func recordMutation(account: String, removed: (bucket: String, key: String)?,
                               replacement: MetadataRecord?, defaults: UserDefaults, lockURL: URL) throws {
        try coordinated(defaults: defaults, lockURL: lockURL) {
            if let removed {
                defaults.removeObject(forKey: pendingKey(account: account, bucket: removed.bucket, key: removed.key))
            }
            if let replacement {
                defaults.removeObject(forKey: pendingKey(account: account, bucket: replacement.bucket, key: replacement.key))
            }
        }
    }

    @discardableResult
    static func publish(_ snapshot: MetadataCatalogSnapshot, account: String, defaults: UserDefaults,
                        lockURL: URL, reload: () -> Void) throws -> Publication {
        let publication = try coordinated(defaults: defaults, lockURL: lockURL) {
            try publishUnlocked(snapshot, account: account, defaults: defaults)
        }
        reload()
        return publication
    }

    private static func publishUnlocked(_ snapshot: MetadataCatalogSnapshot, account: String,
                                        defaults: UserDefaults) throws -> Publication {
        let publication = merging(snapshot, account: account, defaults: defaults)
        let snapshot = publication.snapshot
        try MetadataSnapshotStore(defaults: defaults).save(snapshot, account: account)
        let preview = snapshot.records.sorted { $0.modified > $1.modified }.prefix(50).map {
            RecentUploadPreview(key: $0.key, size: $0.size, lastModified: $0.modified, etag: $0.etag, bucket: $0.bucket)
        }
        let data = try JSONEncoder().encode(preview)
        let widget = try JSONEncoder().encode(RecentUploadWidgetSnapshot(version: 1, account: account, uploads: preview))
        defaults.set(widget, forKey: "s3WidgetRecent.v1")
        defaults.set(data, forKey: "recentUploads")
        defaults.set(account, forKey: "recentUploadsAccount.v1")
        guard defaults.data(forKey: "s3WidgetRecent.v1") == widget,
              defaults.data(forKey: "recentUploads") == data,
              defaults.string(forKey: "recentUploadsAccount.v1")?.utf8.elementsEqual(account.utf8) == true else {
            throw SecureConfigurationError.preferenceWriteNotVerified
        }
        return publication
    }

    static func uploaded(_ record: MetadataRecord, account: String, defaults: UserDefaults,
                         lockURL: URL, deliveredAt: Date = Date(),
                         reload: () -> Void) throws {
        try coordinated(defaults: defaults, lockURL: lockURL) {
            try uploadedUnlocked(record, account: account, defaults: defaults, deliveredAt: deliveredAt)
        }
        reload()
    }

    private static func uploadedUnlocked(_ record: MetadataRecord, account: String, defaults: UserDefaults,
                                         deliveredAt: Date) throws {
        let journalKey = pendingKey(account: account, bucket: record.bucket, key: record.key)
        let journal = try JSONEncoder().encode(PendingUpload(account: account, record: record, deliveredAt: deliveredAt))
        defaults.set(journal, forKey: journalKey)
        guard defaults.data(forKey: journalKey) == journal else { throw SecureConfigurationError.preferenceWriteNotVerified }
        var snapshot = MetadataSnapshotStore(defaults: defaults).load(account: account) ??
            MetadataCatalogSnapshot(records: [], failedBuckets: [MetadataBucketFailure(bucket: "account catalog", message: "Awaiting a complete refresh")], refreshedAt: nil)
        snapshot.records.removeAll { $0.bucket.utf8.elementsEqual(record.bucket.utf8) && $0.key.utf8.elementsEqual(record.key.utf8) }
        snapshot.records.append(record)
        if !snapshot.buckets.contains(where: { $0.utf8.elementsEqual(record.bucket.utf8) }) { snapshot.buckets.append(record.bucket) }
        if let activeAccount = defaults.string(forKey: "recentUploadsAccount.v1"),
           !activeAccount.utf8.elementsEqual(account.utf8) {
            // A Share upload can finish after the app has switched accounts. Preserve
            // its own envelope without replacing the currently active widget account.
            try MetadataSnapshotStore(defaults: defaults).save(merging(snapshot, account: account, defaults: defaults).snapshot, account: account)
            return
        }
        _ = try publishUnlocked(snapshot, account: account, defaults: defaults)
    }
}

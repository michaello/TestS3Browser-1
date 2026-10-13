import Foundation
import WidgetKit

extension S3Service {
    func restoreMetadataSnapshot() {
        guard let defaults = snapshotDefaults else { return }
        let account = session.configuration.account
        let store = MetadataSnapshotStore(defaults: defaults)
        var snapshot = store.load(account: account)
        if snapshot == nil, let data = defaults.data(forKey: "recentUploads"),
           let legacy = try? JSONDecoder().decode([S3Object].self, from: data) {
            let records = legacy.map { MetadataRecord(bucket: $0.bucket ?? config.bucketName,
                key: $0.key, size: $0.size, modified: $0.lastModified, etag: $0.etag) }
            do { snapshot = try store.claimLegacy(records, account: account,
                recordedAccount: defaults.string(forKey: "recentUploadsAccount.v1")) }
            catch { logger.error("Recent snapshot migration failed: \(error.localizedDescription)") }
        }
        if let snapshot {
            session.catalogs.seed(snapshot, for: account, refreshedAt: snapshot.refreshedAt)
            recentFiles = (try? MetadataCatalogQuery.select(snapshot, limit: 50))?.map(\.s3Object) ?? []
            recentRowsFromCache = !recentFiles.isEmpty
        } else {
            recentFiles = []
            recentRowsFromCache = false
        }
        // Legacy widget consumers see the active account only. Named envelopes preserve others.
        writeWidgetPreview()
    }

    func persistRecentFiles() {
        writeWidgetPreview()
    }

    func recordSuccessfulDelete(key: String, bucket: String, generation: UUID) {
        guard session.isCurrent(generation) else { return }
        publishMutation(MetadataMutation(account: session.configuration.account, replacement: nil,
            removed: LocalObjectIdentity(account: session.configuration.account, bucket: bucket, key: key)))
    }

    /// Call only after the captured account generation completes its remote mutation.
    func recordSuccessfulUpload(key: String, bucket: String, size: Int64, contentType: String,
                                generation: UUID, etag: String? = nil) {
        guard session.isCurrent(generation) else { return }
        let record = MetadataRecord(bucket: bucket, key: key, size: size, modified: Date(), etag: etag, contentType: contentType)
        updateMetadata(record, removedSource: nil)
    }

    func recordObjectTransfer(_ request: ObjectTransferRequest, receipt: ObjectCopyReceipt,
                              removedSource: Bool, generation: UUID) {
        guard session.isCurrent(generation) else { return }
        if removedSource {
            ObjectAnnotationState.shared.relocate(
                from: LocalObjectIdentity(account: session.configuration.account, bucket: request.source.bucket, key: request.source.key),
                to: LocalObjectIdentity(account: session.configuration.account, bucket: request.destination.bucket, key: request.destination.key))
        }
        let destination = receipt.metadata(bucket: request.destination.bucket, key: request.destination.key)
        updateMetadata(destination, removedSource: removedSource ? request.source : nil)
    }

    private func updateMetadata(_ record: MetadataRecord, removedSource: TransferObjectLocation?) {
        let account = session.configuration.account
        publishMutation(MetadataMutation(account: account, replacement: record,
            removed: removedSource.map { LocalObjectIdentity(account: account, bucket: $0.bucket, key: $0.key) }))
    }

    private func publishMutation(_ mutation: MetadataMutation) {
        let account = session.configuration.account
        if let defaults = snapshotDefaults {
            do {
                try RecentUploadDelivery.recordMutation(account: account,
                    removed: mutation.removed.map { ($0.bucket, $0.key) }, replacement: mutation.replacement,
                    defaults: defaults, lockURL: recentDeliveryLockURL())
            } catch { logger.error("Recent mutation journal update failed: \(error.localizedDescription)") }
        }
        let catalog = MetadataMutationProjection.apply(mutation, currentAccount: account,
            catalogs: session.catalogs, listings: session.listings)
        if let catalog {
            recentFiles = (try? MetadataCatalogQuery.select(catalog, limit: recentSelectionLimit,
                matching: { recentSelectionFilter.matches($0.s3Object.fileType) }))?.map(\.s3Object) ?? []
        } else if let removed = mutation.removed {
            recentFiles.removeAll { $0.key.utf8.elementsEqual(removed.key.utf8) && ($0.bucket ?? currentBucket).utf8.elementsEqual(removed.bucket.utf8) }
        }
        persistRecentFiles()
    }

    func annotationIdentity(for object: S3Object) -> LocalObjectIdentity {
        LocalObjectIdentity(account: session.configuration.account, bucket: object.bucket ?? currentBucket, key: object.key)
    }

    private func writeWidgetPreview() {
        let snapshot = session.catalogs.value(for: session.configuration.account) ??
            MetadataCatalogSnapshot(records: [], failedBuckets: [], refreshedAt: nil)
        guard let defaults = snapshotDefaults else { return }
        do {
            let delivery = try RecentUploadDelivery.publish(snapshot, account: session.configuration.account,
                defaults: defaults, lockURL: recentDeliveryLockURL()) {
                if publishWidget { WidgetCenter.shared.reloadTimelines(ofKind: "TestS3BrowserWidget") }
            }
            if delivery.importedUploads {
                session.catalogs.seed(delivery.snapshot, for: session.configuration.account, refreshedAt: delivery.snapshot.refreshedAt)
                selectRecentFiles(limit: recentSelectionLimit, typeFilter: recentSelectionFilter)
            }
        } catch { logger.error("Recent widget snapshot delivery failed: \(error.localizedDescription)") }
    }

    private func recentDeliveryLockURL() throws -> URL {
        // App-hosted tests use isolated synthetic defaults and never the App Group.
        if !publishWidget {
            return FileManager.default.temporaryDirectory.appendingPathComponent("s3browser-fixture-recent.lock")
        }
        return try SharedConfig.recentDeliveryLockURL()
    }
}

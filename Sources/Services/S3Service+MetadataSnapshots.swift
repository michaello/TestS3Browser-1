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
        let account = session.configuration.account
        if let snapshot = session.catalogs.value(for: account),
           let defaults = snapshotDefaults {
            do { try MetadataSnapshotStore(defaults: defaults).save(snapshot, account: account) }
            catch { logger.error("Recent snapshot save failed: \(error.localizedDescription)") }
        }
        writeWidgetPreview()
    }

    /// Call only after the captured account generation completes its remote mutation.
    func recordSuccessfulUpload(key: String, bucket: String, size: Int64, contentType: String,
                                generation: UUID, etag: String? = nil) {
        guard session.isCurrent(generation) else { return }
        let record = MetadataRecord(bucket: bucket, key: key, size: size, modified: Date(), etag: etag, contentType: contentType)
        updateMetadata(record, removedSource: nil)
    }

    func recordObjectTransfer(_ request: ObjectTransferRequest, generation: UUID) {
        guard session.isCurrent(generation) else { return }
        if request.kind != .copy {
            ObjectAnnotationState.shared.relocate(
                from: LocalObjectIdentity(account: session.configuration.account, bucket: request.source.bucket, key: request.source.key),
                to: LocalObjectIdentity(account: session.configuration.account, bucket: request.destination.bucket, key: request.destination.key))
        }
        let allRecords = (session.catalogs.value(for: session.configuration.account)?.records ?? []) +
            session.listings.snapshots.values.flatMap { $0.value.files } +
            recentFiles.map { MetadataRecord(bucket: $0.bucket ?? request.source.bucket,
                key: $0.key, size: $0.size, modified: $0.lastModified, etag: $0.etag) }
        guard let source = allRecords.first(where: {
            $0.bucket.utf8.elementsEqual(request.source.bucket.utf8) && $0.key.utf8.elementsEqual(request.source.key.utf8)
        }) else {
            session.catalogs.invalidate(session.configuration.account)
            for query in session.listings.snapshots.keys { session.listings.invalidate(query) }
            return
        }
        let destination = MetadataRecord(bucket: request.destination.bucket, key: request.destination.key,
            size: source.size, modified: Date(), etag: source.etag, contentType: source.contentType)
        updateMetadata(destination, removedSource: request.kind == .copy ? nil : request.source)
    }

    private func updateMetadata(_ record: MetadataRecord, removedSource: TransferObjectLocation?) {
        func matches(_ candidate: MetadataRecord, bucket: String, key: String) -> Bool {
            candidate.bucket.utf8.elementsEqual(bucket.utf8) && candidate.key.utf8.elementsEqual(key.utf8)
        }
        let account = session.configuration.account
        var catalog = session.catalogs.value(for: account) ?? MetadataCatalogSnapshot(records: [],
            failedBuckets: [MetadataBucketFailure(bucket: "account catalog", message: "Awaiting a complete refresh")], refreshedAt: nil)
        catalog.records.removeAll { candidate in
            matches(candidate, bucket: record.bucket, key: record.key) ||
                removedSource.map { matches(candidate, bucket: $0.bucket, key: $0.key) } == true
        }
        catalog.records.append(record)
        if !catalog.buckets.contains(where: { $0.utf8.elementsEqual(record.bucket.utf8) }) { catalog.buckets.append(record.bucket) }
        session.catalogs.seed(catalog, for: account, refreshedAt: catalog.refreshedAt)
        if session.catalogs.isLoading(account) { session.catalogs.invalidate(account) }
        for (query, cached) in session.listings.snapshots {
            let old = cached.value
            var files = old.files.filter { candidate in
                !matches(candidate, bucket: record.bucket, key: record.key) &&
                    removedSource.map { !matches(candidate, bucket: $0.bucket, key: $0.key) } != false
            }
            var folders = old.folders
            if query.bucket.utf8.elementsEqual(record.bucket.utf8), record.key.utf8.starts(with: query.prefix.utf8) {
                if query.delimiter == nil || S3TransferKeys.parentPrefix(of: record.key).utf8.elementsEqual(query.prefix.utf8) {
                    files.append(record)
                } else {
                    let remaining = String(decoding: record.key.utf8.dropFirst(query.prefix.utf8.count), as: UTF8.self)
                    if let slash = remaining.firstIndex(of: "/") {
                        let folder = query.prefix + String(remaining[...slash])
                        if !folders.contains(where: { $0.utf8.elementsEqual(folder.utf8) }) { folders.append(folder) }
                    }
                }
            }
            session.listings.seed(MetadataListingPage(files: files, folders: folders, nextToken: old.nextToken),
                                  for: query, refreshedAt: cached.refreshedAt)
            if session.listings.isLoading(query) { session.listings.invalidate(query) }
        }
        recentFiles = (try? MetadataCatalogQuery.select(catalog, limit: recentSelectionLimit,
            matching: { recentSelectionFilter.matches($0.s3Object.fileType) }))?.map(\.s3Object) ?? []
        persistRecentFiles()
    }

    func annotationIdentity(for object: S3Object) -> LocalObjectIdentity {
        LocalObjectIdentity(account: session.configuration.account, bucket: object.bucket ?? currentBucket, key: object.key)
    }

    private func writeWidgetPreview() {
        let canonical = session.catalogs.value(for: session.configuration.account)
            .flatMap { try? MetadataCatalogQuery.select($0, limit: 50) }?.map(\.s3Object) ?? []
        guard let data = try? JSONEncoder().encode(canonical),
              let defaults = snapshotDefaults else { return }
        defaults.set(data, forKey: "recentUploads")
        defaults.set(session.configuration.account, forKey: "recentUploadsAccount.v1")
        if publishWidget { WidgetCenter.shared.reloadTimelines(ofKind: "TestS3BrowserWidget") }
    }
}

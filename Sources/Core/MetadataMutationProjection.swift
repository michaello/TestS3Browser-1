import Foundation

struct MetadataMutation: Sendable {
    let account: String
    let replacement: MetadataRecord?
    let removed: LocalObjectIdentity?
}

enum MetadataMutationProjection {
    static func matches(_ record: MetadataRecord, bucket: String, key: String) -> Bool {
        record.bucket.utf8.elementsEqual(bucket.utf8) && record.key.utf8.elementsEqual(key.utf8)
    }
    static func replacing(_ records: [MetadataRecord], with replacement: MetadataRecord?, removed: LocalObjectIdentity?) -> [MetadataRecord] {
        var result = records.filter { record in
            let replaced = replacement.map { matches(record, bucket: $0.bucket, key: $0.key) } ?? false
            let deleted = removed.map { matches(record, bucket: $0.bucket, key: $0.key) } ?? false
            return !replaced && !deleted
        }
        if let replacement { result.append(replacement) }
        return result
    }

    /// Publish a successful mutation only into the captured account and affected
    /// listing identities. Old network responses lose ownership before publication.
    @MainActor
    static func apply(_ mutation: MetadataMutation, currentAccount: String,
                      catalogs: ResourceLoader<String, MetadataCatalogSnapshot>,
                      listings: ResourceLoader<ListingQuery, MetadataListingPage>) -> MetadataCatalogSnapshot? {
        guard mutation.account.utf8.elementsEqual(currentAccount.utf8),
              mutation.removed.map({ $0.account.utf8.elementsEqual(currentAccount.utf8) }) ?? true else { return nil }
        var catalog = catalogs.value(for: currentAccount)
        if catalog == nil, mutation.replacement != nil {
            catalog = MetadataCatalogSnapshot(records: [], failedBuckets: [MetadataBucketFailure(bucket: "account catalog", message: "Awaiting a complete refresh")], refreshedAt: nil)
        }
        if var updated = catalog {
            updated.records = replacing(updated.records, with: mutation.replacement, removed: mutation.removed)
            if let replacement = mutation.replacement,
               !updated.buckets.contains(where: { $0.utf8.elementsEqual(replacement.bucket.utf8) }) { updated.buckets.append(replacement.bucket) }
            catalogs.cancel(currentAccount)
            catalogs.seed(updated, for: currentAccount, refreshedAt: updated.refreshedAt)
            catalog = updated
        }
        var queries = Set(listings.snapshots.keys)
        if let replacement = mutation.replacement, replacement.key.utf8.starts(with: "dump/".utf8) {
            queries.insert(ListingQuery(account: currentAccount, bucket: replacement.bucket, prefix: "dump/", delimiter: nil))
        }
        for query in queries {
            guard query.account.utf8.elementsEqual(currentAccount.utf8),
                  mutation.replacement.map({ query.bucket.utf8.elementsEqual($0.bucket.utf8) }) == true ||
                    mutation.removed.map({ query.bucket.utf8.elementsEqual($0.bucket.utf8) }) == true else { continue }
            let cached = listings.snapshots[query]
            let old = cached?.value ?? MetadataListingPage(files: [], folders: [], nextToken: nil)
            var files = replacing(old.files, with: nil, removed: mutation.removed)
            var folders = old.folders
            if let replacement = mutation.replacement {
                files.removeAll { matches($0, bucket: replacement.bucket, key: replacement.key) }
                if query.bucket.utf8.elementsEqual(replacement.bucket.utf8), replacement.key.utf8.starts(with: query.prefix.utf8) {
                    if query.delimiter == nil || S3TransferKeys.parentPrefix(of: replacement.key).utf8.elementsEqual(query.prefix.utf8) {
                        files.append(replacement)
                    } else {
                        let remaining = String(decoding: replacement.key.utf8.dropFirst(query.prefix.utf8.count), as: UTF8.self)
                        if let slash = remaining.firstIndex(of: "/") {
                            let folder = query.prefix + String(remaining[...slash])
                            if !folders.contains(where: { $0.utf8.elementsEqual(folder.utf8) }) { folders.append(folder) }
                        }
                    }
                }
            }
            if cached != nil { listings.cancel(query) }
            listings.seed(MetadataListingPage(files: files, folders: folders, nextToken: old.nextToken), for: query, refreshedAt: cached?.refreshedAt)
            if cached == nil, listings.isLoading(query) { listings.invalidate(query) }
        }
        return catalog
    }
}

import Foundation

@MainActor
struct ScreensIndexServiceTransport: ScreensIndexTransport {
    let service: S3Service
    let generation: UUID
    init(service: S3Service) { self.service = service; generation = service.session.generation }

    private func validate() throws {
        try Task.checkCancellation()
        guard service.session.isCurrent(generation) else { throw CancellationError() }
    }
    func folders(_ identity: MediaObjectIdentity, token: String?) async throws -> (prefixes: [String], nextToken: String?) {
        try validate()
        let query = ListingQuery(account: identity.account, bucket: identity.bucket, prefix: identity.key)
        let page = try await service.fetchPrefixMetadataPage(query, token: token)
        try validate()
        return (page.folders, page.nextToken)
    }
    func metadata(bucket: String, key: String) async throws -> MetadataRecord {
        try validate()
        let metadata = try await service.headObject(key: key, bucket: bucket)
        try validate()
        return MetadataRecord(bucket: bucket, key: key, size: Int64(metadata.contentLength ?? -1),
            modified: metadata.lastModified ?? .distantPast, etag: metadata.etag, contentType: metadata.contentType)
    }
    func manifest(_ metadata: MetadataRecord) async throws -> Data {
        try validate()
        let lease = try await service.downloadOriginalFile(for: metadata.s3Object)
        do {
            try validate()
            guard lease.bytes <= 2 * 1024 * 1024 else { throw ScreensIndexError.oversizedManifest }
            let data = try await MediaFileIO.shared.data(at: lease.url)
            await MediaOriginalStore.shared.release(lease)
            try validate()
            return data
        } catch { await MediaOriginalStore.shared.release(lease); throw error }
    }
}

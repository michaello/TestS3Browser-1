import Foundation
import AWSS3

extension S3Service {
    /// A bucket-specific caller cannot replace the shared all-account snapshot.
    @discardableResult
    func fetchRecentFiles(limit: Int = 20, force: Bool = false) async throws -> [S3Object] {
        let count = try RecentShortcutCount(limit)
        guard count.value > 0 else { return [] }
        let generation = session.generation
        let files = try await fetchFiles(prefix: "", bucket: currentBucket, force: force)
        guard session.isCurrent(generation) else { throw CancellationError() }
        return Array(files.prefix(count.value))
    }

    func selectRecentFiles(limit: Int = 50, typeFilter: FileTypeFilter = .all) {
        guard let snapshot = session.catalogs.value(for: session.configuration.account),
              let records = try? MetadataCatalogQuery.select(snapshot, limit: limit,
                  matching: { typeFilter.matches($0.s3Object.fileType) }) else { return }
        recentSelectionFilter = typeFilter
        recentSelectionLimit = limit
        recentFiles = records.map(\.s3Object)
    }

    func searchMetadata(_ query: String, limit: Int = 50) async throws -> [S3Object] {
        let snapshot = try await refreshMetadataCatalog()
        return try MetadataCatalogQuery.select(snapshot, limit: limit, search: query).map(\.s3Object)
    }

    /// Filter and limit locally after the shared full metadata catalog refresh.
    func fetchRecentFilesFromAllBuckets(limit: Int = 10, typeFilter: FileTypeFilter = .all,
                                       force: Bool = false) async throws {
        let count = try RecentShortcutCount(limit)
        guard count.value > 0 else { return }
        let requestID = recentRequest.begin()
        defer { recentRequest.finish(requestID) }
        recentSelectionFilter = typeFilter
        recentSelectionLimit = count.value
        selectRecentFiles(limit: count.value, typeFilter: typeFilter)
        let generation = session.generation
        let previousRefresh = session.catalogs.value(for: session.configuration.account)?.refreshedAt
        let snapshot = try await refreshMetadataCatalog(force: force)
        guard session.isCurrent(generation), recentRequest.owns(requestID) else { throw CancellationError() }
        if previousRefresh != snapshot.refreshedAt { recentRowsFromCache = false }
        recentFiles = try MetadataCatalogQuery.select(snapshot, limit: count.value,
            matching: { typeFilter.matches($0.s3Object.fileType) }).map(\.s3Object)
        persistRecentFiles()
    }

    func refreshMetadataCatalog(force: Bool = false) async throws -> MetadataCatalogSnapshot {
        let generation = session.generation
        let account = session.configuration.account
        let transport = try await metadataTransport(generation: generation)
        try await fetchAvailableBuckets(force: force)
        guard session.isCurrent(generation) else { throw CancellationError() }
        let buckets = availableBuckets
        let snapshot = try await session.catalogs.load(account, policy: force ? .force : .automatic) { [self] in
            let telemetry = AuditTelemetry.shared.beginRefresh()
            defer { AuditTelemetry.shared.finishRefresh(telemetry) }
            let previous = session.catalogs.value(for: account)
            return try await MetadataCatalogScanner.refresh(buckets: buckets, previous: previous, transport: transport)
        }
        guard session.isCurrent(generation) else { throw CancellationError() }
        persistRecentFiles()
        return session.catalogs.value(for: account) ?? snapshot
    }

    /// Reports are paginated through the same account/query-owned resource loader.
    func fetchStashReports(bucket: String = "phone-stash", limit: Int = 100, force: Bool = false) async throws -> [S3Object] {
        let count = try RecentShortcutCount(limit)
        guard count.value > 0 else { return [] }
        let files = try await fetchFileMetadata(prefix: "reports/", bucket: bucket, force: force)
        return try MetadataCatalogQuery.newestReports(files, limit: count.value).map(\.s3Object)
    }
}

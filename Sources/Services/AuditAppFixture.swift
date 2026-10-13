import Foundation

/// Opt-in process-only fixture boundaries. The actual app views/service remain in use.
@MainActor
enum AuditAppFixture {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["S3BROWSER_AUDIT_FIXTURE"] == "1" }
    static var caseName: String {
        let requested = ProcessInfo.processInfo.environment["S3BROWSER_AUDIT_CASE"] ?? "run"
        return ["cache-success", "offline", "scrolling", "selection", "run"].contains(requested) ? requested : "run"
    }
    static let config = S3Config(bucketName: "audit-bucket", region: "us-east-1", accessKey: "AUDIT_DUMMY_KEY", secretKey: "AUDIT_DUMMY_SECRET", prefix: "")

    static func service() -> S3Service {
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? FileManager.default.removeItem(at: documents.appendingPathComponent("audit-runtime-\(caseName).json"))
        }
        let suite = "s3browser-audit-fixture-v1"
        guard let defaults = UserDefaults(suiteName: suite) else { preconditionFailure("Fixture defaults unavailable") }
        defaults.removePersistentDomain(forName: suite)
        let account = S3AccountScope.identifier(region: config.region, accessKey: config.accessKey)
        let cached = MetadataRecord(bucket: config.bucketName, key: "audit-cache-first.txt", size: 24, modified: Date(timeIntervalSince1970: 1), etag: "cached")
        let rows = (0..<80).map { MetadataRecord(bucket: config.bucketName, key: "audit-cached-\($0).txt", size: 24, modified: Date(timeIntervalSince1970: 0), etag: "fixture") }
        let snapshot = MetadataCatalogSnapshot(records: [cached] + rows, failedBuckets: [], refreshedAt: nil, buckets: [config.bucketName])
        do { try MetadataSnapshotStore(defaults: defaults).save(snapshot, account: account) }
        catch { preconditionFailure("Unable to seed isolated fixture store") }
        return S3Service(config: config, metadataTransport: AuditFixtureTransport(), bucketDiscovery: { [config.bucketName] }, snapshotDefaults: defaults, publishWidget: false)
    }
}

@MainActor
private final class AuditFixtureTransport: MetadataCatalogTransport {
    func page(bucket: String, prefix: String?, delimiter: String?, token: String?) async throws -> MetadataListingPage {
        try await Task.sleep(for: .seconds(3))
        if ProcessInfo.processInfo.environment["S3BROWSER_AUDIT_FAILURE"] == "1" { throw ResourceLoadError.failed("Synthetic offline refresh") }
        let record = MetadataRecord(bucket: bucket, key: "audit-refreshed.txt", size: 32, modified: Date(timeIntervalSince1970: 2), etag: "fresh")
        let rows = (0..<80).map { MetadataRecord(bucket: bucket, key: "audit-new-\($0).txt", size: 32, modified: Date(timeIntervalSince1970: 0), etag: "fixture") }
        return MetadataListingPage(files: [record] + rows, folders: [], nextToken: nil)
    }
}

import Foundation
import Testing
@testable import AuditCore

@MainActor
struct F32BucketCountCacheTests {
    @Test("Fresh complete catalog counts require no bucket listings on repeated presentation")
    func reuseCatalog() async {
        let fixture = CatalogFixture(), cache = BucketCountCache()
        let records = (0..<1_001).map { MetadataRecord(bucket: "bucket", key: "\($0)", size: 1, modified: .now, etag: nil) }
        let catalog = MetadataCatalogSnapshot(records: records, failedBuckets: [], refreshedAt: .now, buckets: ["bucket", "empty"])
        for _ in 0..<2 {
            let counts = await cache.load(account: "A", buckets: ["bucket", "empty"], catalog: catalog, transport: fixture)
            #expect(counts["bucket"]?.count == 1_001)
            #expect(counts["bucket"]?.truncated == false)
            #expect(counts["empty"]?.count == 0)
        }
        #expect(fixture.calls == 0)
    }

    @Test("Fresh first-page counts retain their truncation indication without a new request")
    func reuseTruncatedEstimate() async {
        var now = Date(timeIntervalSince1970: 1_000)
        let fixture = CatalogFixture(), cache = BucketCountCache(now: { now })
        fixture.pages["bucket"] = [(0..<1_000).map { MetadataRecord(bucket: "bucket", key: "\($0)", size: 1, modified: .now, etag: nil) }, []]
        let first = await cache.load(account: "A", buckets: ["bucket"], catalog: nil, transport: fixture)
        #expect(first["bucket"]?.count == 1_000 && first["bucket"]?.truncated == true)
        now += 59
        _ = await cache.load(account: "A", buckets: ["bucket"], catalog: nil, transport: fixture)
        #expect(fixture.calls == 1)
        now += 1
        _ = await cache.load(account: "A", buckets: ["bucket"], catalog: nil, transport: fixture)
        #expect(fixture.calls == 2)
    }

    @Test("Stale count scans run at most three at a time and a denial remains unavailable")
    func boundAndFailure() async throws {
        let fixture = CatalogFixture(), cache = BucketCountCache();fixture.gateEnabled = true
        fixture.failingBuckets = ["denied"]
        let buckets = ["denied"] + (0..<8).map { "bucket-\($0)" }
        let pending = Task { await cache.load(account: "A", buckets: buckets, catalog: nil, transport: fixture) }
        var started = fixture.started.stream.makeAsyncIterator()
        for _ in 0..<3 { _ = await started.next() }
        #expect(fixture.calls == 3 && fixture.active == 3)
        fixture.release();let counts = await pending.value
        #expect(fixture.maximumActive == 3)
        #expect(counts["denied"]?.count == nil)
        #expect(counts["denied"]?.error?.contains("denied") == true)
    }

    @Test("A failed refresh retains an earlier estimate with its error and cannot cross accounts")
    func failedRefreshAndAccountScope() async {
        var now = Date(timeIntervalSince1970: 1_000)
        let fixture = CatalogFixture(), cache = BucketCountCache(now: { now })
        fixture.pages["bucket"] = [[MetadataRecord(bucket: "bucket", key: "one", size: 1, modified: .now, etag: nil)]]
        _ = await cache.load(account: "A", buckets: ["bucket"], catalog: nil, transport: fixture)
        now += 61;fixture.failingBuckets = ["bucket"]
        let failed = await cache.load(account: "A", buckets: ["bucket"], catalog: nil, transport: fixture)
        #expect(failed["bucket"]?.count == 1 && failed["bucket"]?.error != nil)
        #expect(cache.cached(account: "B", bucket: "bucket", catalog: nil) == nil)
        cache.reset()
        #expect(cache.cached(account: "A", bucket: "bucket", catalog: nil) == nil)
    }
}

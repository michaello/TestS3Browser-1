import Foundation
import Testing
@testable import AuditCore

private func queryRecord(_ key: String, bucket: String = "bucket", time: Double = 1) -> MetadataRecord {
    MetadataRecord(bucket: bucket, key: key, size: 10, modified: Date(timeIntervalSince1970: time), etag: key)
}

@MainActor
struct F04SharedCatalogQueryTests {
    @Test("Type selections and Stats reuse one fully paginated account scan")
    func sharedScanAndLocalFilters() async throws {
        let fixture = CatalogFixture()
        fixture.pages["bucket"] = [(0..<1_001).map { queryRecord("old-\($0).txt", time: Double($0)) }, [queryRecord("newest.png", time: 2_000)]]
        let session = ServiceSession(configuration: ServiceConfiguration(account: "account", credentialRevision: "rev", bucket: "bucket", prefix: ""))
        let operation: @MainActor () async throws -> MetadataCatalogSnapshot = {
            try await MetadataCatalogScanner.refresh(buckets: ["bucket"], previous: nil, transport: fixture)
        }
        let recent = try await session.catalogs.load("account", operation: operation)
        #expect(try MetadataCatalogQuery.select(recent, limit: 50).first?.key == "newest.png")
        let text = try MetadataCatalogQuery.select(recent, limit: 50, matching: { $0.key.hasSuffix(".txt") })
        let image = try MetadataCatalogQuery.select(recent, limit: 50, matching: { $0.key.hasSuffix(".png") })
        let stats = try await session.catalogs.load("account", operation: operation)
        #expect(text.count == 50 && image.map(\.key) == ["newest.png"])
        #expect(stats.summaries.first?.count == 1_002)
        #expect(fixture.calls == 2)
        #expect(recent.records.count == 1_002)
    }

    @Test("Simultaneous consumers join one catalog refresh")
    func duplicateConsumersJoin() async throws {
        let fixture = CatalogFixture();fixture.gateEnabled = true
        fixture.pages["bucket"] = [[queryRecord("newest.txt")]]
        let loader = ResourceLoader<String, MetadataCatalogSnapshot>()
        let operation: @MainActor () async throws -> MetadataCatalogSnapshot = { try await MetadataCatalogScanner.refresh(buckets: ["bucket"], previous: nil, transport: fixture) }
        let first = Task { try await loader.load("account", operation: operation) }
        var started = fixture.started.stream.makeAsyncIterator();_ = await started.next()
        let second = Task { try await loader.load("account", operation: operation) }
        fixture.release()
        #expect(try await first.value.records.count == 1)
        #expect(try await second.value.records.count == 1)
        #expect(fixture.calls == 1)
    }
}

@MainActor
struct F06CanonicalCatalogTests {
    @Test("Filters, shortcut limits, widget limits and bucket navigation preserve full source")
    func consumerIsolation() throws {
        let suite = "s3-catalog-queries-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite));defer { defaults.removePersistentDomain(forName: suite) }
        let snapshot = MetadataCatalogSnapshot(records: (0..<75).map { queryRecord("\($0).txt", time: Double($0)) } + [queryRecord("image.png", bucket: "other", time: 100)], failedBuckets: [], refreshedAt: .now)
        let session = ServiceSession(configuration: ServiceConfiguration(account: "A", credentialRevision: "rev", bucket: "bucket", prefix: ""))
        session.catalogs.seed(snapshot, for: "A", refreshedAt: snapshot.refreshedAt)
        let store = MetadataSnapshotStore(defaults: defaults);try store.save(snapshot, account: "A")
        #expect(try MetadataCatalogQuery.select(snapshot, limit: 1).count == 1)
        #expect(try MetadataCatalogQuery.select(snapshot, limit: 50).count == 50)
        #expect(try MetadataCatalogQuery.select(snapshot, limit: 50, bucket: "other").map(\.key) == ["image.png"])
        session.selectRoute(bucket: "other", prefix: "new/")
        #expect(session.catalogs.value(for: "A")?.records.count == 76)
        #expect(store.load(account: "A")?.records.count == 76)
        #expect(store.load(account: "B") == nil)
    }

    @Test("Equal filenames and canonically equivalent Unicode keys remain separate records")
    func exactIdentity() throws {
        let source = MetadataCatalogSnapshot(records: [queryRecord("same.txt", bucket: "a"), queryRecord("same.txt", bucket: "b"), queryRecord("caf\u{e9}.txt"), queryRecord("cafe\u{301}.txt")], failedBuckets: [], refreshedAt: .now)
        #expect(try MetadataCatalogQuery.select(source, limit: 50).count == 4)
        #expect(try MetadataCatalogQuery.select(source, limit: 50, bucket: "b").map(\.key) == ["same.txt"])
    }
}

struct F33FullCatalogSearchTests {
    @Test("Search includes an older match beyond the newest fifty and returns its bucket")
    func olderMatch() throws {
        let source = MetadataCatalogSnapshot(records: (0..<100).map { queryRecord("new-\($0).txt", time: Double($0 + 100)) } + [queryRecord("older-target.txt", bucket: "archive", time: 1)], failedBuckets: [], refreshedAt: .now)
        #expect(try MetadataCatalogQuery.select(source, limit: 50).allSatisfy { $0.key != "older-target.txt" })
        let found = try MetadataCatalogQuery.select(source, limit: 50, search: "TARGET")
        #expect(found.map(\.key) == ["older-target.txt"])
        #expect(found.first?.bucket == "archive")
        #expect(source.records.count == 101)
    }

    @Test("Limits apply after matching and negative limits fail")
    func limits() throws {
        let source = MetadataCatalogSnapshot(records: [queryRecord("target-a"), queryRecord("target-b"), queryRecord("unrelated", time: 10)], failedBuckets: [], refreshedAt: .now)
        #expect(try MetadataCatalogQuery.select(source, limit: 1, search: "target").count == 1)
        #expect(try MetadataCatalogQuery.select(source, limit: 0, search: "target").isEmpty)
        #expect(throws: RecentShortcutCountError.self) { try MetadataCatalogQuery.select(source, limit: -1) }
    }
}

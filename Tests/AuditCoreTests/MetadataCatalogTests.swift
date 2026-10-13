import Foundation
import Testing
@testable import AuditCore

@MainActor
final class CatalogFixture: MetadataCatalogTransport {
    var pages: [String: [[MetadataRecord]]] = [:]
    var failingBuckets: Set<String> = []
    var failingPage: [String: Int] = [:]
    var repeatedToken = false
    var active = 0
    var maximumActive = 0
    var calls = 0
    var gateEnabled = false
    var released = false
    var waiters: [CheckedContinuation<Void, Never>] = []
    let started = AsyncStream<String>.makeStream()

    func page(bucket: String, prefix: String?, delimiter: String?, token: String?) async throws -> MetadataListingPage {
        active += 1
        maximumActive = max(maximumActive, active)
        calls += 1
        defer { active -= 1 }
        started.continuation.yield(bucket)
        if gateEnabled, !released { await withCheckedContinuation { waiters.append($0) } }
        let index = token.flatMap(Int.init) ?? 0
        if failingBuckets.contains(bucket) || failingPage[bucket] == index { throw ResourceLoadError.failed("access denied") }
        let bucketPages = pages[bucket] ?? [[]]
        let files = bucketPages[min(index, bucketPages.count - 1)]
        let next = repeatedToken ? "1" : (index + 1 < bucketPages.count ? String(index + 1) : nil)
        return MetadataListingPage(files: files, folders: [], nextToken: next)
    }

    func release() {
        released = true
        let waiting = waiters
        waiters.removeAll()
        waiting.forEach { $0.resume() }
    }
}

private func record(_ bucket: String, _ key: String, size: Int64 = 10, seconds: TimeInterval = 1) -> MetadataRecord {
    MetadataRecord(bucket: bucket, key: key, size: size, modified: Date(timeIntervalSince1970: seconds), etag: key)
}

@MainActor
struct F05MetadataCatalogTests {
    @Test("A failed bucket retains its previous complete rows and totals are incomplete")
    func partialRefresh() async throws {
        let fixture = CatalogFixture()
        fixture.pages["good"] = [[record("good", "fresh.txt", size: 20)]]
        fixture.failingBuckets = ["failed"]
        let previous = MetadataCatalogSnapshot(records: [record("good", "old.txt"), record("failed", "keep.txt", size: 30)],
                                               failedBuckets: [], refreshedAt: .distantPast)
        let snapshot = try await MetadataCatalogScanner.refresh(buckets: ["good", "failed"], previous: previous, transport: fixture)
        #expect(snapshot.records.map(\.key).sorted() == ["fresh.txt", "keep.txt"])
        #expect(snapshot.failedBuckets.map(\.bucket) == ["failed"])
        #expect(!snapshot.isComplete)
        #expect(snapshot.summaries.reduce(0) { $0 + $1.bytes } == 50)
        #expect(snapshot.summaries.allSatisfy { !$0.isComplete })
    }

    @Test("A failed later page cannot replace a bucket's good snapshot with partial rows")
    func failedLaterPage() async throws {
        let fixture = CatalogFixture()
        fixture.pages["good"] = [[]]
        fixture.pages["failed"] = [[record("failed", "partial.txt")], [record("failed", "unavailable.txt")]]
        fixture.failingPage["failed"] = 1
        let previous = MetadataCatalogSnapshot(records: [record("failed", "keep.txt")], failedBuckets: [], refreshedAt: .distantPast)
        let snapshot = try await MetadataCatalogScanner.refresh(buckets: ["good", "failed"], previous: previous, transport: fixture)
        #expect(snapshot.records.map(\.key) == ["keep.txt"])
        #expect(snapshot.failedBuckets.count == 1)
    }

    @Test("Zero successful buckets cannot replace or persist an empty snapshot")
    func allFailedRetainsPersisted() async throws {
        let suite = "s3-audit-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MetadataSnapshotStore(defaults: defaults)
        let previous = MetadataCatalogSnapshot(records: [record("bucket", "good.txt")], failedBuckets: [], refreshedAt: .distantPast)
        try store.save(previous, account: "account")
        let loader = ResourceLoader<String, MetadataCatalogSnapshot>()
        loader.seed(previous, for: "account", refreshedAt: nil)
        let fixture = CatalogFixture()
        fixture.failingBuckets = ["bucket"]
        await #expect(throws: MetadataCatalogError.self) {
            let result = try await loader.load("account", policy: .force) {
                try await MetadataCatalogScanner.refresh(buckets: ["bucket"], previous: previous, transport: fixture)
            }
            try store.save(result, account: "account")
        }
        #expect(loader.value(for: "account")?.records.first?.key == "good.txt")
        #expect(loader.error(for: "account")?.contains("incomplete") == true)
        #expect(store.load(account: "account")?.records.first?.key == "good.txt")
        #expect(store.load(account: "account")?.records.count == 1)
    }

    @Test("A disappearing bucket list does not erase last-good metadata")
    func emptyDiscoveryRetainsSnapshot() async {
        let fixture = CatalogFixture()
        let previous = MetadataCatalogSnapshot(records: [record("bucket", "good.txt")], failedBuckets: [], refreshedAt: .distantPast)
        await #expect(throws: MetadataCatalogError.self) {
            try await MetadataCatalogScanner.refresh(buckets: [], previous: previous, transport: fixture)
        }
        #expect(fixture.calls == 0)
    }

    @Test("All pages contribute to newest results and empty buckets remain in stats")
    func paginationAndEmptyBuckets() async throws {
        let fixture = CatalogFixture()
        let first = (0..<1_001).map { record("bucket", "old-\($0)", seconds: Double($0)) }
        fixture.pages["bucket"] = [first, [record("bucket", "newest.txt", seconds: 5_000)]]
        let snapshot = try await MetadataCatalogScanner.refresh(buckets: ["bucket", "empty"], previous: nil, transport: fixture)
        #expect(snapshot.records.count == 1_002)
        #expect(snapshot.records.max(by: { $0.modified < $1.modified })?.key == "newest.txt")
        #expect(snapshot.summaries.first(where: { $0.bucket == "empty" })?.count == 0)
        #expect(snapshot.isComplete)
    }

    @Test("Bucket scan concurrency stays at the declared limit of three")
    func boundedConcurrency() async throws {
        let fixture = CatalogFixture()
        fixture.gateEnabled = true
        let buckets = (0..<9).map { "bucket-\($0)" }
        var started = fixture.started.stream.makeAsyncIterator()
        let task = Task { try await MetadataCatalogScanner.refresh(buckets: buckets, previous: nil, transport: fixture) }
        for _ in 0..<3 { _ = await started.next() }
        #expect(fixture.active == 3)
        #expect(fixture.calls == 3)
        fixture.release()
        let snapshot = try await task.value
        #expect(fixture.maximumActive == 3)
        #expect(fixture.calls == 9)
        #expect(snapshot.isComplete)
    }
}

@MainActor
struct F09MetadataNamespaceTests {
    @Test("Legacy migration is claimed once and each account restores only its envelope")
    func migrationIsolation() throws {
        let suite = "s3-audit-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MetadataSnapshotStore(defaults: defaults)
        let legacy = [record("bucket", "account-A.txt")]
        #expect(try store.claimLegacy(legacy, account: "A")?.records.first?.key == "account-A.txt")
        #expect(try store.claimLegacy(legacy, account: "B") == nil)
        #expect(store.load(account: "B") == nil)
        let b = MetadataCatalogSnapshot(records: [record("bucket", "account-B.txt")], failedBuckets: [], refreshedAt: .now)
        try store.save(b, account: "B")
        #expect(store.load(account: "A")?.records.first?.key == "account-A.txt")
        #expect(store.load(account: "B")?.records.first?.key == "account-B.txt")
    }

    @Test("A known active-account preview cannot be migrated into another account")
    func previewOwnerIsolation() throws {
        let suite = "s3-audit-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MetadataSnapshotStore(defaults: defaults)
        #expect(try store.claimLegacy([record("bucket", "A.txt")], account: "B", recordedAccount: "A") == nil)
        #expect(store.load(account: "B") == nil)
    }
}

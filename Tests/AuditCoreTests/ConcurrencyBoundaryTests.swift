import Foundation
import Testing
@testable import AuditCore

@MainActor
private final class ConcurrentLoaderFixture {
    let loader = ResourceLoader<Int, Int>()
    private(set) var calls: [Int: Int] = [:]
    func value(_ key: Int) async throws -> Int {
        try await loader.load(key) {
            self.calls[key, default: 0] += 1
            try await Task.sleep(for: .milliseconds(10))
            return key
        }
    }
}

private actor ConcurrentBodyFixture {
    private(set) var calls = 0
    func body() -> MediaDownloadBody {
        calls += 1
        let reader = MediaDataReader(Data(repeating: 42, count: 1_024))
        return MediaDownloadBody(expectedBytes: 1_024, read: { await reader.read() })
    }
}

struct F08ConcurrencyBoundaryTests {
    @Test("Simultaneous catalog and bucket-count consumers share three process-wide metadata permits")
    @MainActor
    func mixedMetadataConsumersStayBounded() async throws {
        let fixture = CatalogFixture();fixture.gateEnabled = true
        let limited = LimitedMetadataCatalogTransport(base: fixture), counts = BucketCountCache()
        let catalog = Task { try await MetadataCatalogScanner.refresh(buckets: ["a", "b", "c", "d"], previous: nil, transport: limited) }
        let switcher = Task { await counts.load(account: "account", buckets: ["e", "f", "g", "h"], catalog: nil, transport: limited) }
        var started = fixture.started.stream.makeAsyncIterator()
        for _ in 0..<3 { _ = await started.next() }
        #expect(fixture.active == 3 && fixture.calls == 3)
        fixture.release()
        #expect(try await catalog.value.isComplete)
        #expect(await switcher.value.count == 4)
        #expect(fixture.calls == 8 && fixture.maximumActive == 3)
    }

    @Test("Eighty concurrent callers cross MainActor ownership and join one load per key")
    func concurrentLoaderRequests() async throws {
        let fixture = await ConcurrentLoaderFixture()
        let values = try await withThrowingTaskGroup(of: Int.self, returning: [Int].self) { group in
            for index in 0..<80 { group.addTask { try await fixture.value(index % 8) } }
            var values: [Int] = []
            for try await value in group { values.append(value) }
            return values
        }
        #expect(values.count == 80)
        #expect(Set(values) == Set(0..<8))
        #expect(await fixture.calls.values.allSatisfy { $0 == 1 })
        #expect(await fixture.loader.snapshots.count == 8)
    }

    @Test("Concurrent file consumers share one actor-owned transfer and receive independent leases")
    func concurrentOriginalRequests() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("s3-concurrency-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MediaOriginalStore(directory: directory), fixture = ConcurrentBodyFixture()
        let identity = MediaObjectIdentity(account: "fixture", bucket: "bucket", key: "same.bin")
        let leases = try await withThrowingTaskGroup(of: OriginalFileLease.self, returning: [OriginalFileLease].self) { group in
            for _ in 0..<32 {
                group.addTask { try await store.file(for: identity, knownBytes: 1_024) { await fixture.body() } }
            }
            var values: [OriginalFileLease] = []
            for try await value in group { values.append(value) }
            return values
        }
        #expect(await fixture.calls == 1)
        #expect(Set(leases.map(\.id)).count == 32)
        #expect(Set(leases.map(\.url)).count == 1)
        #expect(try Data(contentsOf: #require(leases.first?.url)) == Data(repeating: 42, count: 1_024))
        for lease in leases { await store.release(lease) }
        try await store.clear()
    }

    @Test("An old account completion cannot publish into newly isolated observed state")
    @MainActor
    func staleGeneration() async throws {
        let original = ServiceConfiguration(account: "A", credentialRevision: "rev", bucket: "bucket", prefix: "")
        let session = ServiceSession(configuration: original), controlled = ControlledListing()
        let query = session.route, generation = session.generation
        let pending = Task { try await session.listings.load(query) { try await controlled.load() } }
        var started = controlled.started.stream.makeAsyncIterator();_ = await started.next()
        session.apply(ServiceConfiguration(account: "B", credentialRevision: "new", bucket: "bucket", prefix: ""))
        controlled.succeed(1, key: "old-private")
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(!session.isCurrent(generation))
        #expect(session.listings.value(for: query) == nil && session.listings.value(for: session.route) == nil)
    }
}

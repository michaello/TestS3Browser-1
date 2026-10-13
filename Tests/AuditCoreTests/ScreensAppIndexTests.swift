import Foundation
import Testing
@testable import AuditCore

@MainActor
private final class IndexFixtureTransport: ScreensIndexTransport {
    var keys: [String]
    var etags: [String: String] = [:]
    var denied: Set<String> = []
    var invalid: Set<String> = []
    var blockManifests = false
    var blockFolders = false
    var folderFailure = false
    var pending: [String: CheckedContinuation<Void, Never>] = [:]
    var folderPending: CheckedContinuation<Void, Never>?
    let started = AsyncStream<String>.makeStream()
    let foldersStarted = AsyncStream<Void>.makeStream()
    private(set) var manifestReads = 0
    private(set) var coverHeads = 0
    private(set) var active = 0
    private(set) var maximum = 0
    private(set) var folderReads = 0
    init(_ count: Int) { keys = (0..<count).map { "screensdesign/apps/app\($0)/app.json" } }
    func folders(_ identity: MediaObjectIdentity, token: String?) async throws -> (prefixes: [String], nextToken: String?) {
        folderReads += 1
        if blockFolders {
            await withCheckedContinuation { continuation in
                folderPending = continuation; foldersStarted.continuation.yield(())
            }
        }
        if folderFailure { throw ResourceLoadError.failed("listing offline") }
        return (keys.map { String($0.dropLast("app.json".count)) }, nil)
    }
    func metadata(bucket: String, key: String) async throws -> MetadataRecord {
        if key.hasSuffix("webp") { coverHeads += 1 }
        if denied.contains(key) { throw ResourceLoadError.failed("manifest denied") }
        return MetadataRecord(bucket: bucket, key: key, size: 100, modified: .distantPast, etag: etags[key] ?? "v1")
    }
    func manifest(_ metadata: MetadataRecord) async throws -> Data {
        manifestReads += 1; active += 1; maximum = max(maximum, active)
        defer { active -= 1 }
        if blockManifests {
            await withCheckedContinuation { continuation in
                pending[metadata.key] = continuation; started.continuation.yield(metadata.key)
            }
        }
        if invalid.contains(metadata.key) { return Data("{\"wrong\":true}".utf8) }
        let slug = metadata.key.split(separator: "/").dropLast().last.map(String.init) ?? "app"
        return try JSONEncoder().encode(indexApp(slug))
    }
    func release(_ key: String) { pending.removeValue(forKey: key)?.resume() }
    func releaseAll() { blockManifests = false; let waiters = pending.values; pending.removeAll(); waiters.forEach { $0.resume() } }
    func releaseFolders() { blockFolders = false; folderPending?.resume(); folderPending = nil }
}

private func indexApp(_ slug: String) -> ScreensDesignApp {
    ScreensDesignApp(slug: slug, name: slug, videos: [.init(key: "video", label: "Recording", frames: 3)], sourceURL: nil)
}
private func indexIdentity(_ account: String = "a", bucket: String = "bucket") -> MediaObjectIdentity {
    MediaObjectIdentity(account: account, bucket: bucket, key: "screensdesign/apps/")
}
private func savedIndex(_ count: Int = 1, at date: Date) -> ScreensIndexSnapshot {
    ScreensIndexSnapshot(entries: (0..<count).map { index in
        let slug = "app\(index)"
        let manifest = MetadataRecord(bucket: "bucket", key: "screensdesign/apps/\(slug)/app.json", size: 100, modified: .distantPast, etag: "v1")
        let cover = MetadataRecord(bucket: "bucket", key: "screensdesign/apps/\(slug)/video/screen-001.webp", size: 500, modified: .distantPast, etag: "cover-v1")
        return ScreensAppEntry(manifest: manifest, app: indexApp(slug), cover: cover)
    }, failures: [], refreshedAt: date)
}
private func indexTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("screens-index-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Suite("F28 cached bounded progressive Apps index", .timeLimit(.minutes(1)))
@MainActor
struct F28ScreensIndexTests {
    @Test("Launch reads scoped saved index before network and fresh revisits make no requests")
    func cachedLaunchAndFreshness() async throws {
        let directory = try indexTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScreensIndexDiskStore(directory: directory), identity = indexIdentity()
        var now = Date(timeIntervalSince1970: 100)
        try await store.save(savedIndex(at: now), identity: identity)
        let cache = ScreensAppIndexCache(store: store, now: { now }), transport = IndexFixtureTransport(1)
        await cache.load(identity, transport: transport)
        #expect(cache.value(for: identity)?.entries.first?.app.slug == "app0")
        #expect(transport.folderReads == 0)
        now = now.addingTimeInterval(61)
        transport.blockFolders = true
        var started = transport.foldersStarted.stream.makeAsyncIterator()
        let refresh = Task { await cache.load(identity, transport: transport) }
        _ = await started.next()
        #expect(cache.value(for: identity)?.entries.first?.app.slug == "app0")
        #expect(cache.isLoading(identity))
        transport.releaseFolders(); await refresh.value
        #expect(transport.folderReads == 1)
        #expect(transport.manifestReads == 0)
        await cache.load(identity, transport: transport)
        #expect(transport.folderReads == 1)
        #expect(await store.load(indexIdentity("other-account")) == nil)
        #expect(await store.load(indexIdentity(bucket: "other-bucket")) == nil)
    }

    @Test("Four manifest workers publish usable apps before delayed remaining manifests complete")
    func boundedProgressiveResults() async throws {
        let transport = IndexFixtureTransport(9); transport.blockManifests = true
        var started = transport.started.stream.makeAsyncIterator(), published: [ScreensIndexSnapshot] = []
        let work = Task { try await ScreensIndexScanner.refresh(indexIdentity(), previous: nil, transport: transport) { published.append($0) } }
        var keys: [String] = []
        for _ in 0..<4 { if let key = await started.next() { keys.append(key) } }
        #expect(transport.active == 4)
        #expect(transport.maximum == 4)
        transport.release(try #require(keys.first))
        _ = await started.next()
        #expect(published.contains { !$0.entries.isEmpty })
        #expect(transport.active == 4)
        transport.releaseAll()
        let result = try await work.value
        #expect(result.entries.count == 9)
        #expect(result.isComplete)
        #expect(transport.maximum == 4)
        #expect(published.first?.entries.count == 1)
        #expect(result.entries.allSatisfy { $0.cover?.etag == "v1" })
    }

    @Test("Unchanged ETags reuse decoded manifests and cover metadata; only changed manifest downloads")
    func unchangedManifestAndCoverReuse() async throws {
        let previous = savedIndex(3, at: .now), transport = IndexFixtureTransport(3)
        let unchanged = try await ScreensIndexScanner.refresh(indexIdentity(), previous: previous, transport: transport)
        #expect(unchanged.entries.count == 3)
        #expect(transport.manifestReads == 0)
        #expect(transport.coverHeads == 0)
        #expect(unchanged.entries.first?.cover?.etag == "cover-v1")
        transport.etags[transport.keys[1]] = "v2"
        let changed = try await ScreensIndexScanner.refresh(indexIdentity(), previous: unchanged, transport: transport)
        #expect(transport.manifestReads == 1)
        #expect(transport.coverHeads == 1)
        #expect(changed.entries.first { $0.app.slug == "app1" }?.manifest.etag == "v2")
    }

    @Test("Stale cover revision is refreshed without re-downloading an unchanged manifest")
    func staleCoverRevision() async throws {
        let transport = IndexFixtureTransport(1), now = Date(timeIntervalSince1970: 100)
        let previous = savedIndex(at: now.addingTimeInterval(-61))
        transport.etags["screensdesign/apps/app0/video/screen-001.webp"] = "cover-v2"
        let refreshed = try await ScreensIndexScanner.refresh(indexIdentity(), previous: previous, transport: transport, now: now)
        #expect(transport.manifestReads == 0)
        #expect(transport.coverHeads == 1)
        #expect(refreshed.entries.first?.cover?.etag == "cover-v2")
    }

    @Test("Generation reset prevents suspended app manifests from repopulating memory or saved index")
    func resetRejectsLateManifest() async throws {
        let directory = try indexTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScreensIndexDiskStore(directory: directory), cache = ScreensAppIndexCache(store: store)
        let transport = IndexFixtureTransport(1); transport.blockManifests = true
        var started = transport.started.stream.makeAsyncIterator()
        let request = Task { await cache.load(indexIdentity(), transport: transport) }
        _ = await started.next()
        cache.reset(); transport.releaseAll(); await request.value
        #expect(cache.value(for: indexIdentity()) == nil)
        #expect(await store.load(indexIdentity()) == nil)
    }
}

@Suite("N40 explicit Apps manifest failure states", .timeLimit(.minutes(1)))
@MainActor
struct N40ManifestFailureTests {
    @Test("A failed manifest retains its known cached entry and marks the mixed index incomplete")
    func partialFailureRetainsKnownEntry() async throws {
        let transport = IndexFixtureTransport(3), previous = savedIndex(3, at: .distantPast)
        transport.denied.insert(transport.keys[0]); transport.etags[transport.keys[1]] = "v2"
        let snapshot = try await ScreensIndexScanner.refresh(indexIdentity(), previous: previous, transport: transport)
        #expect(snapshot.entries.count == 3)
        #expect(snapshot.failures.count == 1)
        #expect(snapshot.isComplete == false)
        #expect(snapshot.entries.first { $0.app.slug == "app0" }?.manifest.etag == "v1")
        #expect(snapshot.entries.first { $0.app.slug == "app1" }?.manifest.etag == "v2")
    }

    @Test("All GET/decode failures are unavailable with retry, never a successful empty Apps index")
    func allFailuresThenRetry() async throws {
        let directory = try indexTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ScreensAppIndexCache(store: ScreensIndexDiskStore(directory: directory)), transport = IndexFixtureTransport(2)
        transport.denied.insert(transport.keys[0]); transport.invalid.insert(transport.keys[1])
        await cache.load(indexIdentity(), transport: transport)
        #expect(cache.error(indexIdentity())?.contains("Apps unavailable") == true)
        #expect(cache.value(for: indexIdentity())?.failures.count == 2)
        #expect(cache.value(for: indexIdentity())?.isComplete == false)
        #expect(cache.isLoading(indexIdentity()) == false)
        transport.denied.removeAll(); transport.invalid.removeAll()
        await cache.load(indexIdentity(), force: true, transport: transport)
        #expect(cache.error(indexIdentity()) == nil)
        #expect(cache.value(for: indexIdentity())?.entries.count == 2)
        #expect(cache.value(for: indexIdentity())?.isComplete == true)
    }

    @Test("A genuinely empty listing is complete, while all-failure refresh keeps saved entries")
    func emptyAndCachedFailureAreDistinct() async throws {
        let empty = try await ScreensIndexScanner.refresh(indexIdentity(), previous: nil, transport: IndexFixtureTransport(0))
        #expect(empty.entries.isEmpty)
        #expect(empty.isComplete)
        let directory = try indexTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScreensIndexDiskStore(directory: directory)
        try await store.save(savedIndex(at: .distantPast), identity: indexIdentity())
        let cache = ScreensAppIndexCache(store: store), denied = IndexFixtureTransport(1)
        denied.denied.insert(denied.keys[0])
        await cache.load(indexIdentity(), transport: denied)
        #expect(cache.value(for: indexIdentity())?.entries.count == 1)
        #expect(cache.error(indexIdentity()) != nil)
        #expect(cache.value(for: indexIdentity())?.isComplete == false)
        #expect(await store.load(indexIdentity())?.entries.count == 1)
    }
}

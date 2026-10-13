import Foundation
import Testing
@testable import AuditCore

@MainActor
private final class DetailTestGate<Value: Sendable> {
    private var waiting: CheckedContinuation<Value, Error>?
    let started = AsyncStream<Void>.makeStream()
    func wait() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            waiting = continuation
            started.continuation.yield(())
        }
    }
    func finish(_ value: Value) { waiting?.resume(returning: value); waiting = nil }
    func fail() { waiting?.resume(throwing: ResourceLoadError.failed("fixture unavailable")); waiting = nil }
}

@Suite("F16 requested detail scheduling and shared freshness", .timeLimit(.minutes(1)))
@MainActor
struct F16DetailDemandTests {
    @Test("Initial HTML schedules content only; standard metadata follows visible content")
    func visiblePriority() async throws {
        var events: [String] = []
        await DetailLoadSchedule.initial(isHTML: true, content: { events.append("html") }, metadata: { events.append("metadata") })
        #expect(events == ["html"])
        let gate = DetailTestGate<Void>()
        var started = gate.started.stream.makeAsyncIterator()
        let task = Task {
            await DetailLoadSchedule.initial(isHTML: false, content: {
                events.append("content-start")
                _ = try? await gate.wait()
                events.append("content-visible")
            }, metadata: { events.append("metadata") })
        }
        _ = await started.next()
        #expect(events == ["html", "content-start"])
        gate.finish(())
        await task.value
        #expect(events == ["html", "content-start", "content-visible", "metadata"])
    }

    @Test("Hidden sections do no I/O; requested object and bucket sections reuse fresh exact identities")
    func demandAndFreshness() async throws {
        var now = Date(timeIntervalSince1970: 100), calls = 0
        let cache = DetailSecondaryCache<String>(now: { now })
        let object = MediaObjectIdentity(account: "a", bucket: "b", key: "report.html", etag: "1")
        for section in [DetailSection.versions, .tags, .permissions] {
            let hidden = try await cache.load(DetailResourceKey(object: object, section: section), requested: false) {
                calls += 1; return "hidden"
            }
            #expect(hidden == nil)
        }
        #expect(calls == 0)
        let metadata = DetailResourceKey(object: object, section: .metadata)
        #expect(try await cache.load(metadata) { calls += 1; return "header" } == "header")
        now = now.addingTimeInterval(59)
        #expect(try await cache.load(metadata) { calls += 1; return "duplicate" } == "header")
        #expect(calls == 1)
        now = now.addingTimeInterval(1)
        #expect(try await cache.load(metadata) { calls += 1; return "fresh-header" } == "fresh-header")
        #expect(calls == 2)
        let bucketRules = DetailResourceKey(object: object, section: .lifecycle)
        let sameBucketRules = DetailResourceKey(object: MediaObjectIdentity(account: "a", bucket: "b", key: "other.png", etag: "9"), section: .lifecycle)
        #expect(bucketRules == sameBucketRules)
        _ = try await cache.load(bucketRules) { calls += 1; return "rules" }
        #expect(try await cache.load(sameBucketRules) { calls += 1; return "duplicate-rules" } == "rules")
        let anotherAccount = DetailResourceKey(object: MediaObjectIdentity(account: "c", bucket: "b", key: "report.html", etag: "1"), section: .metadata)
        #expect(try await cache.load(anotherAccount) { calls += 1; return "account-c" } == "account-c")
        #expect(calls == 4)
    }

    @Test("Concurrent demand coalesces; eviction and mutation reject obsolete secondary responses")
    func boundedAndInvalidated() async throws {
        let cache = DetailSecondaryCache<String>(capacity: 2)
        let identity = MediaObjectIdentity(account: "a", bucket: "b", key: "file", etag: "1")
        let key = DetailResourceKey(object: identity, section: .tags)
        let gate = DetailTestGate<String>()
        var started = gate.started.stream.makeAsyncIterator(), calls = 0
        let first = Task { try await cache.load(key) { calls += 1; return try await gate.wait() } }
        _ = await started.next()
        let second = Task { try await cache.load(key) { calls += 1; return "duplicate" } }
        await Task.yield()
        gate.finish("tags")
        #expect(try await first.value == "tags")
        #expect(try await second.value == "tags")
        #expect(calls == 1)
        for section in [DetailSection.metadata, .versions] {
            _ = try await cache.load(DetailResourceKey(object: identity, section: section)) { "value" }
        }
        #expect(cache.count == 2)
        #expect(cache.value(for: key) == nil)
        let old = DetailTestGate<String>()
        var oldStarted = old.started.stream.makeAsyncIterator()
        let obsolete = Task { try await cache.load(key) { try await old.wait() } }
        _ = await oldStarted.next()
        cache.invalidate(account: "a", bucket: "b", key: "file")
        old.finish("obsolete tags")
        await #expect(throws: CancellationError.self) { try await obsolete.value }
        #expect(cache.value(for: key) == nil)
        #expect(try await cache.load(key) { "current tags" } == "current tags")
    }

    @Test("Failure keeps successful metadata; explicit retry bypasses automatic failure throttle")
    func failureAndRetry() async throws {
        let cache = DetailSecondaryCache<String>()
        let key = DetailResourceKey(object: MediaObjectIdentity(account: "a", bucket: "b", key: "file"), section: .metadata)
        _ = try await cache.load(key) { "saved" }
        await #expect(throws: ResourceLoadError.self) {
            try await cache.load(key, force: true) { throw ResourceLoadError.failed("offline") }
        }
        #expect(cache.value(for: key) == "saved")
        #expect(try await cache.load(key, force: true) { "recovered" } == "recovered")
        cache.reset()
        #expect(cache.count == 0)
    }
}

private func framePage(_ key: String, token: String?) -> MetadataListingPage {
    MetadataListingPage(files: [MetadataRecord(bucket: "bucket", key: key, size: 1, modified: .distantPast, etag: "1")], folders: [], nextToken: token)
}

@Suite("N38 terminal metadata read presentation", .timeLimit(.minutes(1)))
@MainActor
struct N38MetadataFailureTests {
    @Test("Failed HEAD ends loading with retry; successful retry replaces failure")
    func failureThenRetry() async {
        let state = DetailMetadataLoadState<String>()
        #expect(state.phase == .idle)
        await state.load { throw ResourceLoadError.failed("HEAD unavailable") }
        #expect(state.isLoading == false)
        #expect(state.error == "HEAD unavailable")
        #expect(state.value == nil)
        await state.load { "metadata" }
        #expect(state.phase == .loaded)
        #expect(state.error == nil)
        #expect(state.value == "metadata")
    }

    @Test("Nil successful metadata is an explicit empty terminal state")
    func emptyAndCancelled() async {
        let state = DetailMetadataLoadState<String>()
        await state.load { nil }
        #expect(state.phase == .empty)
        #expect(state.isLoading == false)
        await state.load { throw CancellationError() }
        #expect(state.phase == .idle)
        #expect(state.isLoading == false)
        #expect(state.error == nil)
    }

    @Test("Older failures cannot replace a newer successful HEAD or clear its request ownership")
    func obsoleteFailure() async {
        let state = DetailMetadataLoadState<String>(), gate = DetailTestGate<String>()
        var started = gate.started.stream.makeAsyncIterator()
        let old = Task { await state.load { try await gate.wait() } }
        _ = await started.next()
        #expect(state.isLoading)
        await state.load { "new metadata" }
        gate.fail(); await old.value
        #expect(state.value == "new metadata")
        #expect(state.phase == .loaded)
        #expect(state.error == nil)
    }
}

@Suite("F23 frame refresh owns rows and continuation", .timeLimit(.minutes(1)))
@MainActor
struct F23FramesRefreshTests {
    @Test("Refreshing during delayed page two retains page one until replacement and rejects old token")
    func replacesObsoletePagination() async throws {
        let state = PagedListingState()
        let query = ListingQuery(account: "a", bucket: "bucket", prefix: "screensdesign/apps/app/recording/")
        try await state.reload(query) { _ in framePage("screen-001.webp", token: "page-two") }
        let pageTwo = DetailTestGate<MetadataListingPage>(), refresh = DetailTestGate<MetadataListingPage>()
        var pageStarted = pageTwo.started.stream.makeAsyncIterator(), refreshStarted = refresh.started.stream.makeAsyncIterator()
        let old = Task { try await state.loadMore { token in
            #expect(token == "page-two")
            return try await pageTwo.wait()
        } }
        _ = await pageStarted.next()
        var firstPageRequests = 0
        let latest = Task { try await state.reload(query, force: true) { token in
            #expect(token == nil)
            firstPageRequests += 1
            return try await refresh.wait()
        } }
        _ = await refreshStarted.next()
        #expect(state.page?.files.map(\.key) == ["screen-001.webp"])
        #expect(state.isLoadingMore == false)
        pageTwo.finish(framePage("obsolete-screen-002.webp", token: "obsolete-token"))
        await #expect(throws: CancellationError.self) { try await old.value }
        #expect(state.page?.files.map(\.key) == ["screen-001.webp"])
        refresh.finish(framePage("fresh-screen-001.webp", token: "fresh-page-two"))
        try await latest.value
        #expect(firstPageRequests == 1)
        #expect(state.page?.files.map(\.key) == ["fresh-screen-001.webp"])
        #expect(state.page?.nextToken == "fresh-page-two")
        #expect(state.isLoading == false)
    }

    @Test("Failed replacement preserves frames and an explicit refresh can retry immediately")
    func failedRefreshRetainsFrames() async throws {
        let state = PagedListingState()
        let query = ListingQuery(account: "a", bucket: "bucket", prefix: "frames/")
        try await state.reload(query) { _ in framePage("saved.webp", token: "next") }
        await #expect(throws: ResourceLoadError.self) {
            try await state.reload(query, force: true) { _ in throw ResourceLoadError.failed("offline") }
        }
        #expect(state.page?.files.map(\.key) == ["saved.webp"])
        #expect(state.error != nil)
        try await state.reload(query, force: true) { _ in framePage("retry.webp", token: nil) }
        #expect(state.page?.files.map(\.key) == ["retry.webp"])
        #expect(state.error == nil)
    }

    @Test("Changing frame account or prefix rejects a non-cooperative old page")
    func changedQueryRejectsOld() async throws {
        let state = PagedListingState()
        let first = ListingQuery(account: "a", bucket: "bucket", prefix: "frames/")
        let replacement = ListingQuery(account: "b", bucket: "bucket", prefix: "new-frames/")
        try await state.reload(first) { _ in framePage("old-first.webp", token: "next") }
        let gate = DetailTestGate<MetadataListingPage>()
        var started = gate.started.stream.makeAsyncIterator()
        let old = Task { try await state.loadMore { _ in try await gate.wait() } }
        _ = await started.next()
        try await state.reload(replacement) { _ in framePage("new-account.webp", token: "new-next") }
        gate.finish(framePage("wrong-account.webp", token: nil))
        await #expect(throws: CancellationError.self) { try await old.value }
        #expect(state.page?.files.map(\.key) == ["new-account.webp"])
        #expect(state.page?.nextToken == "new-next")
    }
}

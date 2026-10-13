import Foundation
import Testing
@testable import AuditCore

@MainActor
struct F01CachedRecentTests {
    @Test("Cached rows render before delayed transport and remain visible after failure")
    func cachedRowsRemainVisible() async throws {
        let loader = ResourceLoader<String, MetadataListingPage>()
        let snapshot = MetadataListingPage(files: [MetadataRecord(bucket: "bucket", key: "saved.txt", size: 1,
            modified: .distantPast, etag: nil)], folders: [], nextToken: nil)
        loader.seed(snapshot, for: "account", refreshedAt: nil)
        let controlled = ControlledListing()
        var started = controlled.started.stream.makeAsyncIterator()
        let refresh = Task { try await loader.load("account") { try await controlled.load() } }
        _ = await started.next()
        #expect(loader.isLoading("account"))
        #expect(loader.value(for: "account")?.files.first?.key == "saved.txt")
        #expect(!CachedRowsPresentation.showsInitialLoading(rowCount: loader.value(for: "account")!.files.count,
            hasLoadedOnce: false, isRefreshing: loader.isLoading("account")))
        controlled.fail(1)
        await #expect(throws: ResourceLoadError.self) { try await refresh.value }
        #expect(loader.value(for: "account")?.files.first?.key == "saved.txt")
        #expect(loader.error(for: "account") == "offline")
        #expect(!CachedRowsPresentation.showsInitialLoading(rowCount: 1, hasLoadedOnce: false, isRefreshing: false))
    }

    @Test("An empty cold cache retains an explicit initial loading state")
    func emptyInitialLoading() {
        #expect(CachedRowsPresentation.showsInitialLoading(rowCount: 0, hasLoadedOnce: false, isRefreshing: false))
        #expect(CachedRowsPresentation.showsInitialLoading(rowCount: 0, hasLoadedOnce: true, isRefreshing: true))
        #expect(!CachedRowsPresentation.showsInitialLoading(rowCount: 0, hasLoadedOnce: true, isRefreshing: false))
    }
}

@MainActor
final class ControlledListing {
    let started = AsyncStream<Int>.makeStream()
    var pending: [Int: CheckedContinuation<MetadataListingPage, Error>] = [:]
    var calls = 0

    func load() async throws -> MetadataListingPage {
        calls += 1
        let call = calls
        return try await withCheckedThrowingContinuation { continuation in
            pending[call] = continuation
            started.continuation.yield(call)
        }
    }

    func succeed(_ call: Int, key: String) {
        pending.removeValue(forKey: call)?.resume(returning: MetadataListingPage(files: [
            MetadataRecord(bucket: "bucket", key: key, size: 1, modified: .distantPast, etag: nil)
        ], folders: [], nextToken: nil))
    }

    func fail(_ call: Int) { pending.removeValue(forKey: call)?.resume(throwing: ResourceLoadError.failed("offline")) }
}

@MainActor
private func configuration(_ account: String, bucket: String = "bucket", prefix: String = "") -> ServiceConfiguration {
    ServiceConfiguration(account: account, credentialRevision: "credentials-\(account)", bucket: bucket, prefix: prefix)
}

@MainActor
struct F09ServiceSessionTests {
    @Test("Applying configuration changes namespace, route and request ownership together")
    func atomicConfiguration() {
        let session = ServiceSession(configuration: configuration("account-A", prefix: "old//"))
        let original = session.generation
        session.bucketChoices.seed(["old-bucket"], for: "account-A", refreshedAt: .now)
        session.catalogs.seed(MetadataCatalogSnapshot(records: [], failedBuckets: [], refreshedAt: .now),
                              for: "account-A", refreshedAt: .now)
        #expect(session.apply(configuration("account-B", bucket: "new-bucket", prefix: "new//")))
        #expect(session.generation != original)
        #expect(session.route == ListingQuery(account: "account-B", bucket: "new-bucket", prefix: "new//"))
        #expect(session.bucketChoices.value(for: "account-A") == nil)
        #expect(session.bucketChoices.value(for: "account-B") == nil)
        #expect(session.catalogs.value(for: "account-A") == nil)
    }

    @Test("A cancelled account response cannot publish even if transport ignores cancellation")
    func staleAccountResponse() async throws {
        let session = ServiceSession(configuration: configuration("account-A"))
        let query = session.route
        let controlled = ControlledListing()
        var started = controlled.started.stream.makeAsyncIterator()
        let old = Task { try await session.listings.load(query) { try await controlled.load() } }
        #expect(await started.next() == 1)
        session.apply(configuration("account-B"))
        controlled.succeed(1, key: "old-secret.txt")
        await #expect(throws: CancellationError.self) { try await old.value }
        #expect(session.listings.value(for: query) == nil)
        #expect(session.listings.value(for: session.route) == nil)
        #expect(session.listings.error(for: session.route) == nil)
    }

    @Test("An identical config is idempotent and preserves generation and cached choices")
    func idempotentConfiguration() {
        let config = configuration("account-A")
        let session = ServiceSession(configuration: config)
        let original = session.generation
        session.bucketChoices.seed(["saved"], for: config.account, refreshedAt: .now)
        #expect(!session.apply(config))
        #expect(session.generation == original)
        #expect(session.bucketChoices.value(for: config.account) == ["saved"])
    }

    @Test("Exact Unicode queries and configuration routes retain byte identity")
    func unicodeIdentity() {
        let a = configuration("account", prefix: "caf\u{e9}/")
        let b = configuration("account", prefix: "cafe\u{301}/")
        #expect(a != b)
        let session = ServiceSession(configuration: a)
        let first = session.route
        session.apply(b)
        #expect(first != session.route)
        #expect(Set([first, session.route]).count == 2)
    }
}

@MainActor
struct F07ResourceOwnershipTests {
    @Test("Out-of-order folders and their loading flags remain request-owned")
    func navigationReplacement() async throws {
        let session = ServiceSession(configuration: configuration("account"))
        let controlled = ControlledListing()
        var started = controlled.started.stream.makeAsyncIterator()
        let first = session.route
        let old = Task { try await session.listings.load(first) { try await controlled.load() } }
        #expect(await started.next() == 1)
        session.selectRoute(bucket: "bucket", prefix: "new/")
        let second = session.route
        let new = Task { try await session.listings.load(second) { try await controlled.load() } }
        #expect(await started.next() == 2)
        controlled.fail(1)
        await #expect(throws: CancellationError.self) { try await old.value }
        #expect(session.listings.isLoading(second))
        #expect(session.listings.error(for: second) == nil)
        controlled.succeed(2, key: "new/file.txt")
        #expect(try await new.value.files.first?.key == "new/file.txt")
        #expect(!session.listings.isLoading(second))
        #expect(session.listings.value(for: first) == nil)
    }

    @Test("An explicit refresh during work schedules a replacement and both waiters receive it")
    func pendingRefresh() async throws {
        let loader = ResourceLoader<String, MetadataListingPage>()
        let controlled = ControlledListing()
        var started = controlled.started.stream.makeAsyncIterator()
        let first = Task { try await loader.load("query") { try await controlled.load() } }
        #expect(await started.next() == 1)
        let refreshStarted = AsyncStream<Void>.makeStream()
        let forced = Task {
            refreshStarted.continuation.yield(())
            return try await loader.load("query", policy: .force) { try await controlled.load() }
        }
        var refreshIterator = refreshStarted.stream.makeAsyncIterator()
        _ = await refreshIterator.next()
        controlled.succeed(1, key: "obsolete.txt")
        #expect(await started.next() == 2)
        #expect(loader.value(for: "query") == nil)
        controlled.succeed(2, key: "fresh.txt")
        #expect(try await first.value.files.first?.key == "fresh.txt")
        #expect(try await forced.value.files.first?.key == "fresh.txt")
        #expect(controlled.calls == 2)
    }

    @Test("Identical requests join without taking another resource's loading flag")
    func joinsDuplicates() async throws {
        let loader = ResourceLoader<String, MetadataListingPage>()
        let controlled = ControlledListing()
        var started = controlled.started.stream.makeAsyncIterator()
        let first = Task { try await loader.load("query") { try await controlled.load() } }
        _ = await started.next()
        let second = Task { try await loader.load("query") { try await controlled.load() } }
        controlled.succeed(1, key: "shared.txt")
        #expect(try await first.value.files.first?.key == "shared.txt")
        #expect(try await second.value.files.first?.key == "shared.txt")
        #expect(controlled.calls == 1)
        #expect(!loader.isLoading("query"))
    }

    @Test("Automatic refresh obeys 60 seconds and explicit refresh bypasses freshness")
    func freshness() async throws {
        var clock = Date(timeIntervalSince1970: 1_000)
        let loader = ResourceLoader<String, Int>(now: { clock })
        var calls = 0
        func operation() async -> Int { calls += 1; return calls }
        #expect(try await loader.load("query", operation: operation) == 1)
        clock += 59
        #expect(try await loader.load("query", operation: operation) == 1)
        #expect(calls == 1)
        clock += 1
        #expect(try await loader.load("query", operation: operation) == 2)
        #expect(try await loader.load("query", policy: .force, operation: operation) == 3)
    }

    @Test("An old account error cannot clear newer work or publish its message")
    func resetInvalidatesError() async throws {
        let loader = ResourceLoader<String, MetadataListingPage>()
        let controlled = ControlledListing()
        var started = controlled.started.stream.makeAsyncIterator()
        let old = Task { try await loader.load("same-query") { try await controlled.load() } }
        _ = await started.next()
        loader.reset()
        let new = Task { try await loader.load("same-query") { try await controlled.load() } }
        _ = await started.next()
        controlled.fail(1)
        await #expect(throws: CancellationError.self) { try await old.value }
        #expect(loader.isLoading("same-query"))
        #expect(loader.error(for: "same-query") == nil)
        controlled.succeed(2, key: "new-account.txt")
        _ = try await new.value
    }
}

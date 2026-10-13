import Foundation
import Testing
@testable import AuditCore

@MainActor
struct F02BrowseStartupTests {
    @Test("Saved folder lists once while bucket discovery remains suspended")
    func listingDoesNotWaitForDiscovery() async throws {
        let session = ServiceSession(configuration: ServiceConfiguration(account: "account", credentialRevision: "rev", bucket: "root", prefix: ""))
        let savedCatalog = MetadataCatalogSnapshot(records: [MetadataRecord(bucket: "elsewhere", key: "recent.txt", size: 1, modified: .now, etag: nil)], failedBuckets: [], refreshedAt: .now)
        session.catalogs.seed(savedCatalog, for: "account", refreshedAt: .now)
        let listed = AsyncStream<ListingQuery>.makeStream()
        let discoveryStarted = AsyncStream<Void>.makeStream()
        var releaseDiscovery: CheckedContinuation<Void, Never>?
        var calls: [ListingQuery] = []
        let task = Task {
            await session.restoreBrowse(bucket: "saved", prefix: "nested//folder/", listing: {
                let query = session.route;calls.append(query)
                session.listings.seed(MetadataListingPage(files: [], folders: [], nextToken: nil), for: query, refreshedAt: .now)
                listed.continuation.yield(query)
            }, discovery: {
                await withCheckedContinuation { continuation in
                    releaseDiscovery = continuation;discoveryStarted.continuation.yield(())
                }
            })
        }
        var listingIterator = listed.stream.makeAsyncIterator();let route = try #require(await listingIterator.next())
        var discoveryIterator = discoveryStarted.stream.makeAsyncIterator();_ = await discoveryIterator.next()
        #expect(route.bucket == "saved" && route.prefix == "nested//folder/")
        #expect(calls == [route])
        #expect(session.listings.value(for: route) != nil)
        #expect(session.catalogs.value(for: "account")?.records.first?.key == "recent.txt")
        releaseDiscovery?.resume();await task.value
    }

    @Test("Restoring root does not perform an intermediate root request")
    func rootIsListedOnce() async {
        let session = ServiceSession(configuration: ServiceConfiguration(account: "account", credentialRevision: "rev", bucket: "initial", prefix: "old/"))
        var calls: [ListingQuery] = []
        await session.restoreBrowse(bucket: "saved", prefix: "", listing: { calls.append(session.route) }, discovery: {})
        #expect(calls == [ListingQuery(account: "account", bucket: "saved", prefix: "")])
    }
}

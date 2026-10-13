import Foundation
import Testing
@testable import AuditCore

private func pageRecord(_ key: String, time: Double = 1) -> MetadataRecord {
    MetadataRecord(bucket: "bucket", key: key, size: 1, modified: Date(timeIntervalSince1970: time), etag: nil)
}
private let pageQuery = ListingQuery(account: "account", bucket: "bucket", prefix: "")

@MainActor
struct F20ListingPaginationTests {
    @Test("Browse publishes the first thousand rows before explicitly loading the next page")
    func incrementalBrowse() async throws {
        let session = ServiceSession(configuration: ServiceConfiguration(account: "account", credentialRevision: "rev", bucket: "bucket", prefix: ""))
        var tokens: [String?] = []
        let operation: @MainActor (String?) async -> MetadataListingPage = { token in
            tokens.append(token)
            return token == nil ? MetadataListingPage(files: (0..<1_000).map { pageRecord("old-\($0)") }, folders: [], nextToken: "later") : MetadataListingPage(files: [pageRecord("newest", time: 100)], folders: [], nextToken: nil)
        }
        try await session.browse.reload(pageQuery, operation: operation)
        #expect(tokens.count == 1 && tokens[0] == nil)
        #expect(session.listings.value(for: pageQuery)?.files.count == 1_000)
        #expect(session.browse.hasMore)
        try await session.browse.loadMore(operation: operation)
        #expect(tokens.count == 2 && tokens[1] == "later")
        #expect(session.listings.value(for: pageQuery)?.files.count == 1_001)
        #expect(!session.browse.hasMore)
    }

    @Test("A folder picker exposes destinations after the first thousand prefixes")
    func destinationFolders() async throws {
        let picker = PagedListingState()
        let operation: @MainActor (String?) async -> MetadataListingPage = { token in
            MetadataListingPage(files: [], folders: token == nil ? (0..<1_000).map { "folder-\($0)/" } : ["last-destination/"], nextToken: token == nil ? "page-two" : nil)
        }
        try await picker.reload(pageQuery, operation: operation)
        #expect(picker.hasMore && picker.canConfirmDestination(pageQuery))
        try await picker.loadMore(operation: operation)
        #expect(picker.page?.folders.count == 1_001)
        #expect(picker.page?.folders.last == "last-destination/")
    }

    @Test("Stash sorts only after scanning every report page, including the newest report")
    func newestReportBeyondFirstPage() async throws {
        let fixture = CatalogFixture()
        fixture.pages["bucket"] = [(0..<1_001).map { pageRecord("reports/2025-\($0).html") }, [pageRecord("reports/2026-12-31.html")]]
        let source = try await MetadataCatalogScanner.listing(ListingQuery(account: "account", bucket: "bucket", prefix: "reports/", delimiter: nil), transport: fixture)
        let newest = try MetadataCatalogQuery.newestReports(source.files, limit: 1)
        #expect(fixture.calls == 2)
        #expect(source.files.count == 1_002)
        #expect(newest.map(\.key) == ["reports/2026-12-31.html"])
    }
}

@MainActor
struct N16PartialFolderSortTests {
    @Test("An incomplete first-page sort explicitly reports its scope until the newest later row loads")
    func partialSortNotice() async throws {
        let state = PagedListingState()
        let operation: @MainActor (String?) async -> MetadataListingPage = { token in
            MetadataListingPage(files: [pageRecord(token == nil ? "old" : "new", time: token == nil ? 1 : 100)], folders: [], nextToken: token == nil ? "more" : nil)
        }
        try await state.reload(pageQuery, operation: operation)
        #expect(state.partialQueryNotice != nil)
        try await state.loadMore(operation: operation)
        #expect(state.partialQueryNotice == nil)
        let snapshot = MetadataCatalogSnapshot(records: try #require(state.page?.files), failedBuckets: [], refreshedAt: .now)
        #expect(try MetadataCatalogQuery.select(snapshot, limit: 1).first?.key == "new")
    }
}

@MainActor
struct N17PartialFolderSearchTests {
    @Test("A no-match first page keeps later search work available and finds a later matching file")
    func noMatchCanLoadMore() async throws {
        let state = PagedListingState()
        let operation: @MainActor (String?) async -> MetadataListingPage = { token in
            MetadataListingPage(files: [pageRecord(token == nil ? "unrelated.txt" : "matching-target.txt")], folders: [], nextToken: token == nil ? "more" : nil)
        }
        try await state.reload(pageQuery, operation: operation)
        #expect(state.page?.files.filter { $0.key.contains("target") }.isEmpty == true)
        #expect(state.hasMore && state.partialQueryNotice != nil)
        try await state.loadMore(operation: operation)
        #expect(state.page?.files.filter { $0.key.contains("target") }.map(\.key) == ["matching-target.txt"])
    }
}

@MainActor
struct N39DestinationListingTests {
    @Test("A failed destination cannot show the previous folder's rows or authorize confirmation")
    func failedDestination() async throws {
        let state = PagedListingState()
        try await state.reload(pageQuery) { _ in MetadataListingPage(files: [], folders: ["old-child/"], nextToken: nil) }
        #expect(state.canConfirmDestination(pageQuery))
        let destination = ListingQuery(account: "account", bucket: "bucket", prefix: "denied/")
        await #expect(throws: ResourceLoadError.self) {
            try await state.reload(destination) { _ in throw ResourceLoadError.failed("Denied destination") }
        }
        #expect(state.query == destination && state.page == nil)
        #expect(state.error?.contains("Denied") == true)
        #expect(!state.canConfirmDestination(destination))
        try await state.reload(destination, force: true) { _ in MetadataListingPage(files: [], folders: ["denied/valid/"], nextToken: nil) }
        #expect(state.canConfirmDestination(destination))
    }

    @Test("A response for an old destination cannot replace a newer validated destination")
    func staleDestination() async throws {
        let state = PagedListingState(), controlled = ControlledListing()
        let old = Task { try await state.reload(pageQuery) { _ in try await controlled.load() } }
        var started = controlled.started.stream.makeAsyncIterator();_ = await started.next()
        let newer = ListingQuery(account: "account", bucket: "bucket", prefix: "new/")
        try await state.reload(newer) { _ in MetadataListingPage(files: [], folders: ["new/valid/"], nextToken: nil) }
        controlled.succeed(1, key: "old-file")
        await #expect(throws: CancellationError.self) { try await old.value }
        #expect(state.page?.folders == ["new/valid/"])
        #expect(state.canConfirmDestination(newer))
        #expect(!state.canConfirmDestination(pageQuery))
    }
}

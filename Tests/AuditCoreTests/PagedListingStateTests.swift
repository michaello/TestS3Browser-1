import Foundation
import Testing
@testable import AuditCore

@MainActor
private final class ControlledPage {
    let started = AsyncStream<Void>.makeStream()
    var pending: CheckedContinuation<MetadataListingPage, Error>?
    func load() async throws -> MetadataListingPage {
        try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            started.continuation.yield(())
        }
    }
    func succeed(_ key: String, token: String?) {
        pending?.resume(returning: page(key, token: token))
        pending = nil
    }
    func fail() { pending?.resume(throwing: ResourceLoadError.failed("old pagination error")); pending = nil }
}

private func page(_ key: String, token: String?) -> MetadataListingPage {
    MetadataListingPage(files: [MetadataRecord(bucket: "bucket", key: key, size: 1, modified: .distantPast, etag: nil)],
                        folders: [], nextToken: token)
}

@MainActor
struct F07PagedListingTests {
    @Test("Stale pagination cannot append into refreshed rows or discard the new token")
    func refreshInvalidatesPagination() async throws {
        let state = PagedListingState()
        let query = ListingQuery(account: "account", bucket: "bucket", prefix: "folder/")
        try await state.reload(query) { _ in page("old-first.txt", token: "old-token") }
        let delayed = ControlledPage()
        var started = delayed.started.stream.makeAsyncIterator()
        let pagination = Task { try await state.loadMore { _ in try await delayed.load() } }
        _ = await started.next()
        #expect(state.isLoadingMore)
        try await state.reload(query, force: true) { _ in page("fresh-first.txt", token: "new-token") }
        delayed.succeed("obsolete-page.txt", token: nil)
        await #expect(throws: CancellationError.self) { try await pagination.value }
        #expect(state.page?.files.map(\.key) == ["fresh-first.txt"])
        #expect(state.page?.nextToken == "new-token")
        #expect(!state.isLoading)
        #expect(!state.isLoadingMore)
        #expect(state.error == nil)
    }

    @Test("Stale page errors cannot overwrite a refreshed resource's error state")
    func stalePaginationError() async throws {
        let state = PagedListingState()
        let query = ListingQuery(account: "account", bucket: "bucket", prefix: "folder/")
        try await state.reload(query) { _ in page("old.txt", token: "old-token") }
        let delayed = ControlledPage()
        var started = delayed.started.stream.makeAsyncIterator()
        let pagination = Task { try await state.loadMore { _ in try await delayed.load() } }
        _ = await started.next()
        try await state.reload(query, force: true) { _ in page("new.txt", token: "new-token") }
        delayed.fail()
        await #expect(throws: ResourceLoadError.self) { try await pagination.value }
        #expect(state.error == nil)
        #expect(state.page?.files.first?.key == "new.txt")
    }

    @Test("Request completion cannot clear a newer view request's loading flag")
    func viewRequestOwnership() {
        let ownership = RequestOwnership()
        let old = ownership.begin()
        let new = ownership.begin()
        #expect(!ownership.owns(old))
        #expect(ownership.owns(new))
        ownership.finish(old)
        #expect(ownership.isLoading)
        ownership.finish(new)
        #expect(!ownership.isLoading)
    }
}

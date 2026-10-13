import Foundation
import Observation

/// Refresh and pagination share one epoch. A replaced page cannot append rows or replace
/// the continuation token, even when the transport ignores cancellation.
@Observable @MainActor
final class PagedListingState {
    private(set) var query: ListingQuery?
    private(set) var page: MetadataListingPage?
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var error: String?
    private var generation = UUID()
    private var paginationID: UUID?
    private var paginationTask: Task<MetadataListingPage, Error>?
    private var usedTokens: Set<Data> = []
    private let requests: ResourceLoader<ListingQuery, MetadataListingPage>

    init(requests: ResourceLoader<ListingQuery, MetadataListingPage>? = nil) {
        self.requests = requests ?? ResourceLoader()
    }

    var hasMore: Bool { page?.nextToken != nil }
    var partialQueryNotice: String? {
        hasMore ? "Search and sort apply to loaded files. Load remaining pages to include the whole folder." : nil
    }
    func canConfirmDestination(_ expected: ListingQuery) -> Bool {
        query == expected && page != nil && !isLoading && error == nil
    }

    func cancelPagination() {
        generation = UUID()
        paginationTask?.cancel()
        paginationTask = nil
        paginationID = nil
        isLoadingMore = false
    }

    func reset() {
        cancelPagination()
        query = nil;page = nil;isLoading = false;error = nil
        usedTokens.removeAll()
    }

    func remove(bucket: String, key: String) {
        guard let query, let old = page else { return }
        let files = old.files.filter { !($0.bucket.utf8.elementsEqual(bucket.utf8) && $0.key.utf8.elementsEqual(key.utf8)) }
        let updated = MetadataListingPage(files: files, folders: old.folders, nextToken: old.nextToken)
        page = updated
        requests.seed(updated, for: query, refreshedAt: requests.snapshots[query]?.refreshedAt)
        if requests.isLoading(query) { requests.invalidate(query) }
    }

    func reload(_ query: ListingQuery, force: Bool = false,
                operation: @escaping @MainActor (String?) async throws -> MetadataListingPage) async throws {
        if self.query != query {
            if let old = self.query { requests.cancel(old) }
            page = nil
        }
        self.query = query
        let epoch = UUID()
        generation = epoch
        paginationTask?.cancel()
        paginationTask = nil
        paginationID = nil
        isLoadingMore = false
        usedTokens.removeAll()
        if let cached = requests.value(for: query) { page = cached }
        isLoading = true
        error = nil
        defer { if generation == epoch { isLoading = false } }
        do {
            let loaded = try await requests.load(query, policy: force ? .force : .automatic) {
                try await operation(nil)
            }
            guard generation == epoch else { throw CancellationError() }
            page = loaded
        } catch {
            if generation == epoch, !(error is CancellationError) { self.error = error.localizedDescription }
            throw error
        }
    }

    func loadMore(operation: @escaping @MainActor (String?) async throws -> MetadataListingPage) async throws {
        guard let query, !isLoading, !isLoadingMore else { return }
        // Successful mutations update the shared query cache. Appending another
        // page must use that current value instead of resurrecting removed rows.
        if let cached = requests.value(for: query) { page = cached }
        guard let token = page?.nextToken else { return }
        let epoch = generation
        let identifier = UUID()
        paginationID = identifier
        isLoadingMore = true
        let task = Task { @MainActor in try await operation(token) }
        paginationTask = task
        defer {
            if paginationID == identifier {
                isLoadingMore = false
                paginationID = nil
                paginationTask = nil
            }
        }
        do {
            let next = try await task.value
            try Task.checkCancellation()
            guard generation == epoch, self.query == query, !isLoading,
                  page?.nextToken.map({ Data($0.utf8) }) == Data(token.utf8) else { throw CancellationError() }
            guard usedTokens.insert(Data(token.utf8)).inserted,
                  next.nextToken.map({ Data($0.utf8) }) != Data(token.utf8) else {
                throw MetadataCatalogError.repeatedContinuationToken
            }
            let combined = MetadataListingPage(files: (page?.files ?? []) + next.files,
                folders: (page?.folders ?? []) + next.folders, nextToken: next.nextToken)
            page = combined
            requests.seed(combined, for: query, refreshedAt: requests.snapshots[query]?.refreshedAt)
        } catch {
            if generation == epoch, !(error is CancellationError) { self.error = error.localizedDescription }
            throw error
        }
    }
}

import Foundation

struct BucketCountEstimate: Sendable {
    let count: Int?
    let truncated: Bool
    let error: String?
}

@MainActor
final class BucketCountCache {
    private struct Value: Sendable { let count: Int;let truncated: Bool }
    private let requests: ResourceLoader<ListingQuery, Value>
    private let now: @MainActor () -> Date

    init(now: @escaping @MainActor () -> Date = Date.init) {
        self.now = now;requests = ResourceLoader(now: now)
    }

    func reset() { requests.reset() }

    func cached(account: String, bucket: String, catalog: MetadataCatalogSnapshot?) -> BucketCountEstimate? {
        if let value = completeCatalogCount(bucket: bucket, catalog: catalog) { return value }
        let query = ListingQuery(account: account, bucket: bucket, prefix: "", delimiter: nil)
        let value = requests.value(for: query), error = requests.error(for: query)
        guard value != nil || error != nil else { return nil }
        return BucketCountEstimate(count: value?.count, truncated: value?.truncated ?? false, error: error)
    }

    func load(account: String, buckets: [String], catalog: MetadataCatalogSnapshot?,
              transport: any MetadataCatalogTransport) async -> [String: BucketCountEstimate] {
        var results: [String: BucketCountEstimate] = [:]
        await withTaskGroup(of: (String, BucketCountEstimate).self) { group in
            var iterator = buckets.makeIterator()
            for _ in 0..<3 {
                if let bucket = iterator.next() {
                    group.addTask { (bucket, await self.loadOne(account: account, bucket: bucket, catalog: catalog, transport: transport)) }
                }
            }
            while let (bucket, estimate) = await group.next() {
                results[bucket] = estimate
                if !Task.isCancelled, let bucket = iterator.next() {
                    group.addTask { (bucket, await self.loadOne(account: account, bucket: bucket, catalog: catalog, transport: transport)) }
                }
            }
        }
        return results
    }

    private func loadOne(account: String, bucket: String, catalog: MetadataCatalogSnapshot?,
                         transport: any MetadataCatalogTransport) async -> BucketCountEstimate {
        if let complete = completeCatalogCount(bucket: bucket, catalog: catalog) { return complete }
        let query = ListingQuery(account: account, bucket: bucket, prefix: "", delimiter: nil)
        do {
            _ = try await requests.load(query) {
                let page = try await transport.page(bucket: bucket, prefix: nil, delimiter: nil, token: nil)
                return Value(count: page.files.count, truncated: page.nextToken != nil)
            }
        } catch {
            if error is CancellationError { return BucketCountEstimate(count: nil, truncated: false, error: "Count refresh cancelled") }
        }
        return cached(account: account, bucket: bucket, catalog: nil) ?? BucketCountEstimate(count: nil, truncated: false, error: "Count unavailable")
    }

    private func completeCatalogCount(bucket: String, catalog: MetadataCatalogSnapshot?) -> BucketCountEstimate? {
        guard let catalog, catalog.isComplete, let date = catalog.refreshedAt,
              now().timeIntervalSince(date) < 60,
              catalog.buckets.contains(where: { $0.utf8.elementsEqual(bucket.utf8) }) else { return nil }
        return BucketCountEstimate(count: catalog.records.filter { $0.bucket.utf8.elementsEqual(bucket.utf8) }.count,
                                   truncated: false, error: nil)
    }
}

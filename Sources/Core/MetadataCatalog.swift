import Foundation

struct MetadataRecord: Codable, Sendable {
    let bucket: String
    let key: String
    let size: Int64
    let modified: Date
    let etag: String?
    var contentType: String? = nil
}

struct MetadataListingPage: Sendable {
    let files: [MetadataRecord]
    let folders: [String]
    let nextToken: String?
}

struct MetadataBucketFailure: Codable, Sendable {
    let bucket: String
    let message: String
}

struct MetadataCatalogSnapshot: Codable, Sendable {
    var records: [MetadataRecord]
    var failedBuckets: [MetadataBucketFailure]
    var refreshedAt: Date?
    var buckets: [String]
    var isComplete: Bool { failedBuckets.isEmpty }

    init(records: [MetadataRecord], failedBuckets: [MetadataBucketFailure], refreshedAt: Date?, buckets: [String]? = nil) {
        self.records = records
        self.failedBuckets = failedBuckets
        self.refreshedAt = refreshedAt
        self.buckets = buckets ?? Dictionary(grouping: records, by: { Data($0.bucket.utf8) }).values.compactMap { $0.first?.bucket }
    }

    var summaries: [MetadataBucketSummary] {
        let grouped = Dictionary(grouping: records, by: { Data($0.bucket.utf8) })
        return buckets.map { bucket in
            let records = grouped[Data(bucket.utf8)] ?? []
            return MetadataBucketSummary(bucket: bucket, count: records.count,
                bytes: records.reduce(Int64(0)) { $0 + $1.size }, isComplete: isComplete)
        }
    }
}

struct MetadataBucketSummary: Sendable {
    let bucket: String
    let count: Int
    let bytes: Int64
    let isComplete: Bool
}

enum MetadataCatalogError: LocalizedError {
    case noSuccessfulBuckets([MetadataBucketFailure])
    case repeatedContinuationToken

    var errorDescription: String? {
        switch self {
        case .noSuccessfulBuckets(let failures):
            return "Refresh incomplete. No buckets could be refreshed: " + failures.map(\.bucket).joined(separator: ", ")
        case .repeatedContinuationToken:
            return "S3 returned a repeated pagination token."
        }
    }
}

/// External I/O only. The same catalog algorithm is executed by app and local fixtures.
@MainActor
protocol MetadataCatalogTransport: Sendable {
    func page(bucket: String, prefix: String?, delimiter: String?, token: String?) async throws -> MetadataListingPage
}

enum MetadataCatalogScanner {
    private struct Outcome: Sendable {
        let bucket: String
        let records: [MetadataRecord]?
        let failure: String?
    }

    @MainActor
    static func listing(_ query: ListingQuery, transport: any MetadataCatalogTransport) async throws -> MetadataListingPage {
        var token: String?
        var visited: Set<Data> = []
        var files: [MetadataRecord] = []
        var folders: [String] = []
        repeat {
            try Task.checkCancellation()
            let page = try await transport.page(bucket: query.bucket, prefix: query.prefix.isEmpty ? nil : query.prefix,
                                                delimiter: query.delimiter, token: token)
            files.append(contentsOf: page.files)
            folders.append(contentsOf: page.folders)
            token = page.nextToken
            if let token, !visited.insert(Data(token.utf8)).inserted { throw MetadataCatalogError.repeatedContinuationToken }
        } while token != nil
        return MetadataListingPage(files: files, folders: folders, nextToken: nil)
    }

    /// At most three bucket scans run concurrently. Pages within a bucket are sequential.
    @MainActor
    static func refresh(buckets: [String], previous: MetadataCatalogSnapshot?,
                        transport: any MetadataCatalogTransport, maxConcurrent: Int = 3,
                        now: Date = Date()) async throws -> MetadataCatalogSnapshot {
        let width = max(1, min(3, maxConcurrent))
        var outcomes: [Outcome] = []
        await withTaskGroup(of: Outcome.self) { group in
            var iterator = buckets.makeIterator()
            for _ in 0..<width {
                if let bucket = iterator.next() { group.addTask { await scan(bucket, transport: transport) } }
            }
            while let outcome = await group.next() {
                outcomes.append(outcome)
                if !Task.isCancelled, let bucket = iterator.next() {
                    group.addTask { await scan(bucket, transport: transport) }
                }
            }
        }
        try Task.checkCancellation()
        let failures = outcomes.compactMap { outcome in
            outcome.failure.map { MetadataBucketFailure(bucket: outcome.bucket, message: $0) }
        }
        guard (buckets.isEmpty && previous?.records.isEmpty != false) || outcomes.contains(where: { $0.records != nil }) else {
            throw MetadataCatalogError.noSuccessfulBuckets(failures)
        }
        var records: [MetadataRecord] = []
        for outcome in outcomes {
            if let refreshed = outcome.records { records.append(contentsOf: refreshed) }
            else {
                records.append(contentsOf: (previous?.records ?? []).filter {
                    $0.bucket.utf8.elementsEqual(outcome.bucket.utf8)
                })
            }
        }
        return MetadataCatalogSnapshot(records: records, failedBuckets: failures, refreshedAt: now, buckets: buckets)
    }

    @MainActor
    private static func scan(_ bucket: String, transport: any MetadataCatalogTransport) async -> Outcome {
        do {
            var token: String?
            var visited: Set<Data> = []
            var records: [MetadataRecord] = []
            repeat {
                try Task.checkCancellation()
                let page = try await transport.page(bucket: bucket, prefix: nil, delimiter: nil, token: token)
                records.append(contentsOf: page.files)
                token = page.nextToken
                if let token, !visited.insert(Data(token.utf8)).inserted {
                    throw MetadataCatalogError.repeatedContinuationToken
                }
            } while token != nil
            return Outcome(bucket: bucket, records: records, failure: nil)
        } catch {
            return Outcome(bucket: bucket, records: nil, failure: error.localizedDescription)
        }
    }
}

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


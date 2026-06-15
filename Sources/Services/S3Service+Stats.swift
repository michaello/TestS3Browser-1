import Foundation
import AWSS3

/// Bucket-level usage statistics for S3Service.
extension S3Service {
    /// Fetches object count and total storage bytes for every bucket in availableBuckets.
    /// Buckets are scanned concurrently; inaccessible or wrong-region buckets are skipped silently.
    /// - Returns: Stats per bucket, sorted by total bytes descending.
    func fetchBucketStats() async throws -> [BucketStats] {
        if client == nil { try await initializeClient() }
        guard let client = client else { throw S3ServiceError.clientNotInitialized }

        if availableBuckets.isEmpty {
            try await fetchAvailableBuckets()
        }

        var results: [BucketStats] = []

        await withTaskGroup(of: BucketStats?.self) { group in
            for bucketName in availableBuckets {
                group.addTask {
                    var count = 0
                    var bytes: Int64 = 0
                    var token: String? = nil
                    do {
                        repeat {
                            let input = ListObjectsV2Input(
                                bucket: bucketName,
                                continuationToken: token
                            )
                            let output = try await client.listObjectsV2(input: input)
                            for item in output.contents ?? [] {
                                guard let key = item.key, !key.hasSuffix("/") else { continue }
                                count += 1
                                bytes += Int64(item.size ?? 0)
                            }
                            token = output.nextContinuationToken
                        } while token != nil
                    } catch {
                        return nil
                    }
                    return BucketStats(bucket: bucketName, objectCount: count, totalBytes: bytes)
                }
            }
            for await stat in group {
                if let stat { results.append(stat) }
            }
        }

        return results.sorted { $0.totalBytes > $1.totalBytes }
    }

    /// Returns a quick object count for a single bucket using one list page (max 1000 keys).
    /// - Returns: `(count, truncated)` where `truncated` is true when the bucket has more than 1000 objects.
    func quickObjectCount(bucket: String) async -> (count: Int, truncated: Bool) {
        if client == nil { try? await initializeClient() }
        guard let client else { return (0, false) }
        do {
            let input = ListObjectsV2Input(bucket: bucket, maxKeys: 1000)
            let output = try await client.listObjectsV2(input: input)
            let count = output.contents?.filter { !($0.key?.hasSuffix("/") ?? false) }.count ?? 0
            let truncated = output.isTruncated ?? false
            return (count, truncated)
        } catch {
            return (0, false)
        }
    }
}

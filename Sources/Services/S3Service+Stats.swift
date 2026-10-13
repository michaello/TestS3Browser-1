import Foundation
import AWSS3
import AWSClientRuntime

/// Bucket-level usage statistics for S3Service.
extension S3Service {
    /// Recent and Stats share the same metadata generation. Failed buckets retain cached
    /// records; callers display recentRefreshError/isCatalogComplete with the totals.
    func fetchBucketStats(force: Bool = false) async throws -> [BucketStats] {
        let snapshot = try await refreshMetadataCatalog(force: force)
        return snapshot.summaries.map { summary in
            BucketStats(bucket: summary.bucket, objectCount: summary.count, totalBytes: summary.bytes)
        }.sorted { $0.totalBytes > $1.totalBytes }
    }

    /// Fetches the bucket policy JSON string for the given bucket.
    /// Only the explicit service NoSuchBucketPolicy response means absence.
    func fetchBucketPolicy(bucket: String) async throws -> String? {
        try await initializeClient()
        guard let client else { throw S3ServiceError.clientNotInitialized }
        return try await BucketAdministrationRead.perform(.policy, absent: String?.none,
            serviceCode: { ($0 as? any AWSClientRuntime.AWSServiceError)?.errorCode }) {
            let input = GetBucketPolicyInput(bucket: bucket)
            let output = try await client.getBucketPolicy(input: input)
            guard let policy = output.policy else { throw BucketAdministrationReadError.invalidResponse(.policy) }
            return policy
        }
    }

    /// Fetches replication rules for the given bucket.
    /// Denied/network/unknown failures remain retryable failures.
    func fetchReplicationRules(bucket: String) async throws -> [ReplicationRuleDisplay] {
        try await initializeClient()
        guard let client else { throw S3ServiceError.clientNotInitialized }
        return try await BucketAdministrationRead.perform(.replication, absent: [],
            serviceCode: { ($0 as? any AWSClientRuntime.AWSServiceError)?.errorCode }) {
            let input = GetBucketReplicationInput(bucket: bucket)
            let output = try await client.getBucketReplication(input: input)
            guard let rules = output.replicationConfiguration?.rules else { throw BucketAdministrationReadError.invalidResponse(.replication) }
            return rules.enumerated().map { index, rule in
                // Destination arrives as an ARN: arn:aws:s3:::bucket-name — strip prefix for display.
                let destARN = rule.destination?.bucket ?? ""
                let destBucket = destARN.components(separatedBy: ":::").last ?? destARN
                return ReplicationRuleDisplay(
                    id: rule.id ?? "Rule \(index + 1)",
                    status: rule.status?.rawValue ?? "Unknown",
                    destinationBucket: destBucket.isEmpty ? "(unknown)" : destBucket,
                    storageClass: rule.destination?.storageClass?.rawValue,
                    priority: rule.priority
                )
            }
        }
    }

    /// Fetches CORS rules for the given bucket.
    func fetchCORSRules(bucket: String) async throws -> [CORSRuleDisplay] {
        try await initializeClient()
        guard let client else { throw S3ServiceError.clientNotInitialized }
        return try await BucketAdministrationRead.perform(.cors, absent: [],
            serviceCode: { ($0 as? any AWSClientRuntime.AWSServiceError)?.errorCode }) {
            let input = GetBucketCorsInput(bucket: bucket)
            let output = try await client.getBucketCors(input: input)
            guard let rules = output.corsRules else { throw BucketAdministrationReadError.invalidResponse(.cors) }
            return rules.enumerated().map { index, rule in
                CORSRuleDisplay(
                    id: rule.id ?? "Rule \(index + 1)",
                    allowedOrigins: rule.allowedOrigins ?? [],
                    allowedMethods: rule.allowedMethods ?? [],
                    allowedHeaders: rule.allowedHeaders ?? [],
                    exposeHeaders: rule.exposeHeaders ?? [],
                    maxAgeSeconds: rule.maxAgeSeconds
                )
            }
        }
    }

    /// Fetches lifecycle rules for the given bucket.
    func fetchLifecycleRules(bucket: String) async throws -> [LifecycleRuleDisplay] {
        try await initializeClient()
        guard let client else { throw S3ServiceError.clientNotInitialized }
        return try await BucketAdministrationRead.perform(.lifecycle, absent: [],
            serviceCode: { ($0 as? any AWSClientRuntime.AWSServiceError)?.errorCode }) {
            let input = GetBucketLifecycleConfigurationInput(bucket: bucket)
            let output = try await client.getBucketLifecycleConfiguration(input: input)
            guard output.rules != nil else { throw BucketAdministrationReadError.invalidResponse(.lifecycle) }
            return Self.lifecycleDisplayRules(output)
        }
    }

    /// Counts reuse the complete catalog or a timestamped first-page estimate.
    /// A failed count remains unavailable, rather than being labeled zero objects.
    func fetchBucketCounts() async -> [String: BucketCountEstimate] {
        let generation = session.generation, account = session.configuration.account
        do {
            let transport = try await metadataTransport(generation: generation)
            let results = await session.counts.load(account: account, buckets: availableBuckets,
                catalog: session.catalogs.value(for: account), transport: transport)
            guard session.isCurrent(generation) else { return [:] }
            return results
        } catch {
            return Dictionary(uniqueKeysWithValues: availableBuckets.map {
                ($0, BucketCountEstimate(count: nil, truncated: false, error: error.localizedDescription))
            })
        }
    }
}

import Foundation
import AWSS3

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
    /// Returns nil when no policy is configured or access is denied (both treated as "no policy").
    func fetchBucketPolicy(bucket: String) async -> String? {
        if client == nil { try? await initializeClient() }
        guard let client else { return nil }
        do {
            let input = GetBucketPolicyInput(bucket: bucket)
            let output = try await client.getBucketPolicy(input: input)
            return output.policy
        } catch {
            // NoSuchBucketPolicy and AccessDenied both mean "no readable policy"
            return nil
        }
    }

    /// Fetches replication rules for the given bucket.
    /// Returns an empty array when no replication is configured or access is denied.
    func fetchReplicationRules(bucket: String) async -> [ReplicationRuleDisplay] {
        if client == nil { try? await initializeClient() }
        guard let client else { return [] }
        do {
            let input = GetBucketReplicationInput(bucket: bucket)
            let output = try await client.getBucketReplication(input: input)
            return (output.replicationConfiguration?.rules ?? []).enumerated().map { index, rule in
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
        } catch {
            // ReplicationConfigurationNotFoundError and AccessDenied both mean "no readable config"
            return []
        }
    }

    /// Fetches CORS rules for the given bucket.
    /// Returns an empty array when no CORS configuration exists or access is denied.
    func fetchCORSRules(bucket: String) async -> [CORSRuleDisplay] {
        if client == nil { try? await initializeClient() }
        guard let client else { return [] }
        do {
            let input = GetBucketCorsInput(bucket: bucket)
            let output = try await client.getBucketCors(input: input)
            return (output.corsRules ?? []).enumerated().map { index, rule in
                CORSRuleDisplay(
                    id: rule.id ?? "Rule \(index + 1)",
                    allowedOrigins: rule.allowedOrigins ?? [],
                    allowedMethods: rule.allowedMethods ?? [],
                    allowedHeaders: rule.allowedHeaders ?? [],
                    exposeHeaders: rule.exposeHeaders ?? [],
                    maxAgeSeconds: rule.maxAgeSeconds
                )
            }
        } catch {
            // NoSuchCORSConfiguration and AccessDenied both mean "no readable CORS rules"
            return []
        }
    }

    /// Fetches lifecycle rules for the given bucket.
    /// Returns an empty array when no rules are configured or access is denied.
    func fetchLifecycleRules(bucket: String) async -> [LifecycleRuleDisplay] {
        if client == nil { try? await initializeClient() }
        guard let client else { return [] }
        do {
            let input = GetBucketLifecycleConfigurationInput(bucket: bucket)
            let output = try await client.getBucketLifecycleConfiguration(input: input)
            return Self.lifecycleDisplayRules(output)
        } catch {
            // NoSuchLifecycleConfiguration and AccessDenied both mean "no readable rules"
            return []
        }
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

import Foundation
import AWSS3

extension S3Service {
    /// Lists request-metrics configuration, not live CloudWatch measurements.
    /// Only a successful complete empty list means that no configuration exists.
    @MainActor
    func fetchBucketMetrics(bucket: String) async throws -> [BucketMetric] {
        if client == nil { try await initializeClient() }
        guard let client else { throw BucketMetricsError.clientUnavailable }
        let configurations = try await BucketMetricsLoader.load { token in
            let output = try await client.listBucketMetricsConfigurations(
                input: ListBucketMetricsConfigurationsInput(bucket: bucket, continuationToken: token)
            )
            guard let truncated = output.isTruncated else { throw BucketMetricsError.invalidPagination }
            let entries = try (output.metricsConfigurationList ?? []).map { configuration in
                guard let id = configuration.id, !id.isEmpty else { throw BucketMetricsError.invalidConfiguration }
                return BucketMetricsConfiguration(id: id, scope: Self.metricsScope(configuration.filter))
            }
            return BucketMetricsPage(configurations: entries, isTruncated: truncated, nextToken: output.nextContinuationToken)
        }
        return configurations.map {
            BucketMetric(name: $0.id, value: "Request metrics configured. \($0.scope)", unit: "")
        }
    }

    private static func metricsScope(_ filter: S3ClientTypes.MetricsFilter?) -> String {
        guard let filter else { return "All objects" }
        switch filter {
        case .prefix(let prefix): return "Prefix: \(prefix)"
        case .tag(let tag): return "Tag: \(tag.key ?? "unknown")=\(tag.value ?? "unknown")"
        case .accesspointarn(let arn): return "Access point: \(arn)"
        case .and(let condition):
            var parts: [String] = []
            if let prefix = condition.prefix { parts.append("Prefix: \(prefix)") }
            if let arn = condition.accessPointArn { parts.append("Access point: \(arn)") }
            parts += (condition.tags ?? []).map { "Tag: \($0.key ?? "unknown")=\($0.value ?? "unknown")" }
            return parts.isEmpty ? "Filter unknown" : parts.joined(separator: "; ")
        case .sdkUnknown(let name): return "Filter unknown: \(name)"
        }
    }
}

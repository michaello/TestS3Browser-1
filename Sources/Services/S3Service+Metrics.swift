import Foundation
import AWSS3

extension S3Service {
    /// Fetches metrics configuration for the bucket via GetBucketMetricsConfiguration.
    /// Returns a display-friendly array of metrics or an empty array on failure/unconfigured metrics.
    func fetchBucketMetrics(bucket: String) async -> [BucketMetric] {
        if client == nil { try? await initializeClient() }
        guard let client else { return [] }

        var metrics: [BucketMetric] = []

        do {
            let input = GetBucketMetricsConfigurationInput(bucket: bucket)
            let output = try await client.getBucketMetricsConfiguration(input: input)

            guard let config = output.metricsConfiguration else {
                return []
            }

            guard let id = config.id else {
                return []
            }

            metrics.append(BucketMetric(
                name: "Metrics Configuration ID",
                value: id,
                unit: ""
            ))

            metrics.append(BucketMetric(
                name: "Status",
                value: "Enabled",
                unit: ""
            ))

            metrics.append(BucketMetric(
                name: "Metric Type",
                value: "Request count and data transfer",
                unit: ""
            ))

        } catch {
            return []
        }

        return metrics
    }

    /// Note: CloudWatch metrics must be enabled via PutBucketMetricsConfiguration to track actual usage data.
    /// This method provides configuration status rather than real-time metrics.
}

import AppIntents
import Foundation

/// App Intent that summarizes total S3 storage usage across every bucket. Appears in the
/// Shortcuts app as "Get S3 Storage Stats" and can be triggered by Siri. Returns a list of
/// per-bucket stat strings as its value, and speaks a one-line total summary as its dialog.
struct GetStorageStatsIntent: AppIntent {
    static var title: LocalizedStringResource = "Get S3 Storage Stats"
    static var description = IntentDescription(
        "Summarizes how many objects and how much storage you are using across your S3 buckets.",
        categoryName: "Browse"
    )

    func perform() async throws -> some IntentResult & ReturnsValue<[String]> & ProvidesDialog {
        let config = SharedConfig.loadConfig() ?? S3Config.default
        let service = S3Service(config: config)

        // fetchBucketStats also fetches buckets when needed, but call fetchAvailableBuckets
        // first so the bucket list is populated before the stats scan runs.
        try await service.fetchAvailableBuckets()
        let stats = try await service.fetchBucketStats()

        // Per-bucket lines like "my-bucket: 1234 objects, 42.7 GB" for the returned value list.
        let perBucketLines = stats.map { stat in
            "\(stat.bucket): \(stat.objectCount) objects, \(stat.formattedSize)"
        }

        // Totals for the spoken summary.
        let bucketCount = stats.count
        let totalObjects = stats.reduce(0) { $0 + $1.objectCount }
        let totalBytes = stats.reduce(Int64(0)) { $0 + $1.totalBytes }
        let totalGB = Double(totalBytes) / 1_073_741_824.0

        let objectsFormatter = NumberFormatter()
        objectsFormatter.numberStyle = .decimal
        let objectsText = objectsFormatter.string(from: NSNumber(value: totalObjects)) ?? "\(totalObjects)"

        let summary = "\(bucketCount) bucket\(bucketCount == 1 ? "" : "s"), \(objectsText) objects, \(String(format: "%.1f", totalGB)) GB total"

        return .result(value: perBucketLines, dialog: IntentDialog(stringLiteral: summary))
    }
}

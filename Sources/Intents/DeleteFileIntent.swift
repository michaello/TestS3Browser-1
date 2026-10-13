import AppIntents
import Foundation

/// Deletes an exact listed S3 object, with legacy Key/Bucket input retained.
struct DeleteFileIntent: AppIntent {
    static let title: LocalizedStringResource = "Delete S3 File"
    static let description = IntentDescription(
        "Deletes a listed S3 file, or an exact key in the specified/default bucket. This cannot be undone.",
        categoryName: "Browse"
    )

    @Parameter(
        title: "Key",
        description: "The S3 object key to delete (e.g. dump/2024-01-01T00-00-00Z-photo.jpg)"
    )
    var key: String?

    @Parameter(title: "File", description: "A file returned by List Recent S3 Files or Search My S3 Files.")
    var file: S3FileEntity?

    @Parameter(
        title: "Bucket",
        description: "Bucket the file lives in. Leave blank to use the default bucket from Settings."
    )
    var bucket: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Delete \(\.$file) from S3") {
            \.$key
            \.$bucket
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let config = try SharedConfig.requireConfig()
        let target = try ShortcutObjectRequest.resolve(
            file: file?.reference, key: key, bucket: bucket,
            defaultBucket: config.bucketName, account: S3FileEntity.accountScope(for: config)
        )
        let service = S3Service(config: config)

        try await ShortcutObjectRequest.delete(
            target,
            initialize: { try await service.initializeClient() },
            operation: { key, bucket in try await service.deleteObject(key: key, bucket: bucket) }
        )

        let filename = target.fileName
        return .result(dialog: IntentDialog("Deleted \(filename)"))
    }
}

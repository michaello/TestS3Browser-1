import AppIntents
import Foundation

/// App Intent that deletes a single S3 object by key. Appears in the Shortcuts app as
/// "Delete S3 File" and can be chained after List Recent S3 Files to bulk-delete by key.
struct DeleteFileIntent: AppIntent {
    static var title: LocalizedStringResource = "Delete S3 File"
    static var description = IntentDescription(
        "Deletes a file from S3 by key. This cannot be undone.",
        categoryName: "Browse"
    )

    @Parameter(
        title: "Key",
        description: "The S3 object key to delete (e.g. dump/2024-01-01T00-00-00Z-photo.jpg)"
    )
    var key: String

    @Parameter(
        title: "Bucket",
        description: "Bucket the file lives in. Leave blank to use the default bucket from Settings."
    )
    var bucket: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Delete \(\.$key) from S3")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let config = SharedConfig.loadConfig() ?? S3Config.default
        let service = S3Service(config: config)

        try await service.deleteObject(key: key, bucket: bucket)

        let filename = URL(string: key)?.lastPathComponent ?? key
        return .result(dialog: IntentDialog("Deleted \(filename)"))
    }
}

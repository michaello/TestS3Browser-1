import AppIntents
import Foundation
import UniformTypeIdentifiers

/// App Intent that downloads a single S3 object and returns it as a file the Shortcuts
/// app can pipe into Save to Files, Quick Look, or any action that accepts a file.
struct DownloadFileIntent: AppIntent {
    static var title: LocalizedStringResource = "Download S3 File"
    static var description = IntentDescription(
        "Downloads a file from S3 by key and returns it so you can save it or share it.",
        categoryName: "Browse"
    )

    @Parameter(
        title: "Key",
        description: "The S3 object key to download (e.g. dump/2024-01-01T00-00-00Z-photo.jpg)"
    )
    var key: String

    @Parameter(
        title: "Bucket",
        description: "Bucket the file lives in. Leave blank to use the default bucket from Settings."
    )
    var bucket: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Download \(\.$key) from S3")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> & ProvidesDialog {
        let config = SharedConfig.loadConfig() ?? S3Config.default
        let service = S3Service(config: config)

        let data = try await service.downloadObject(key: key, bucket: bucket)

        let filename = URL(string: key)?.lastPathComponent ?? key
        let uti = UTType(filenameExtension: (filename as NSString).pathExtension) ?? .data
        let file = IntentFile(data: data, filename: filename, type: uti)

        let dialog = IntentDialog("Downloaded \(filename) (\(Self.formattedSize(data.count)))")
        return .result(value: file, dialog: dialog)
    }

    private static func formattedSize(_ bytes: Int) -> String {
        let kb = Double(bytes) / 1024.0
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        return String(format: "%.1f MB", kb / 1024.0)
    }
}

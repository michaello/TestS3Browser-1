import AppIntents
import Foundation
import UIKit
import UniformTypeIdentifiers

/// App Intent that uploads files passed in from Shortcuts/Siri to the S3 dump/ folder.
/// Appears in the Shortcuts app as "Upload File to S3" and can receive files from
/// the share sheet, Files picker, or any previous Shortcuts action that outputs files.
struct UploadFileToS3Intent: AppIntent {
    static var title: LocalizedStringResource = "Upload File to S3"
    static var description = IntentDescription(
        "Uploads one or more files to the S3 dump folder and returns presigned links.",
        categoryName: "Upload"
    )

    @Parameter(
        title: "Files",
        description: "Files to upload to S3",
        supportedContentTypes: [.data]
    )
    var files: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("Upload \(\.$files) to S3")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[String]> & ProvidesDialog {
        let config = SharedConfig.loadConfig() ?? S3Config.default
        let service = S3Service(config: config)

        var presignedURLs: [String] = []

        for file in files {
            var data = file.data
            var filename = file.filename
            var contentType = file.type?.preferredMIMEType ?? "application/octet-stream"

            // Re-encode images as JPEG (0.8) so screenshots don't upload as multi-MB PNGs.
            // Same behavior as the Upload tab and the share extension.
            if file.type?.conforms(to: .image) == true,
               let image = UIImage(data: data),
               let jpeg = image.jpegData(compressionQuality: 0.8) {
                data = jpeg
                filename = (filename as NSString).deletingPathExtension + ".jpg"
                contentType = "image/jpeg"
            }

            let key = Self.dumpKey(for: filename)

            try await service.uploadObject(data: data, key: key, contentType: contentType)

            if let url = service.generatePresignedURL(for: key, expiresIn: 86400) {
                presignedURLs.append(url)
            }
        }

        let count = files.count
        let dialog = IntentDialog("Uploaded \(count) file\(count == 1 ? "" : "s") to S3")
        return .result(value: presignedURLs, dialog: dialog)
    }

    /// Dedicated folder for Siri/Shortcuts uploads so these photos are easy to find,
    /// separate from the mixed dump/ folder used by phone-stash and other tools
    static let uploadPrefix = "shortcut-uploads/"

    /// Builds a shortcut-uploads/ key with timestamp prefix, keeping the original
    /// filename so files stay recognizable in the bucket
    static func dumpKey(for filename: String) -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let safeName = filename
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "_")
        return "\(uploadPrefix)\(timestamp)-\(safeName)"
    }
}

/// Registers the intent with Siri so it can be triggered by voice
struct TestS3BrowserShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: UploadFileToS3Intent(),
            phrases: [
                "Upload file to S3 with \(.applicationName)",
                "Upload to S3 with \(.applicationName)",
                "Dump file with \(.applicationName)"
            ],
            shortTitle: "Upload to S3",
            systemImageName: "arrow.up.circle"
        )
    }
}

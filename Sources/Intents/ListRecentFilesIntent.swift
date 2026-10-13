import AppIntents
import Foundation

/// Returns bucket-qualified files that Download/Delete can consume without losing identity.
struct ListRecentFilesIntent: AppIntent {
    static let title: LocalizedStringResource = "List Recent S3 Files"
    static let description = IntentDescription(
        "Lists the most recently modified files with their S3 bucket identities.",
        categoryName: "Browse"
    )

    @Parameter(
        title: "Count",
        description: "How many recent files to return. Must be zero or greater; zero returns no files without scanning.",
        default: 10
    )
    var count: Int

    static var parameterSummary: some ParameterSummary {
        Summary("List \(\.$count) recent S3 files")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[S3FileEntity]> & ProvidesDialog {
        let request = try RecentShortcutCount(count)
        let files: [S3FileEntity] = try await request.load { limit in
            let config = try SharedConfig.requireConfig()
            let service = S3Service(config: config)
            try await service.fetchRecentFilesFromAllBuckets(limit: limit)
            let account = S3FileEntity.accountScope(for: config)
            return try service.recentFiles.map { try S3FileEntity(object: $0, account: account) }
        }

        let dialog = IntentDialog("Found \(files.count) recent file\(files.count == 1 ? "" : "s")")
        return .result(value: files, dialog: dialog)
    }
}

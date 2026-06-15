import AppIntents
import Foundation

/// App Intent that returns the keys of the most recently modified S3 objects across
/// all buckets. Appears in the Shortcuts app as "List Recent S3 Files" and can be
/// chained into other Shortcuts actions that consume a list of text values.
struct ListRecentFilesIntent: AppIntent {
    static var title: LocalizedStringResource = "List Recent S3 Files"
    static var description = IntentDescription(
        "Lists the keys of the most recently modified files across your S3 buckets.",
        categoryName: "Browse"
    )

    @Parameter(
        title: "Count",
        description: "How many recent files to return",
        default: 10
    )
    var count: Int

    static var parameterSummary: some ParameterSummary {
        Summary("List \(\.$count) recent S3 files")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[String]> & ProvidesDialog {
        let config = SharedConfig.loadConfig() ?? S3Config.default
        let service = S3Service(config: config)

        // recentFiles is empty on a freshly built service, so fetch first to populate it,
        // then read the keys back off recentFiles. Use the all-buckets fetch because the
        // Recent Files feature mixes objects from every bucket.
        try await service.fetchRecentFilesFromAllBuckets(limit: count)

        let keys = service.recentFiles.map(\.key)

        let dialog = IntentDialog("Found \(keys.count) recent file\(keys.count == 1 ? "" : "s")")
        return .result(value: keys, dialog: dialog)
    }
}

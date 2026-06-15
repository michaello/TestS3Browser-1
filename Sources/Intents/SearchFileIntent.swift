import AppIntents
import Foundation

/// App Intent that searches recent S3 files by key substring and returns matching keys.
/// Appears in the Shortcuts app as "Search My S3 Files" and can be chained into any
/// action that consumes a list of text values.
struct SearchFileIntent: AppIntent {
    static var title: LocalizedStringResource = "Search My S3 Files"
    static var description = IntentDescription(
        "Searches your recent S3 files by name and returns the matching keys.",
        categoryName: "Browse"
    )

    @Parameter(
        title: "Query",
        description: "Text to search for in file keys (case-insensitive)"
    )
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Search S3 files for \(\.$query)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[String]> & ProvidesDialog {
        let config = SharedConfig.loadConfig() ?? S3Config.default
        let service = S3Service(config: config)

        // Populate recentFiles from all buckets, then filter by query.
        try await service.fetchRecentFilesFromAllBuckets(limit: 50)

        let lower = query.lowercased()
        let matches = service.recentFiles
            .map(\.key)
            .filter { $0.lowercased().contains(lower) }

        let dialog = IntentDialog("Found \(matches.count) file\(matches.count == 1 ? "" : "s") matching \"\(query)\"")
        return .result(value: matches, dialog: dialog)
    }
}

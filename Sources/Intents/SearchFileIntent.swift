import AppIntents
import Foundation

/// Searches the full metadata catalog and retains each match's bucket identity.
struct SearchFileIntent: AppIntent {
    static let title: LocalizedStringResource = "Search My S3 Files"
    static let description = IntentDescription(
        "Searches your S3 file catalog by name and returns the matching files with their buckets.",
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

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[S3FileEntity]> & ProvidesDialog {
        let config = try SharedConfig.requireConfig()
        let service = S3Service(config: config)

        let account = S3FileEntity.accountScope(for: config)
        let matches = try await service.searchMetadata(query, limit: 50)
            .map { try S3FileEntity(object: $0, account: account) }

        let dialog = IntentDialog("Found \(matches.count) file\(matches.count == 1 ? "" : "s") matching \"\(query)\"")
        return .result(value: matches, dialog: dialog)
    }
}

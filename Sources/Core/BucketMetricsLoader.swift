import Foundation

struct BucketMetricsConfiguration: Equatable, Sendable {
    let id: String
    let scope: String
}

struct BucketMetricsPage: Sendable {
    let configurations: [BucketMetricsConfiguration]
    let isTruncated: Bool
    var nextToken: String? = nil
}

enum BucketMetricsError: LocalizedError, Equatable {
    case clientUnavailable
    case invalidConfiguration
    case invalidPagination

    var errorDescription: String? {
        switch self {
        case .clientUnavailable: "The S3 client is unavailable."
        case .invalidConfiguration: "S3 returned an incomplete metrics configuration."
        case .invalidPagination: "S3 returned an incomplete or repeated metrics page token."
        }
    }
}

/// Loads the list API completely. A failed page never becomes a successful empty result.
enum BucketMetricsLoader {
    @MainActor
    static func load(using page: (String?) async throws -> BucketMetricsPage) async throws -> [BucketMetricsConfiguration] {
        var token: String?
        var seenTokens: Set<String> = []
        var seenConfigurations: Set<String> = []
        var configurations: [BucketMetricsConfiguration] = []
        while true {
            try Task.checkCancellation()
            let result = try await page(token)
            try Task.checkCancellation()
            for configuration in result.configurations {
                guard !configuration.id.isEmpty else { throw BucketMetricsError.invalidConfiguration }
                if seenConfigurations.insert(configuration.id).inserted { configurations.append(configuration) }
            }
            guard result.isTruncated else { return configurations }
            guard let next = result.nextToken, !next.isEmpty, seenTokens.insert(next).inserted else {
                throw BucketMetricsError.invalidPagination
            }
            token = next
        }
    }
}

import Foundation
import Observation

enum CachedRowsPresentation {
    static func showsInitialLoading(rowCount: Int, hasLoadedOnce: Bool, isRefreshing: Bool) -> Bool {
        rowCount == 0 && (!hasLoadedOnce || isRefreshing)
    }
}

/// Account and credential fingerprints contain no plaintext credentials.
struct ServiceConfiguration: Equatable, Sendable {
    let account: String
    let credentialRevision: String
    let bucket: String
    let prefix: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        zip([lhs.account, lhs.credentialRevision, lhs.bucket, lhs.prefix],
            [rhs.account, rhs.credentialRevision, rhs.bucket, rhs.prefix])
            .allSatisfy { $0.utf8.elementsEqual($1.utf8) }
    }
}

struct ListingQuery: Hashable, Codable, Sendable {
    let account: String
    let bucket: String
    let prefix: String
    let delimiter: String?

    init(account: String, bucket: String, prefix: String, delimiter: String? = "/") {
        self.account = account
        self.bucket = bucket
        self.prefix = prefix
        self.delimiter = delimiter
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.account.utf8.elementsEqual(rhs.account.utf8) &&
            lhs.bucket.utf8.elementsEqual(rhs.bucket.utf8) && lhs.prefix.utf8.elementsEqual(rhs.prefix.utf8) &&
            lhs.delimiter.map { Data($0.utf8) } == rhs.delimiter.map { Data($0.utf8) }
    }

    func hash(into hasher: inout Hasher) {
        for field in [account, bucket, prefix] {
            hasher.combine(Array(field.utf8))
        }
        hasher.combine(delimiter.map { Data($0.utf8) })
    }
}

@Observable @MainActor
final class ServiceSession {
    private(set) var configuration: ServiceConfiguration
    private(set) var generation = UUID()
    private(set) var route: ListingQuery
    let bucketChoices = ResourceLoader<String, [String]>()
    let listings = ResourceLoader<ListingQuery, MetadataListingPage>()
    let catalogs = ResourceLoader<String, MetadataCatalogSnapshot>()

    init(configuration: ServiceConfiguration) {
        self.configuration = configuration
        route = ListingQuery(account: configuration.account, bucket: configuration.bucket, prefix: configuration.prefix)
    }

    @discardableResult
    func apply(_ configuration: ServiceConfiguration) -> Bool {
        guard configuration != self.configuration else { return false }
        self.configuration = configuration
        generation = UUID()
        route = ListingQuery(account: configuration.account, bucket: configuration.bucket, prefix: configuration.prefix)
        bucketChoices.reset()
        listings.reset()
        catalogs.reset()
        return true
    }

    func selectRoute(bucket: String, prefix: String) {
        let next = ListingQuery(account: configuration.account, bucket: bucket, prefix: prefix)
        guard next != route else { return }
        listings.cancel(route)
        route = next
    }

    /// Restore both route fields before either operation begins. Discovery may remain
    /// suspended while the requested folder publishes its cached or refreshed rows.
    func restoreBrowse(bucket: String, prefix: String,
                       listing: @escaping @MainActor () async -> Void,
                       discovery: @escaping @MainActor () async -> Void) async {
        selectRoute(bucket: bucket, prefix: prefix)
        async let choices: Void = discovery()
        await listing()
        await choices
    }

    func isCurrent(_ generation: UUID) -> Bool { self.generation == generation }
}

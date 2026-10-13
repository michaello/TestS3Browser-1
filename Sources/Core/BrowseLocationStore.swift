import Foundation

@MainActor
struct BrowseLocationStore {
    private struct Envelope: Codable {
        let route: ListingQuery
        let configuredBucket: String
        let configuredPrefix: String
    }
    let defaults: UserDefaults

    func resolve(_ configuration: ServiceConfiguration, legacyBucket: String = "", legacyPrefix: String = "") -> ListingQuery {
        let fallback = ListingQuery(account: configuration.account, bucket: configuration.bucket, prefix: configuration.prefix)
        if let data = defaults.data(forKey: key(configuration.account)),
           let saved = try? JSONDecoder().decode(Envelope.self, from: data),
           saved.route.account.utf8.elementsEqual(configuration.account.utf8) {
            guard saved.configuredBucket.utf8.elementsEqual(configuration.bucket.utf8),
                  saved.configuredPrefix.utf8.elementsEqual(configuration.prefix.utf8) else { return fallback }
            return saved.route
        }
        // An explicit configured prefix takes precedence over the old unscoped
        // defaults. Claim legacy navigation once so another account cannot inherit it.
        guard configuration.prefix.isEmpty, !legacyBucket.isEmpty else { return fallback }
        let ownerKey = "s3BrowseLegacyOwner.v1"
        if let owner = defaults.string(forKey: ownerKey), !owner.utf8.elementsEqual(configuration.account.utf8) { return fallback }
        defaults.set(configuration.account, forKey: ownerKey)
        return ListingQuery(account: configuration.account, bucket: legacyBucket, prefix: legacyPrefix)
    }

    func save(_ route: ListingQuery, configuration: ServiceConfiguration) throws {
        guard route.account.utf8.elementsEqual(configuration.account.utf8) else { return }
        let envelope = Envelope(route: route, configuredBucket: configuration.bucket, configuredPrefix: configuration.prefix)
        defaults.set(try JSONEncoder().encode(envelope), forKey: key(configuration.account))
    }

    private func key(_ account: String) -> String { "s3BrowseLocation.v1." + account }
}

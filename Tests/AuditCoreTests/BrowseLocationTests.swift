import Foundation
import Testing
@testable import AuditCore

@MainActor
private func locationDefaults() throws -> (String, UserDefaults) {
    let suite = "s3-location-" + UUID().uuidString
    return (suite, try #require(UserDefaults(suiteName: suite)))
}

private func locationConfig(_ account: String = "A", bucket: String = "bucket", prefix: String = "") -> ServiceConfiguration {
    ServiceConfiguration(account: account, credentialRevision: "rev", bucket: bucket, prefix: prefix)
}

@MainActor
struct F27ConfirmedNavigationTests {
    @Test("Folder, breadcrumb, root and bucket changes persist through one success owner")
    func successfulRoutes() throws {
        let (suite, defaults) = try locationDefaults();defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = locationConfig(), session = ServiceSession(configuration: locationConfig())
        let store = BrowseLocationStore(defaults: defaults)
        for (bucket, prefix) in [("bucket", "a/b/"), ("bucket", "a/"), ("bucket", ""), ("another", "")] {
            session.selectRoute(bucket: bucket, prefix: prefix)
            session.listings.seed(MetadataListingPage(files: [], folders: [], nextToken: nil), for: session.route, refreshedAt: .now)
            #expect(session.confirmRoute(session.route))
            try store.save(try #require(session.confirmedRoute), configuration: configuration)
            #expect(store.resolve(configuration) == session.route)
        }
    }

    @Test("A failed new folder cannot commit another route's cached rows")
    func failedRoute() throws {
        let (suite, defaults) = try locationDefaults();defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = locationConfig(), session = ServiceSession(configuration: locationConfig())
        let store = BrowseLocationStore(defaults: defaults), successful = session.route
        session.listings.seed(MetadataListingPage(files: [], folders: ["known/"], nextToken: nil), for: successful, refreshedAt: .now)
        #expect(session.confirmRoute(successful));try store.save(successful, configuration: configuration)
        session.selectRoute(bucket: "denied", prefix: "private/")
        #expect(!session.confirmRoute(session.route))
        #expect(!session.confirmRoute(successful))
        #expect(session.listings.value(for: session.route) == nil)
        #expect(store.resolve(configuration) == successful)
    }

    @Test("Legacy route migration and saved navigation cannot cross accounts")
    func accountIsolation() throws {
        let (suite, defaults) = try locationDefaults();defer { defaults.removePersistentDomain(forName: suite) }
        let store = BrowseLocationStore(defaults: defaults)
        let migrated = store.resolve(locationConfig(), legacyBucket: "saved", legacyPrefix: "deep//")
        #expect(migrated.bucket == "saved" && migrated.prefix == "deep//")
        try store.save(migrated, configuration: locationConfig())
        let other = store.resolve(locationConfig("B"), legacyBucket: "saved", legacyPrefix: "deep//")
        #expect(other.bucket == "bucket" && other.prefix.isEmpty)
    }
}

@MainActor
struct N34ConfiguredPrefixTests {
    @Test("An initial explicit prefix wins over unrelated unscoped legacy defaults")
    func freshPrefix() throws {
        let (suite, defaults) = try locationDefaults();defer { defaults.removePersistentDomain(forName: suite) }
        let route = BrowseLocationStore(defaults: defaults).resolve(locationConfig(prefix: "configured//"), legacyBucket: "stale", legacyPrefix: "old/")
        #expect(route.bucket == "bucket" && route.prefix == "configured//")
    }

    @Test("Applying configured bucket or prefix changes overrides an old saved route")
    func appliedConfiguration() throws {
        let (suite, defaults) = try locationDefaults();defer { defaults.removePersistentDomain(forName: suite) }
        let store = BrowseLocationStore(defaults: defaults), original = locationConfig()
        try store.save(ListingQuery(account: "A", bucket: "saved", prefix: "deep/"), configuration: original)
        #expect(store.resolve(original).prefix == "deep/")
        #expect(store.resolve(locationConfig(prefix: "new/")).prefix == "new/")
        #expect(store.resolve(locationConfig(bucket: "new-bucket")).bucket == "new-bucket")
    }
}

import Foundation
import Testing
@testable import AuditCore

@MainActor
struct F03TabRetentionTests {
    @Test("Initial selection creates only its own screen, including a restored non-Browse tab")
    func lazyInitialSelection() {
        let tabs = AppTabState(initial: .recent)
        #expect(tabs.retainedTabs == [.recent])
        #expect(!tabs.visited.contains(.browse))
        tabs.select(.stats)
        #expect(tabs.retainedTabs == [.recent, .stats])
        tabs.select(.recent)
        #expect(tabs.retainedTabs == [.recent, .stats])
        #expect(tabs.selected == .recent)
    }

    @Test("A revisit retains the same per-route cache and sends no listing within sixty seconds")
    func cachedRevisit() async throws {
        let tabs = AppTabState(initial: .browse)
        let session = ServiceSession(configuration: ServiceConfiguration(account: "account", credentialRevision: "rev", bucket: "bucket", prefix: "nested/"))
        let query = session.route;var calls = 0
        let operation: @MainActor () async -> MetadataListingPage = {
            calls += 1
            return MetadataListingPage(files: [], folders: ["nested/child/"], nextToken: nil)
        }
        _ = try await session.listings.load(query, operation: operation)
        tabs.select(.stats);tabs.select(.browse)
        #expect(session.route == query)
        #expect(session.listings.value(for: query)?.folders == ["nested/child/"])
        _ = try await session.listings.load(query, operation: operation)
        #expect(calls == 1)
    }

    @Test("An account configuration reset releases hidden account-specific screen state")
    func accountReset() {
        let tabs = AppTabState(initial: .browse)
        tabs.select(.recent);tabs.select(.settings)
        tabs.resetForConfiguration()
        #expect(tabs.retainedTabs == [.settings])
        #expect(tabs.selected == .settings)
    }
}

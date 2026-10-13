import Foundation
import Testing
@testable import AuditCore

@MainActor
struct AuditF29 {
    enum Failure: Error { case denied }
    private func identity(revision: String = "rev-1", bucket: String = "bucket", account: String = "a", prefix: String = "") -> AdministrationIdentity {
        AdministrationIdentity(configuration: ServiceConfiguration(account: account, credentialRevision: revision, bucket: bucket, prefix: prefix))
    }

    @Test func typingDraftDoesNotPublishOrPersistUntilApply() throws {
        var draft = ConfigurationDraft(applied: "bucket")
        var writes: [String] = []
        for text in ["b", "bu", "buc", "bucket-other"] { draft.value = text }
        #expect(writes.isEmpty)
        #expect(draft.applied == "bucket")
        #expect(draft.generation == 0)
        try draft.apply { writes.append($0) }
        #expect(writes == ["bucket-other"])
        #expect(draft.generation == 1)
        try draft.apply { writes.append($0) }
        #expect(writes.count == 1)
        #expect(draft.generation == 1)
    }
    @Test func failedApplyKeepsTheAppliedConfigurationAndEditableDraft() {
        var draft = ConfigurationDraft(applied: "old")
        draft.value = "replacement"
        #expect(throws: Failure.denied) { try draft.apply { _ in throw Failure.denied } }
        #expect(draft.applied == "old")
        #expect(draft.value == "replacement")
        #expect(draft.generation == 0)
        draft.discard()
        #expect(draft.value == "old")
    }
    @Test func collapsedSectionsSendNoRequestsAndRevisitsReuseTheCache() async {
        let section = AdministrationSection<String>()
        let key = identity()
        var requests = 0
        await section.load(key, expanded: false) { requests += 1; return "unused" }
        #expect(requests == 0)
        #expect(section.hasLoaded == false)
        await section.load(key, expanded: true) { requests += 1; return "first" }
        await section.load(key, expanded: false) { requests += 1; return "unused" }
        await section.load(key, expanded: true) { requests += 1; return "unneeded" }
        #expect(requests == 1)
        #expect(section.value == "first")
    }
    @Test func sameBucketCredentialChangesAndExactFullConfigurationInvalidateSelection() async {
        let section = AdministrationSection<String>()
        let first = identity(), changed = identity(revision: "rev-2")
        await section.load(first, expanded: true) { "old-credential-result" }
        section.activate(changed)
        #expect(section.value == nil)
        #expect(section.value(for: changed) == nil)
        await section.load(changed, expanded: true) { "new-credential-result" }
        #expect(section.value == "new-credential-result")
        let distinct = [first, changed, identity(bucket: "other"), identity(account: "other"), identity(prefix: "x//"), identity(prefix: "x/")]
        #expect(Set(distinct).count == distinct.count)
    }
    @Test func obsoleteResponseCannotOverwriteTheCurrentAdministrationResults() async {
        let section = AdministrationSection<String>()
        let started = AsyncStream<Void>.makeStream()
        var continuation: CheckedContinuation<String, Never>?
        let old = Task {
            await section.load(identity(), expanded: true) {
                await withCheckedContinuation { continuation = $0; started.continuation.yield(()) }
            }
        }
        var events = started.stream.makeAsyncIterator()
        _ = await events.next()
        let current = identity(revision: "new-credentials", bucket: "new-bucket")
        await section.load(current, expanded: true) { "current" }
        continuation?.resume(returning: "obsolete")
        await old.value
        #expect(section.identity == current)
        #expect(section.value == "current")
        #expect(section.value(for: identity()) == nil)
        #expect(section.error == nil)
    }
    @Test func failedForcedRefreshRetainsGoodAdministrationData() async {
        let section = AdministrationSection<String>()
        let key = identity()
        await section.load(key, expanded: true) { "saved" }
        await section.load(key, expanded: true, force: true) { throw Failure.denied }
        #expect(section.value == "saved")
        #expect(section.error != nil)
        #expect(section.isLoading == false)
    }
}

@MainActor
struct AuditN20 {
    @Test func failedRebuildRetainsSavedRowsAndRunsOneReplacementRequest() async throws {
        let loader = ResourceLoader<String, [String]>()
        loader.seed(["saved"], for: "account", refreshedAt: .now)
        loader.prepareRebuild("account")
        #expect(loader.value(for: "account") == ["saved"])
        var requests = 0
        await #expect(throws: ResourceLoadError.self) {
            try await loader.load("account", policy: .force) { requests += 1; throw ResourceLoadError.failed("offline") }
        }
        #expect(requests == 1)
        #expect(loader.value(for: "account") == ["saved"])
        #expect(loader.error(for: "account") == "offline")
    }
    @Test func successfulRebuildPublishesOneReplacement() async throws {
        let loader = ResourceLoader<String, [String]>()
        loader.seed(["saved"], for: "account", refreshedAt: .now)
        loader.prepareRebuild("account")
        var requests = 0
        let rebuilt = try await loader.load("account", policy: .force) { requests += 1; return ["replacement"] }
        #expect(rebuilt == ["replacement"])
        #expect(loader.value(for: "account") == ["replacement"])
        #expect(requests == 1)
    }
    @Test func priorInFlightRequestCannotUndoTheRebuild() async throws {
        let loader = ResourceLoader<String, [String]>()
        loader.seed(["saved"], for: "account", refreshedAt: nil)
        let started = AsyncStream<Void>.makeStream()
        var continuation: CheckedContinuation<[String], Never>?
        let old = Task {
            try await loader.load("account") {
                await withCheckedContinuation { continuation = $0; started.continuation.yield(()) }
            }
        }
        var events = started.stream.makeAsyncIterator()
        _ = await events.next()
        loader.prepareRebuild("account")
        var requests = 0
        _ = try await loader.load("account", policy: .force) { requests += 1; return ["rebuilt"] }
        continuation?.resume(returning: ["obsolete"])
        await #expect(throws: CancellationError.self) { try await old.value }
        #expect(loader.value(for: "account") == ["rebuilt"])
        #expect(requests == 1)
    }
}

import Foundation
import Testing
@testable import AuditCore

@MainActor
private func withAnnotationFixture(_ run: (UserDefaults, ObjectAnnotationState) throws -> Void) throws {
    let name = "AuditLocalObjects-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    try run(defaults, ObjectAnnotationState(defaults: defaults))
}

private func object(_ account: String = "account-A", _ bucket: String = "bucket-A", _ key: String = "same/key.jpg") -> LocalObjectIdentity {
    LocalObjectIdentity(account: account, bucket: bucket, key: key)
}

@MainActor
struct AuditF26 {
    @Test func equalKeysAcrossBucketsAndAccountsKeepIndependentLabels() throws {
        try withAnnotationFixture { defaults, state in
            let first = object(), otherBucket = object("account-A", "bucket-B"), otherAccount = object("account-B")
            state.toggleStar(first)
            state.setTag("review", for: first)
            state.setTag("archive", for: otherBucket)
            #expect(state.stars == [first])
            #expect(state.tags[first] == "review")
            #expect(state.tags[otherBucket] == "archive")
            #expect(state.tags[otherAccount] == nil)
            #expect(state.hasStars(in: "account-B") == false)
            #expect(state.tags(in: "account-B").isEmpty)
            let restored = ObjectAnnotationState(defaults: defaults)
            #expect(restored.stars == state.stars)
            #expect(restored.tags == state.tags)
        }
    }

    @Test func exactUnicodeAndRepeatedSlashKeysRemainDistinct() throws {
        let identities = [object("a", "b", "caf\u{e9}.jpg"), object("a", "b", "cafe\u{301}.jpg"),
            object("a", "b", "x//y"), object("a", "b", "x/y"), object("a.b", "c", "d"), object("a", "b.c", "d")]
        #expect(Set(identities).count == identities.count)
        try withAnnotationFixture { defaults, state in
            for (index, identity) in identities.enumerated() { state.setTag("tag-\(index)", for: identity) }
            let restored = ObjectAnnotationState(defaults: defaults)
            for (index, identity) in identities.enumerated() { #expect(restored.tags[identity] == "tag-\(index)") }
        }
    }

    @Test func ambiguousLegacyLabelsAreRetainedWithoutAssigningAnAccountOrBucket() throws {
        try withAnnotationFixture { defaults, _ in
            defaults.set(["legacy.jpg"], forKey: "s3StarredKeys")
            defaults.set(["legacy.jpg": "keep"], forKey: "s3FileTags")
            let state = ObjectAnnotationState(defaults: defaults)
            #expect(state.legacyStarKeys == ["legacy.jpg"])
            #expect(state.legacyTags == ["legacy.jpg": "keep"])
            #expect(state.stars.isEmpty)
            #expect(state.tags.isEmpty)
            state.toggleStar(object("new-account", "new-bucket", "new.jpg"))
            #expect(defaults.array(forKey: "s3StarredKeys") as? [String] == ["legacy.jpg"])
            #expect(defaults.dictionary(forKey: "s3FileTags") as? [String: String] == ["legacy.jpg": "keep"])
            #expect(ObjectAnnotationState(defaults: defaults).legacyTags == state.legacyTags)
        }
    }

    @Test func renameAndMoveCarryAnnotationsToTheExactDestination() throws {
        try withAnnotationFixture { _, state in
            let source = object(), destination = object("account-A", "bucket-B", "renamed//photo.jpg")
            let unrelated = object("account-B", "bucket-B", "renamed//photo.jpg")
            state.toggleStar(source); state.setTag("important", for: source)
            state.setTag("other-account", for: unrelated)
            state.relocate(from: source, to: destination)
            #expect(state.stars.contains(source) == false)
            #expect(state.stars.contains(destination))
            #expect(state.tags[source] == nil)
            #expect(state.tags[destination] == "important")
            #expect(state.tags[unrelated] == "other-account")
        }
    }

    @Test func unreadableArchiveIsRetainedRatherThanReplacedByAnEmptyStore() throws {
        try withAnnotationFixture { defaults, _ in
            let invalid = Data("invalid-fixture".utf8)
            defaults.set(invalid, forKey: ObjectAnnotationState.storageKey)
            let state = ObjectAnnotationState(defaults: defaults)
            state.toggleStar(object()); state.setTag("replacement", for: object())
            #expect(defaults.data(forKey: ObjectAnnotationState.storageKey) == invalid)
            #expect(state.storageError != nil)
            #expect(state.stars.isEmpty)
        }
    }

    @Test func newFileMarkersDoNotCrossBucketOrAccountBoundaries() {
        var history = SeenObjectHistory()
        history.mark(["old.jpg"], account: "account-A", bucket: "bucket-A")
        history.mark(["same.jpg"], account: "account-A", bucket: "bucket-B")
        let newA = history.newKeys(["same.jpg"], account: "account-A", bucket: "bucket-A")
            .map { object("account-A", "bucket-A", $0) }
        #expect(Set(newA) == [object("account-A", "bucket-A", "same.jpg")])
        #expect(history.newKeys(["same.jpg"], account: "account-A", bucket: "bucket-B").isEmpty)
        #expect(Set(newA).contains(object("account-B", "bucket-A", "same.jpg")) == false)
    }
}

struct AuditN23 {
    @Test func filteredOrLimitedPagesCannotForgetPreviouslySeenKeys() {
        var history = SeenObjectHistory()
        history.mark(["image.jpg", "log.txt", "older.png"], account: "a", bucket: "b")
        history.mark(["log.txt"], account: "a", bucket: "b")
        history.mark([], account: "a", bucket: "b")
        #expect(history.newKeys(["image.jpg", "older.png", "brand-new.jpg"], account: "a", bucket: "b") == ["brand-new.jpg"])
    }
    @Test func namespacesAndAccountsHaveIndependentSeenHistory() {
        var history = SeenObjectHistory()
        history.mark(["report.html"], account: "a", bucket: "b", namespace: "recent")
        #expect(history.hasRecord(account: "a", bucket: "b", namespace: "stash") == false)
        #expect(history.hasRecord(account: "other", bucket: "b") == false)
        history.mark([], account: "a", bucket: "b", namespace: "stash")
        #expect(history.newKeys(["report.html"], account: "a", bucket: "b", namespace: "stash") == ["report.html"])
    }
    @Test func historyRoundTripPreservesExactBytesAndAdditivePages() throws {
        var history = SeenObjectHistory()
        history.mark(["caf\u{e9}.jpg", "x//y"], account: "a", bucket: "b")
        history.mark(["latest.jpg"], account: "a", bucket: "b")
        let restored = try JSONDecoder().decode(SeenObjectHistory.self, from: JSONEncoder().encode(history))
        #expect(restored.newKeys(["caf\u{e9}.jpg", "cafe\u{301}.jpg", "x/y", "x//y", "latest.jpg"], account: "a", bucket: "b") == ["cafe\u{301}.jpg", "x/y"])
    }
    @Test func explicitPruningClearsOnlyTheRequestedScope() {
        var history = SeenObjectHistory()
        history.mark(["one"], account: "a", bucket: "b")
        history.mark(["two"], account: "a", bucket: "other")
        history.clear(account: "a", bucket: "b")
        #expect(history.hasRecord(account: "a", bucket: "b") == false)
        #expect(history.hasRecord(account: "a", bucket: "other"))
        #expect(history.newKeys(["two"], account: "a", bucket: "other").isEmpty)
    }
}

@MainActor
struct AuditN22 {
    @Test func removingLastStarResetsStarFilter() throws {
        try withAnnotationFixture { _, state in
            let identity = object()
            state.toggleStar(identity)
            var filter = RecentAnnotationFilter(starredOnly: true)
            state.toggleStar(identity)
            filter.reconcile(availableTags: state.tags(in: identity.account), hasStars: state.hasStars(in: identity.account))
            #expect(filter.starredOnly == false)
            #expect(filter.isActive == false)
        }
    }
    @Test func removingLastSelectedTagResetsTagFilter() throws {
        try withAnnotationFixture { _, state in
            let identity = object()
            state.setTag("review", for: identity)
            var filter = RecentAnnotationFilter(tag: "review")
            state.setTag(nil, for: identity)
            state.setTag("review", for: object("other-account"))
            filter.reconcile(availableTags: state.tags(in: identity.account), hasStars: false)
            #expect(filter.tag == nil)
            #expect(filter.isActive == false)
        }
    }
    @Test func existingFiltersRemainUntilExplicitlyCleared() {
        var filter = RecentAnnotationFilter(tag: "review", starredOnly: true)
        filter.reconcile(availableTags: ["review"], hasStars: true)
        #expect(filter.isActive)
        filter.clear()
        #expect(filter == RecentAnnotationFilter())
    }
    @Test func unavailableTagDoesNotClearAnAvailableStarFilter() {
        var filter = RecentAnnotationFilter(tag: "gone", starredOnly: true)
        filter.reconcile(availableTags: [], hasStars: true)
        #expect(filter.tag == nil)
        #expect(filter.starredOnly)
        #expect(filter.isActive)
    }
}

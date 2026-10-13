import Foundation
import Darwin
import Testing
@testable import AuditCore

private func mutationRecord(_ bucket: String, _ key: String, time: TimeInterval = 1) -> MetadataRecord {
    MetadataRecord(bucket: bucket, key: key, size: 42, modified: Date(timeIntervalSince1970: time), etag: "fixture")
}
@MainActor
private final class MutationFixture {
    let catalogs = ResourceLoader<String, MetadataCatalogSnapshot>()
    let listings = ResourceLoader<ListingQuery, MetadataListingPage>()
    let account = "account"
    func seed(_ bucket: String, _ key: String) -> ListingQuery {
        let query = ListingQuery(account: account, bucket: bucket, prefix: "", delimiter: nil)
        listings.seed(MetadataListingPage(files: [mutationRecord(bucket, key)], folders: [], nextToken: nil), for: query, refreshedAt: .now)
        return query
    }
    func apply(replacement: MetadataRecord? = nil, removed: LocalObjectIdentity? = nil, account: String = "account") {
        _ = MetadataMutationProjection.apply(MetadataMutation(account: account, replacement: replacement, removed: removed),
            currentAccount: self.account, catalogs: catalogs, listings: listings)
    }
}

@MainActor
struct AuditN24 {
    @Test func deletingBucketBKeyCannotEvictBucketAKeyFromAnySnapshot() {
        let fixture = MutationFixture()
        let a = fixture.seed("A", "same/key.txt"), b = fixture.seed("B", "same/key.txt")
        fixture.catalogs.seed(MetadataCatalogSnapshot(records: [mutationRecord("A", "same/key.txt"), mutationRecord("B", "same/key.txt")],
            failedBuckets: [], refreshedAt: .now), for: fixture.account, refreshedAt: .now)
        fixture.apply(removed: LocalObjectIdentity(account: fixture.account, bucket: "B", key: "same/key.txt"))
        #expect(fixture.listings.value(for: a)?.files.map(\.bucket) == ["A"])
        #expect(fixture.listings.value(for: b)?.files.isEmpty == true)
        #expect(fixture.catalogs.value(for: fixture.account)?.records.map(\.bucket) == ["A"])
    }
    @Test func obsoleteAccountDeleteCannotChangeCurrentCaches() {
        let fixture = MutationFixture()
        let current = fixture.seed("A", "same.txt")
        fixture.apply(removed: LocalObjectIdentity(account: "obsolete", bucket: "A", key: "same.txt"), account: "obsolete")
        #expect(fixture.listings.value(for: current)?.files.count == 1)
    }
    @Test func byteDistinctKeysAndBucketsAreNotEvictedAsAliases() {
        let fixture = MutationFixture()
        let a = fixture.seed("A", "caf\u{e9}.txt")
        fixture.apply(removed: LocalObjectIdentity(account: fixture.account, bucket: "A", key: "cafe\u{301}.txt"))
        #expect(fixture.listings.value(for: a)?.files.count == 1)
    }
    @Test func delayedListingCannotRestoreASuccessfullyDeletedObject() async throws {
        let fixture = MutationFixture()
        let query = fixture.seed("B", "deleted.txt")
        let started = AsyncStream<Void>.makeStream()
        var release: CheckedContinuation<MetadataListingPage, Never>?
        let old = Task { try await fixture.listings.load(query, policy: .force) {
            await withCheckedContinuation { release = $0; started.continuation.yield(()) }
        } }
        var events = started.stream.makeAsyncIterator(); _ = await events.next()
        fixture.apply(removed: LocalObjectIdentity(account: fixture.account, bucket: "B", key: "deleted.txt"))
        release?.resume(returning: MetadataListingPage(files: [mutationRecord("B", "deleted.txt")], folders: [], nextToken: nil))
        await #expect(throws: CancellationError.self) { try await old.value }
        #expect(fixture.listings.value(for: query)?.files.isEmpty == true)
    }
}

@MainActor
struct AuditN12 {
    @Test(arguments: ["root", "sheet-after-dismissal", "queued"])
    func everyUploadCompletionUpdatesTheExactActiveUploadSnapshot(_ origin: String) {
        let fixture = MutationFixture()
        let target = ListingQuery(account: fixture.account, bucket: "A", prefix: "dump/", delimiter: nil)
        let other = ListingQuery(account: fixture.account, bucket: "B", prefix: "dump/", delimiter: nil)
        fixture.listings.seed(MetadataListingPage(files: [mutationRecord("A", "dump/saved.jpg")], folders: [], nextToken: nil), for: target, refreshedAt: .now)
        fixture.listings.seed(MetadataListingPage(files: [mutationRecord("B", "dump/saved.jpg")], folders: [], nextToken: nil), for: other, refreshedAt: .now)
        fixture.apply(replacement: mutationRecord("A", "dump/\(origin).jpg", time: 2))
        #expect(fixture.listings.value(for: target)?.files.count == 2)
        #expect(fixture.listings.value(for: other)?.files.map(\.key) == ["dump/saved.jpg"])
        #expect(fixture.catalogs.value(for: fixture.account)?.records.first?.key == "dump/\(origin).jpg")
    }
    @Test func uploadBeforeTheFirstListingCreatesAVisibleStaleSnapshot() {
        let fixture = MutationFixture()
        fixture.apply(replacement: mutationRecord("A", "dump/new.jpg"))
        let query = ListingQuery(account: fixture.account, bucket: "A", prefix: "dump/", delimiter: nil)
        #expect(fixture.listings.value(for: query)?.files.map(\.key) == ["dump/new.jpg"])
        #expect(fixture.listings.snapshots[query]?.refreshedAt == nil)
        #expect(fixture.catalogs.value(for: fixture.account)?.isComplete == false)
    }
    @Test func nestedUploadAddsTheCorrectFolderWithoutChangingAnUnrelatedListing() {
        let fixture = MutationFixture()
        let root = ListingQuery(account: fixture.account, bucket: "A", prefix: "", delimiter: "/")
        fixture.listings.seed(MetadataListingPage(files: [], folders: [], nextToken: nil), for: root, refreshedAt: .now)
        fixture.apply(replacement: mutationRecord("A", "dump//new.jpg"))
        #expect(fixture.listings.value(for: root)?.folders == ["dump/"])
        #expect(fixture.listings.value(for: root)?.files.isEmpty == true)
    }
    @Test func obsoleteUploadAccountCannotPublishIntoTheNewActiveUploadList() {
        let fixture = MutationFixture()
        fixture.apply(replacement: mutationRecord("A", "dump/obsolete.jpg"), account: "old-account")
        #expect(fixture.listings.snapshots.isEmpty)
        #expect(fixture.catalogs.snapshots.isEmpty)
    }
}

@MainActor
struct AuditN42 {
    private func withDefaults(_ run: (UserDefaults, URL) throws -> Void) throws {
        let name = "AuditUploadDelivery-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: folder)
        }
        try run(defaults, folder.appendingPathComponent("delivery.lock"))
    }
    @Test func completedUploadPersistsTheAccountEnvelopeAndRequestsReloadWithoutScanning() throws {
        try withDefaults { defaults, lockURL in
            var reloads = 0
            try RecentUploadDelivery.uploaded(mutationRecord("bucket", "dump/new.jpg"), account: "a", defaults: defaults, lockURL: lockURL) { reloads += 1 }
            #expect(reloads == 1)
            #expect(MetadataSnapshotStore(defaults: defaults).load(account: "a")?.records.map(\.key) == ["dump/new.jpg"])
            let data = try #require(defaults.data(forKey: "s3WidgetRecent.v1"))
            let widget = try JSONDecoder().decode(RecentUploadWidgetSnapshot.self, from: data)
            #expect(widget.account == "a")
            #expect(widget.uploads.first?.bucket == "bucket")
            #expect(widget.uploads.first?.key == "dump/new.jpg")
        }
    }
    @Test func uploadPreservesOtherBucketRowsAndReplacesOnlyTheExactTarget() throws {
        try withDefaults { defaults, lockURL in
            let prior = MetadataCatalogSnapshot(records: [mutationRecord("A", "dump/same.jpg"), mutationRecord("B", "dump/same.jpg")], failedBuckets: [], refreshedAt: .now)
            try RecentUploadDelivery.publish(prior, account: "a", defaults: defaults, lockURL: lockURL) {}
            try RecentUploadDelivery.uploaded(mutationRecord("B", "dump/same.jpg", time: 99), account: "a", defaults: defaults, lockURL: lockURL) {}
            let records = try #require(MetadataSnapshotStore(defaults: defaults).load(account: "a")?.records)
            #expect(records.count == 2)
            #expect(records.first { $0.bucket == "A" }?.modified == Date(timeIntervalSince1970: 1))
            #expect(records.first { $0.bucket == "B" }?.modified == Date(timeIntervalSince1970: 99))
        }
    }
    @Test func canonicalWidgetDeliveryKeepsRowsIndependentOfAnyUIFilter() throws {
        try withDefaults { defaults, lockURL in
            let records = [mutationRecord("A", "image.jpg"), mutationRecord("B", "log.txt", time: 2)]
            try RecentUploadDelivery.publish(MetadataCatalogSnapshot(records: records, failedBuckets: [], refreshedAt: .now), account: "a", defaults: defaults, lockURL: lockURL) {}
            let widget = try JSONDecoder().decode(RecentUploadWidgetSnapshot.self, from: #require(defaults.data(forKey: "s3WidgetRecent.v1")))
            #expect(widget.uploads.map(\.key) == ["log.txt", "image.jpg"])
            #expect(Set(widget.uploads.compactMap(\.bucket)) == ["A", "B"])
        }
    }
    @Test func cachedAppPublicationCannotEraseANewerShareUpload() throws {
        try withDefaults { defaults, lockURL in
            let cached = MetadataCatalogSnapshot(records: [mutationRecord("A", "cached")], failedBuckets: [],
                refreshedAt: Date(timeIntervalSince1970: 10), buckets: ["A"])
            try RecentUploadDelivery.publish(cached, account: "a", defaults: defaults, lockURL: lockURL) {}
            try RecentUploadDelivery.uploaded(mutationRecord("A", "shared", time: 20), account: "a", defaults: defaults, lockURL: lockURL,
                deliveredAt: Date(timeIntervalSince1970: 20)) {}
            let delivery = try RecentUploadDelivery.publish(cached, account: "a", defaults: defaults, lockURL: lockURL) {}
            #expect(delivery.importedUploads)
            #expect(Set(delivery.snapshot.records.map(\.key)) == ["cached", "shared"])
            #expect(Set(MetadataSnapshotStore(defaults: defaults).load(account: "a")?.records.map(\.key) ?? []) == ["cached", "shared"])
            let widget = try JSONDecoder().decode(RecentUploadWidgetSnapshot.self, from: #require(defaults.data(forKey: "s3WidgetRecent.v1")))
            #expect(Set(widget.uploads.map(\.key)) == ["cached", "shared"])
        }
    }
    @Test func scanStartedBeforeDeliveryCannotEraseItAndLaterAuthoritativeScanCanRetireIt() throws {
        try withDefaults { defaults, lockURL in
            try RecentUploadDelivery.uploaded(mutationRecord("A", "shared"), account: "a", defaults: defaults, lockURL: lockURL,
                deliveredAt: Date(timeIntervalSince1970: 20)) {}
            let old = MetadataCatalogSnapshot(records: [], failedBuckets: [], refreshedAt: Date(timeIntervalSince1970: 10), buckets: ["A"])
            #expect(try RecentUploadDelivery.publish(old, account: "a", defaults: defaults, lockURL: lockURL, reload: {}).snapshot.records.count == 1)
            let fresh = MetadataCatalogSnapshot(records: [], failedBuckets: [], refreshedAt: Date(timeIntervalSince1970: 30), buckets: ["A"])
            #expect(try RecentUploadDelivery.publish(fresh, account: "a", defaults: defaults, lockURL: lockURL, reload: {}).snapshot.records.isEmpty)
            #expect(!defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("s3RecentUploads.pending.v1.") })
        }
    }
    @Test func failedBucketRefreshRetainsPendingUploadsDespiteANewerScanTimestamp() throws {
        try withDefaults { defaults, lockURL in
            try RecentUploadDelivery.uploaded(mutationRecord("A", "shared"), account: "a", defaults: defaults, lockURL: lockURL,
                deliveredAt: Date(timeIntervalSince1970: 20)) {}
            let denied = MetadataCatalogSnapshot(records: [], failedBuckets: [.init(bucket: "A", message: "denied")],
                refreshedAt: Date(timeIntervalSince1970: 30), buckets: ["A"])
            #expect(try RecentUploadDelivery.publish(denied, account: "a", defaults: defaults, lockURL: lockURL, reload: {}).snapshot.records.count == 1)
        }
    }
    @Test func acknowledgedDeleteOrReplacementClearsOnlyItsExactPendingUpload() throws {
        try withDefaults { defaults, lockURL in
            for bucket in ["A", "B"] {
                try RecentUploadDelivery.uploaded(mutationRecord(bucket, "same"), account: "a", defaults: defaults, lockURL: lockURL) {}
            }
            try RecentUploadDelivery.recordMutation(account: "a", removed: ("A", "same"), replacement: nil, defaults: defaults, lockURL: lockURL)
            let empty = MetadataCatalogSnapshot(records: [], failedBuckets: [], refreshedAt: nil)
            let remaining = try RecentUploadDelivery.publish(empty, account: "a", defaults: defaults, lockURL: lockURL) {}
            #expect(remaining.snapshot.records.map(\.bucket) == ["B"])
            let replacement = mutationRecord("B", "same", time: 99)
            try RecentUploadDelivery.recordMutation(account: "a", removed: nil, replacement: replacement, defaults: defaults, lockURL: lockURL)
            let final = try RecentUploadDelivery.publish(.init(records: [replacement], failedBuckets: [], refreshedAt: nil), account: "a", defaults: defaults, lockURL: lockURL) {}
            #expect(final.snapshot.records.first?.modified == replacement.modified)
            #expect(!final.importedUploads)
        }
    }
    @Test func pendingDeliveryKeysPreserveExactUnicodeAndAccountIdentity() throws {
        try withDefaults { defaults, lockURL in
            for key in ["caf\u{e9}", "cafe\u{301}"] {
                try RecentUploadDelivery.uploaded(mutationRecord("A", key), account: "a", defaults: defaults, lockURL: lockURL) {}
            }
            let empty = MetadataCatalogSnapshot(records: [], failedBuckets: [], refreshedAt: nil)
            #expect(try RecentUploadDelivery.publish(empty, account: "a", defaults: defaults, lockURL: lockURL, reload: {}).snapshot.records.count == 2)
            #expect(try RecentUploadDelivery.publish(empty, account: "other", defaults: defaults, lockURL: lockURL, reload: {}).snapshot.records.isEmpty)
        }
    }
    @Test func lateShareCompletionPreservesTheNewActiveWidgetAccount() throws {
        try withDefaults { defaults, lockURL in
            let current = MetadataCatalogSnapshot(records: [mutationRecord("new-bucket", "current.jpg")], failedBuckets: [], refreshedAt: .now)
            try RecentUploadDelivery.publish(current, account: "new-account", defaults: defaults, lockURL: lockURL) {}
            let before = defaults.data(forKey: "s3WidgetRecent.v1")
            var reloads = 0
            try RecentUploadDelivery.uploaded(mutationRecord("old-bucket", "dump/late.jpg"), account: "old-account", defaults: defaults, lockURL: lockURL) { reloads += 1 }
            #expect(defaults.data(forKey: "s3WidgetRecent.v1") == before)
            #expect(defaults.string(forKey: "recentUploadsAccount.v1") == "new-account")
            #expect(MetadataSnapshotStore(defaults: defaults).load(account: "old-account")?.records.first?.key == "dump/late.jpg")
            #expect(reloads == 1)
        }
    }

    @Test func filesystemLockProtectsRetirementEnvelopeWidgetAndPreferenceSynchronization() throws {
        try withDeliveryMemory { defaults, lockURL in
            try RecentUploadDelivery.uploaded(mutationRecord("A", "same"), account: "a", defaults: defaults,
                lockURL: lockURL, deliveredAt: Date(timeIntervalSince1970: 10)) {}
            var observed: Set<String> = []
            defaults.onOperation = { operation in
                observed.insert(operation)
                #expect((try? deliveryLockAvailable(lockURL)) == false)
            }
            let scan = MetadataCatalogSnapshot(records: [], failedBuckets: [], refreshedAt: Date(timeIntervalSince1970: 20), buckets: ["A"])
            try RecentUploadDelivery.publish(scan, account: "a", defaults: defaults, lockURL: lockURL) {
                #expect((try? deliveryLockAvailable(lockURL)) == true)
            }
            #expect(observed.isSuperset(of: ["synchronize", "enumerate", "remove", "envelope", "widget"]))
        }
    }

    @Test func synchronizationImportsANewerSameKeyDeliveryBeforeRetiringAnOldEntry() throws {
        try withDeliveryMemory { app, lockURL in
            let share = DeliveryMemoryDefaults()
            try RecentUploadDelivery.uploaded(mutationRecord("A", "same", time: 10), account: "a", defaults: app,
                lockURL: lockURL, deliveredAt: Date(timeIntervalSince1970: 10)) {}
            try RecentUploadDelivery.uploaded(mutationRecord("A", "same", time: 30), account: "a", defaults: share,
                lockURL: lockURL, deliveredAt: Date(timeIntervalSince1970: 30)) {}
            app.onSynchronize = {
                app.onSynchronize = nil
                app.values = share.values
            }
            let scan = MetadataCatalogSnapshot(records: [], failedBuckets: [], refreshedAt: Date(timeIntervalSince1970: 20), buckets: ["A"])
            let publication = try RecentUploadDelivery.publish(scan, account: "a", defaults: app, lockURL: lockURL) {}
            #expect(publication.snapshot.records.first?.modified == Date(timeIntervalSince1970: 30))
            #expect(app.values.keys.contains { $0.hasPrefix("s3RecentUploads.pending.v1.") })
            let widget = try JSONDecoder().decode(RecentUploadWidgetSnapshot.self, from: #require(app.data(forKey: "s3WidgetRecent.v1")))
            #expect(widget.uploads.first?.lastModified == Date(timeIntervalSince1970: 30))
        }
    }

    @Test func competingWriterCannotOvertakeRetirementOrLeaveAnOlderFinalWidget() throws {
        try withDeliveryMemory { defaults, lockURL in
            try RecentUploadDelivery.uploaded(mutationRecord("A", "same", time: 10), account: "a", defaults: defaults,
                lockURL: lockURL, deliveredAt: Date(timeIntervalSince1970: 10)) {}
            var blockedDuringEnumeration = false
            var blockedDuringWidgetWrite = false
            defaults.onOperation = { operation in
                if operation == "enumerate" { blockedDuringEnumeration = (try? deliveryLockAvailable(lockURL)) == false }
                if operation == "widget" { blockedDuringWidgetWrite = (try? deliveryLockAvailable(lockURL)) == false }
            }
            let scan = MetadataCatalogSnapshot(records: [], failedBuckets: [], refreshedAt: Date(timeIntervalSince1970: 20), buckets: ["A"])
            try RecentUploadDelivery.publish(scan, account: "a", defaults: defaults, lockURL: lockURL) {}
            #expect(blockedDuringEnumeration && blockedDuringWidgetWrite)
            defaults.onOperation = nil
            try RecentUploadDelivery.uploaded(mutationRecord("A", "same", time: 30), account: "a", defaults: defaults,
                lockURL: lockURL, deliveredAt: Date(timeIntervalSince1970: 30)) {}
            try RecentUploadDelivery.publish(scan, account: "a", defaults: defaults, lockURL: lockURL) {}
            let widget = try JSONDecoder().decode(RecentUploadWidgetSnapshot.self, from: #require(defaults.data(forKey: "s3WidgetRecent.v1")))
            #expect(widget.uploads.first?.lastModified == Date(timeIntervalSince1970: 30))
            #expect(MetadataSnapshotStore(defaults: defaults).load(account: "a")?.records.first?.modified == Date(timeIntervalSince1970: 30))
        }
    }

    @Test func coordinationFailuresCannotPublishOrReloadUncoordinatedState() throws {
        try withDeliveryMemory { defaults, lockURL in
            defaults.synchronizationSucceeds = false
            var reloads = 0
            #expect(throws: RecentUploadDeliveryError.self) {
                try RecentUploadDelivery.uploaded(mutationRecord("A", "same"), account: "a", defaults: defaults,
                    lockURL: lockURL) { reloads += 1 }
            }
            #expect(defaults.values.isEmpty && reloads == 0)
            defaults.synchronizationSucceeds = true
            let directoryAsLock = lockURL.deletingLastPathComponent()
            #expect(throws: RecentUploadDeliveryError.self) {
                try RecentUploadDelivery.publish(.init(records: [], failedBuckets: [], refreshedAt: nil), account: "a",
                    defaults: defaults, lockURL: directoryAsLock) { reloads += 1 }
            }
            #expect(defaults.values.isEmpty && reloads == 0)
            #expect((try? deliveryLockAvailable(lockURL)) == true)
        }
    }

    @Test func failedPublicationFlushesItsRecoveryJournalBeforeReleasingTheLock() throws {
        try withDeliveryMemory { defaults, lockURL in
            defaults.failWidgetVerification = true
            var flushes = 0
            var flushedJournal = false
            defaults.onSynchronize = {
                #expect((try? deliveryLockAvailable(lockURL)) == false)
                flushes += 1
                flushedJournal = defaults.values.keys.contains { $0.hasPrefix("s3RecentUploads.pending.v1.") }
            }
            #expect(throws: SecureConfigurationError.preferenceWriteNotVerified) {
                try RecentUploadDelivery.uploaded(mutationRecord("A", "recover", time: 30), account: "a", defaults: defaults,
                    lockURL: lockURL, deliveredAt: Date(timeIntervalSince1970: 30)) {}
            }
            #expect(flushes == 2 && flushedJournal)
            #expect((try? deliveryLockAvailable(lockURL)) == true)
            defaults.failWidgetVerification = false
            let stale = MetadataCatalogSnapshot(records: [], failedBuckets: [], refreshedAt: Date(timeIntervalSince1970: 20), buckets: ["A"])
            let recovered = try RecentUploadDelivery.publish(stale, account: "a", defaults: defaults, lockURL: lockURL) {}
            #expect(recovered.snapshot.records.first?.key == "recover")
        }
    }
}

private final class DeliveryMemoryDefaults: UserDefaults, @unchecked Sendable {
    nonisolated(unsafe) var values: [String: Any] = [:]
    nonisolated(unsafe) var onOperation: (@MainActor (String) -> Void)?
    nonisolated(unsafe) var onSynchronize: (@MainActor () -> Void)?
    nonisolated(unsafe) var synchronizationSucceeds = true
    nonisolated(unsafe) var failWidgetVerification = false
    init() { super.init(suiteName: "AuditMemoryDelivery-" + UUID().uuidString)! }
    override func synchronize() -> Bool {
        let operation = onOperation
        let synchronize = onSynchronize
        MainActor.assumeIsolated { operation?("synchronize"); synchronize?() }
        return synchronizationSucceeds
    }
    override func dictionaryRepresentation() -> [String: Any] {
        let operation = onOperation
        MainActor.assumeIsolated { operation?("enumerate") }
        return values
    }
    override func set(_ value: Any?, forKey key: String) {
        let operation = onOperation
        MainActor.assumeIsolated {
            if key == "s3WidgetRecent.v1" { operation?("widget") }
            if key.hasPrefix("s3MetadataCatalog.v1.") { operation?("envelope") }
        }
        values[key] = value
    }
    override func data(forKey key: String) -> Data? {
        if failWidgetVerification && key == "s3WidgetRecent.v1" { return nil }
        return values[key] as? Data
    }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func removeObject(forKey key: String) {
        let operation = onOperation
        MainActor.assumeIsolated { operation?("remove") }
        values.removeValue(forKey: key)
    }
}

@MainActor
private func withDeliveryMemory(_ operation: (DeliveryMemoryDefaults, URL) throws -> Void) throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AuditDeliveryLock-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    try operation(DeliveryMemoryDefaults(), folder.appendingPathComponent("delivery.lock"))
}

private func deliveryLockAvailable(_ url: URL) throws -> Bool {
    let descriptor = Darwin.open(url.path, O_RDWR | O_CLOEXEC)
    guard descriptor >= 0 else { throw RecentUploadDeliveryError.coordinationUnavailable(errno) }
    defer { Darwin.close(descriptor) }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return false }
    flock(descriptor, LOCK_UN)
    return true
}

import Foundation
import Testing
@testable import AuditCore

private func confirmedMutationDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("confirmed-mutation-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
private func confirmedMutationBody() -> MediaDownloadBody {
    let reader = MediaDataReader(Data([1, 2, 3]))
    return MediaDownloadBody(expectedBytes: 3, read: { await reader.read() })
}
@MainActor
private func confirmedRequest(_ kind: ObjectTransferRequest.Kind) -> ObjectTransferRequest {
    ObjectTransferRequest(kind: kind, source: .init(accountScope: "account", bucket: "bucket", key: "folder/original.txt"),
        destination: .init(accountScope: "account", bucket: "bucket", key: "target-" + UUID().uuidString + ".txt"))
}

@Suite("F12 acknowledged copy and delete invalidate exact media", .timeLimit(.minutes(1)))
@MainActor
struct F12ConfirmedMutationTests {
    @Test("Copy returns the destination's confirmed ETag/version and builds its actual metadata")
    func exactDestinationReceipt() async throws {
        let transport = TransferFixture(), request = confirmedRequest(.copy)
        var published: [ObjectCopyReceipt] = []
        let receipt = try await ObjectTransferCoordinator(transport: transport).execute(request) { published.append($0) }
        #expect(receipt.revision.etag == "\"destination\"")
        #expect(receipt.revision.etag != transport.revision.etag)
        #expect(receipt.revision.versionID == "copied-v2")
        #expect(published == [receipt])
        let record = receipt.metadata(bucket: request.destination.bucket, key: request.destination.key)
        #expect(record.etag == receipt.revision.etag)
        #expect(record.size == 17)
        #expect(record.modified == receipt.revision.lastModified)
        #expect(record.contentType == "text/plain")
        #expect(transport.deletes.isEmpty)
    }

    @Test("Source-delete failure still publishes completed destination and invalidates overwritten media")
    func partialMoveRetainsSourceAndReplacesDestinationCache() async throws {
        let directory = try confirmedMutationDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = MediaOriginalStore(directory: directory), transport = TransferFixture(), request = confirmedRequest(.move)
        transport.deleteFailure = .deleteFailed
        let oldDestination = MediaObjectIdentity(account: "account", bucket: "bucket", key: request.destination.key, etag: "old")
        let original = try await store.file(for: oldDestination) { confirmedMutationBody() }
        await store.release(original)
        let catalogs = ResourceLoader<String, MetadataCatalogSnapshot>(), listings = ResourceLoader<ListingQuery, MetadataListingPage>()
        let source = MetadataRecord(bucket: "bucket", key: request.source.key, size: 17, modified: .distantPast, etag: transport.revision.etag)
        catalogs.seed(.init(records: [source], failedBuckets: [], refreshedAt: .now), for: "account", refreshedAt: .now)
        var copiesPublished = 0
        let error = await #expect(throws: ObjectTransferError.self) {
            try await ObjectTransferCoordinator(transport: transport).execute(request) { receipt in
                await ConfirmedMediaMutation.apply(identity: oldDestination, isCurrent: { true }, invalidate: { identity in
                    await store.invalidate(account: identity.account, bucket: identity.bucket, key: identity.key)
                }, publish: {
                    copiesPublished += 1
                    _ = MetadataMutationProjection.apply(.init(account: "account",
                        replacement: receipt.metadata(bucket: "bucket", key: request.destination.key), removed: nil),
                        currentAccount: "account", catalogs: catalogs, listings: listings)
                })
            }
        }
        guard case .sourceRetainedAfterCopy = error else { Issue.record("Expected completed-copy/source-retained outcome"); return }
        #expect(copiesPublished == 1)
        #expect(try await store.cachedFile(for: oldDestination) == nil)
        #expect(FileManager.default.fileExists(atPath: original.url.path) == false)
        let records = try #require(catalogs.value(for: "account")?.records)
        #expect(records.contains { $0.key == request.source.key })
        #expect(records.first { $0.key == request.destination.key }?.etag == "\"destination\"")
        #expect(transport.deletes.isEmpty)
    }

    @Test("Cancellation after confirmed copy still acknowledges destination before retaining the source")
    func cancellationAfterCopy() async {
        let transport = TransferFixture(), request = confirmedRequest(.move)
        transport.afterCopy = { withUnsafeCurrentTask { $0?.cancel() } }
        var acknowledged = 0
        let task = Task {
            try await ObjectTransferCoordinator(transport: transport).execute(request) { _ in acknowledged += 1 }
        }
        let error = await #expect(throws: ObjectTransferError.self) { try await task.value }
        guard case .sourceRetainedAfterCopy = error else { Issue.record("Expected explicit partial outcome"); return }
        #expect(acknowledged == 1)
        #expect(transport.copies.count == 1)
        #expect(transport.deletes.isEmpty)
    }

    @Test("Confirmed deletion invalidates captured account only even after active account changes")
    func deletionAfterAccountChange() async throws {
        let directory = try confirmedMutationDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = MediaOriginalStore(directory: directory)
        let old = MediaObjectIdentity(account: "old", bucket: "bucket", key: "same.png", etag: "one")
        let current = MediaObjectIdentity(account: "current", bucket: "bucket", key: "same.png", etag: "one")
        let oldLease = try await store.file(for: old) { confirmedMutationBody() }
        let currentLease = try await store.file(for: current) { confirmedMutationBody() }
        await store.release(oldLease); await store.release(currentLease)
        var publications = 0
        await ConfirmedMediaMutation.apply(identity: old, isCurrent: { false }, invalidate: { identity in
            await store.invalidate(account: identity.account, bucket: identity.bucket, key: identity.key)
        }, publish: { publications += 1 })
        #expect(publications == 0)
        #expect(try await store.cachedFile(for: old) == nil)
        let retained = try #require(try await store.cachedFile(for: current))
        #expect(retained.url == currentLease.url)
        await store.release(retained)
    }

    @Test("Unconfirmed copy ETag cannot acknowledge success or authorize source deletion")
    func missingCopyReceiptETag() async {
        let transport = TransferFixture()
        transport.receipt = ObjectCopyReceipt(revision: .init(etag: nil, versionID: nil, lastModified: nil, size: 17))
        var acknowledgements = 0
        await #expect(throws: CopyEncryptionPolicyError.unconfirmedCopy) {
            try await ObjectTransferCoordinator(transport: transport).execute(confirmedRequest(.move)) { _ in acknowledgements += 1 }
        }
        #expect(acknowledgements == 0)
        #expect(transport.deletes.isEmpty)
    }
}

import Foundation
import Testing
@testable import AuditCore

@MainActor
final class TransferFixture: ObjectTransferTransport {
    enum Failure: Error { case denied, offline, copyFailed, deleteFailed }
    var revision = TransferObjectRevision(etag: "\"source\"", versionID: "v1", lastModified: Date(timeIntervalSince1970: 123), size: 17)
    var destination: TransferObjectPresence = .absent
    var headFailure: Failure?
    var copyFailure: Failure?
    var deleteFailure: Failure?
    var contextValid = true
    var afterCopy: (() -> Void)?
    var copyStarted: (() -> Void)?
    var copyGate: AsyncStream<Void>?
    var sourceChanged = false
    var heads: [TransferObjectLocation] = []
    var copies: [ObjectTransferRequest] = []
    var deletes: [TransferObjectLocation] = []

    func validateContext() throws {
        guard contextValid else { throw ObjectTransferError.contextChanged }
    }

    func head(_ location: TransferObjectLocation) async throws -> TransferObjectPresence {
        heads.append(location)
        if location.key == "folder/original.txt" {
            return sourceChanged ? .absent : .present(revision)
        }
        if let headFailure { throw headFailure }
        return destination
    }

    func copy(_ request: ObjectTransferRequest, sourceRevision: TransferObjectRevision) async throws {
        if let copyFailure { throw copyFailure }
        #expect(sourceRevision == revision)
        copyStarted?()
        if let copyGate { for await _ in copyGate { break } }
        copies.append(request)
        afterCopy?()
    }

    func delete(_ source: TransferObjectLocation, revision: TransferObjectRevision) async throws {
        if let deleteFailure { throw deleteFailure }
        #expect(revision == self.revision)
        deletes.append(source)
    }
}

private func transferRequest(_ kind: ObjectTransferRequest.Kind = .move, account: String = "account-A", destinationKey: String = "target.txt") -> ObjectTransferRequest {
    ObjectTransferRequest(kind: kind,
        source: TransferObjectLocation(accountScope: account, bucket: "bucket", key: "folder/original.txt"),
        destination: TransferObjectLocation(accountScope: account, bucket: "bucket", key: destinationKey))
}

@MainActor
struct N05ObjectTransferTests {
    @Test("App operations cannot both claim the same absent destination")
    func concurrentDestination() async throws {
        let fixture = TransferFixture()
        let started = AsyncStream<Void>.makeStream()
        let gate = AsyncStream<Void>.makeStream()
        fixture.copyStarted = { started.continuation.yield(()) }
        fixture.copyGate = gate.stream
        let request = transferRequest(.copy, destinationKey: "concurrent.txt")
        let first = Task { try await ObjectTransferCoordinator(transport: fixture).execute(request) }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        await #expect(throws: ObjectTransferError.destinationBusy) {
            try await ObjectTransferCoordinator(transport: fixture).execute(request)
        }
        gate.continuation.yield(())
        gate.continuation.finish()
        started.continuation.finish()
        try await first.value
        #expect(fixture.copies.count == 1)
        #expect(fixture.deletes.isEmpty)
    }

    @Test("Unicode normalization never shares replacement approval or revision identity")
    func exactUnicodeApproval() async {
        let nfc = transferRequest(destinationKey: "caf\u{e9}.txt")
        let nfd = transferRequest(destinationKey: "cafe\u{301}.txt")
        #expect(nfc != nfd)
        #expect(Set([nfc.destination, nfd.destination]).count == 2)
        let fixture = TransferFixture()
        fixture.destination = .present(fixture.revision)
        let approval = ObjectReplacementApproval(request: nfc, destinationRevision: fixture.revision)
        await #expect(throws: ObjectTransferError.self) {
            try await ObjectTransferCoordinator(transport: fixture).execute(nfd, approval: approval)
        }
        #expect(fixture.copies.isEmpty)
        let revision1 = TransferObjectRevision(etag: "caf\u{e9}", versionID: "v\u{e9}", lastModified: nil, size: 0)
        let revision2 = TransferObjectRevision(etag: "cafe\u{301}", versionID: "ve\u{301}", lastModified: nil, size: 0)
        #expect(revision1 != revision2)
    }

    @Test("Existing destination needs approval and declining performs no copy or delete")
    func collisionWithoutApproval() async throws {
        let fixture = TransferFixture()
        fixture.destination = .present(fixture.revision)
        let request = transferRequest()
        let error = await #expect(throws: ObjectTransferError.self) {
            try await ObjectTransferCoordinator(transport: fixture).execute(request)
        }
        #expect(error == .confirmationRequired(ObjectTransferConflict(request: request, destinationRevision: fixture.revision)))
        #expect(fixture.copies.isEmpty)
        #expect(fixture.deletes.isEmpty)
    }

    @Test("Approval authorizes only the observed account, operation and destination revision")
    func scopedApproval() async throws {
        let fixture = TransferFixture()
        fixture.destination = .present(fixture.revision)
        let request = transferRequest()
        let approval = ObjectReplacementApproval(request: request, destinationRevision: fixture.revision)
        try await ObjectTransferCoordinator(transport: fixture).execute(request, approval: approval)
        #expect(fixture.copies == [request])
        #expect(fixture.deletes == [request.source])

        for changed in [transferRequest(account: "account-B"), transferRequest(.copy), transferRequest(destinationKey: "other.txt")] {
            fixture.copies.removeAll()
            fixture.deletes.removeAll()
            await #expect(throws: ObjectTransferError.self) {
                try await ObjectTransferCoordinator(transport: fixture).execute(changed, approval: approval)
            }
            #expect(fixture.copies.isEmpty)
            #expect(fixture.deletes.isEmpty)
        }
        fixture.destination = .present(TransferObjectRevision(etag: "new", versionID: "v2", lastModified: .now, size: 22))
        await #expect(throws: ObjectTransferError.self) {
            try await ObjectTransferCoordinator(transport: fixture).execute(request, approval: approval)
        }
        #expect(fixture.copies.isEmpty)
    }

    @Test("Unknown HEAD errors never authorize writes", arguments: [TransferFixture.Failure.denied, .offline])
    func unknownHeadFailure(_ failure: TransferFixture.Failure) async {
        let fixture = TransferFixture()
        fixture.headFailure = failure
        await #expect(throws: TransferFixture.Failure.self) {
            try await ObjectTransferCoordinator(transport: fixture).execute(transferRequest())
        }
        #expect(fixture.copies.isEmpty)
        #expect(fixture.deletes.isEmpty)
    }

    @Test("Absent destination succeeds and copy preserves the source")
    func absentCopy() async throws {
        let fixture = TransferFixture()
        let request = transferRequest(.copy)
        try await ObjectTransferCoordinator(transport: fixture).execute(request)
        #expect(fixture.copies == [request])
        #expect(fixture.deletes.isEmpty)
    }

    @Test("Failed copy never removes source")
    func failedCopy() async {
        let fixture = TransferFixture()
        fixture.copyFailure = .copyFailed
        await #expect(throws: TransferFixture.Failure.self) {
            try await ObjectTransferCoordinator(transport: fixture).execute(transferRequest())
        }
        #expect(fixture.deletes.isEmpty)
    }

    @Test("Cancellation after completed copy retains source and reports partial completion")
    func cancelledAfterCopy() async {
        let fixture = TransferFixture()
        let task = Task {
            fixture.afterCopy = { withUnsafeCurrentTask { $0?.cancel() } }
            return await #expect(throws: ObjectTransferError.self) {
                try await ObjectTransferCoordinator(transport: fixture).execute(transferRequest())
            }
        }
        let error = await task.value
        guard case .sourceRetainedAfterCopy = error else {
            Issue.record("Expected a completed-copy/source-retained result")
            return
        }
        #expect(fixture.copies.count == 1)
        #expect(fixture.deletes.isEmpty)
    }

    @Test("Changed account or source after copy retains source", arguments: [false, true])
    func changedAfterCopy(_ accountChanged: Bool) async {
        let fixture = TransferFixture()
        fixture.afterCopy = {
            if accountChanged { fixture.contextValid = false } else { fixture.sourceChanged = true }
        }
        let error = await #expect(throws: ObjectTransferError.self) {
            try await ObjectTransferCoordinator(transport: fixture).execute(transferRequest())
        }
        guard case .sourceRetainedAfterCopy = error else { Issue.record("Expected partial completion"); return }
        #expect(fixture.copies.count == 1)
        #expect(fixture.deletes.isEmpty)
    }

    @Test("Failed delete reports completed destination and retained source")
    func failedDelete() async {
        let fixture = TransferFixture()
        fixture.deleteFailure = .deleteFailed
        let error = await #expect(throws: ObjectTransferError.self) {
            try await ObjectTransferCoordinator(transport: fixture).execute(transferRequest())
        }
        guard case .sourceRetainedAfterCopy = error else { Issue.record("Expected partial completion"); return }
        #expect(fixture.copies.count == 1)
        #expect(fixture.deletes.isEmpty)
    }

    @Test("Missing source ETag never authorizes an unconditional delete")
    func missingSourceETag() async {
        let fixture = TransferFixture()
        fixture.revision = TransferObjectRevision(etag: nil, versionID: "v1", lastModified: nil, size: 17)
        let error = await #expect(throws: ObjectTransferError.self) {
            try await ObjectTransferCoordinator(transport: fixture).execute(transferRequest())
        }
        guard case .sourceRetainedAfterCopy = error else { Issue.record("Expected partial completion"); return }
        #expect(fixture.copies.count == 1)
        #expect(fixture.deletes.isEmpty)
    }

    @Test("Keep both preserves exact prefix and rechecks new destination")
    func keepBoth() async throws {
        let fixture = TransferFixture()
        let request = transferRequest(destinationKey: "odd//文+%?#.txt").keepingBoth(suffix: "unique")
        #expect(request.destination.key == "odd//文+%?# copy unique.txt")
        try await ObjectTransferCoordinator(transport: fixture).execute(request)
        #expect(fixture.heads.contains(request.destination))
        #expect(fixture.copies == [request])
    }

    @Test("Copy source preserves reserved bytes, repeated slashes and version query")
    func encodedSource() {
        #expect(S3CopySource.encoded(bucket: "bucket", key: "a//文+%?#.txt", versionID: "v+/=?#") == "bucket/a//%E6%96%87%2B%25%3F%23.txt?versionId=v%2B%2F%3D%3F%23")
    }
}

@MainActor
struct F25SameObjectTransferTests {
    @Test("Canonically equivalent Unicode keys remain different S3 objects")
    func unicodeDestinations() {
        let nfc = "caf\u{e9}/original.txt"
        let nfd = "cafe\u{301}/original.txt"
        #expect(!S3TransferKeys.isSameDestination(sourceBucket: "bucket", sourceKey: nfc,
            destinationBucket: "bucket", destinationPrefix: S3TransferKeys.parentPrefix(of: nfd)))
        let source = TransferObjectLocation(accountScope: "account", bucket: "bucket", key: nfc)
        let destination = TransferObjectLocation(accountScope: "account", bucket: "bucket", key: nfd)
        #expect(source != destination)
    }

    @Test("Picker identifies root, nested and repeated-slash same destinations")
    func exactDestinationKeys() {
        for key in ["original.txt", "folder/original.txt", "folder//original.txt", "folder///文+?#%.txt"] {
            let prefix = S3TransferKeys.parentPrefix(of: key)
            #expect(S3TransferKeys.isSameDestination(sourceBucket: "bucket", sourceKey: key,
                destinationBucket: "bucket", destinationPrefix: prefix))
            #expect(!S3TransferKeys.isSameDestination(sourceBucket: "bucket", sourceKey: key,
                destinationBucket: "other-bucket", destinationPrefix: prefix))
            #expect(!S3TransferKeys.isSameDestination(sourceBucket: "bucket", sourceKey: key,
                destinationBucket: "bucket", destinationPrefix: prefix + "different/"))
        }
    }

    @Test("Generic same-object operations fail before any transport call", arguments: [ObjectTransferRequest.Kind.copy, .move, .rename])
    func rejectSameObject(_ kind: ObjectTransferRequest.Kind) async {
        let fixture = TransferFixture()
        let request = transferRequest(kind, destinationKey: "folder/original.txt")
        await #expect(throws: ObjectTransferError.sameObject) {
            try await ObjectTransferCoordinator(transport: fixture).execute(request)
        }
        #expect(fixture.heads.isEmpty)
        #expect(fixture.copies.isEmpty)
        #expect(fixture.deletes.isEmpty)
    }
}

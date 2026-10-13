import Foundation
import Testing
@testable import AuditCore

@MainActor
struct N01UploadPreparationTests {
    let original = UploadDestination(account: "account-A", bucket: "original", prefix: "folder//")
    let payload = PreparedUploadPayload(data: Data([1, 2, 3]), filename: "a +%?#.jpg", contentType: "image/jpeg")

    @Test func delayedRepresentationRetainsOriginalBucketAndPrefix() async throws {
        var visibleBucket = original.bucket
        var visiblePrefix = original.prefix
        var sent: (String, String)?
        try await UploadPreparation.perform(destination: original, load: {
            // The external input provider finishes after navigation has changed.
            visibleBucket = "different"
            visiblePrefix = "new/"
            await Task.yield()
            return payload
        }, isCurrentAccount: { true }, send: { payload, destination in
            sent = (destination.bucket, destination.key(for: payload.filename))
        })
        #expect(visibleBucket == "different")
        #expect(visiblePrefix == "new/")
        #expect(sent?.0 == "original")
        #expect(sent?.1 == "folder//a +%?#.jpg")
    }

    @Test func changedAccountCancelsBeforeMutation() async {
        var account = "account-A"
        var sends = 0
        await #expect(throws: UploadPreparationError.self) {
            try await UploadPreparation.perform(destination: original, load: {
                account = "account-B"
                return payload
            }, isCurrentAccount: { account == original.account }, send: { _, _ in sends += 1 })
        }
        #expect(sends == 0)
    }

    @Test func cancelledInputCannotStartUpload() async {
        var sends = 0
        let task = Task { @MainActor in
            try await UploadPreparation.perform(destination: original, load: {
                withUnsafeCurrentTask { $0?.cancel() }
                return payload
            }, isCurrentAccount: { true }, send: { _, _ in sends += 1 })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(sends == 0)
    }

    @Test func providerFailureAndMissingRepresentationDoNotMutate() async {
        var sends = 0
        for fails in [false, true] {
            await #expect(throws: (any Error).self) {
                try await UploadPreparation.perform(destination: original, load: {
                    if fails { throw CocoaError(.fileReadUnknown) }
                    return nil
                }, isCurrentAccount: { true }, send: { _, _ in sends += 1 })
            }
        }
        #expect(sends == 0)
    }

    @Test func accountScopeHasUnambiguousFieldsAndNoCredentialText() {
        let one = S3AccountScope.identifier(region: "a.b", accessKey: "c")
        let two = S3AccountScope.identifier(region: "a", accessKey: "b.c")
        #expect(one != two)
        #expect(one.count == 64)
    }
}

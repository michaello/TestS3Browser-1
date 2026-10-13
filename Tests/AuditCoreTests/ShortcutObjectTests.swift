import Foundation
import Testing
@testable import AuditCore

@Suite("N04 bucket-qualified Shortcuts identities")
struct N04ShortcutIdentityTests {
    @MainActor
    @Test("List/search identities round-trip into download/delete in the object's bucket")
    func chainedObjectsRetainBucket() async throws {
        let key = "folder//你好 +%?#.jpg"
        let output = try ["default", "other"].map {
            try ShortcutObjectReference(account: "account-A", bucket: $0, key: key)
        }
        #expect(Set(output.map(\.identifier)).count == 2)
        var requests: [ShortcutObjectReference] = []
        for listed in output {
            let restored = try ShortcutObjectReference(identifier: listed.identifier)
            let input = try ShortcutObjectRequest.resolve(
                file: restored, key: nil, bucket: nil, defaultBucket: "default", account: "account-A"
            )
            let downloaded = try await ShortcutObjectRequest.download(input) { key, bucket in
                requests.append(try ShortcutObjectReference(account: "account-A", bucket: bucket, key: key))
                return Data(bucket.utf8)
            }
            #expect(downloaded == Data(listed.bucket.utf8))
            try await ShortcutObjectRequest.delete(input, initialize: {}, operation: { key, bucket in
                requests.append(try ShortcutObjectReference(account: "account-A", bucket: bucket, key: key))
            })
        }
        #expect(requests == [output[0], output[0], output[1], output[1]])
        #expect(requests.allSatisfy { Array($0.key.utf8) == Array(key.utf8) })
    }

    @Test("Legacy keys use their explicit bucket or the configured default")
    func legacyInputs() throws {
        for (bucket, expected) in [(nil, "configured"), ("", "configured"), ("explicit", "explicit")] {
            let input = try ShortcutObjectRequest.resolve(
                file: nil, key: " /literal// +%?# ", bucket: bucket,
                defaultBucket: "configured", account: "account-A"
            )
            #expect(input.bucket == expected)
            #expect(input.key == " /literal// +%?# ")
        }
    }

    @Test("An old-account entity and conflicting explicit overrides fail before transport")
    func rejectsAmbiguousRouting() throws {
        let file = try ShortcutObjectReference(account: "account-A", bucket: "other", key: "key")
        #expect(throws: ShortcutObjectError.accountChanged) {
            try ShortcutObjectRequest.resolve(file: file, key: nil, bucket: nil, defaultBucket: "default", account: "account-B")
        }
        #expect(throws: ShortcutObjectError.conflictingInput) {
            try ShortcutObjectRequest.resolve(file: file, key: nil, bucket: "default", defaultBucket: "default", account: "account-A")
        }
        #expect(throws: ShortcutObjectError.conflictingInput) {
            try ShortcutObjectRequest.resolve(file: file, key: "different", bucket: nil, defaultBucket: "default", account: "account-A")
        }
    }

    @Test("Missing bucket/key and malformed persisted references are rejected")
    func invalidInputs() throws {
        #expect(throws: ShortcutObjectError.missingBucket) {
            try ShortcutObjectRequest.resolve(file: nil, key: "key", bucket: nil, defaultBucket: "", account: "account-A")
        }
        #expect(throws: ShortcutObjectError.missingKey) {
            try ShortcutObjectRequest.resolve(file: nil, key: nil, bucket: nil, defaultBucket: "default", account: "account-A")
        }
        for identifier in ["bucket/key", "s3-object-v1:a", "s3-object-v1:AA==.AA==.%%%%", "s3-object-v1:YWNj.Yg==."] {
            #expect(throws: (any Error).self) { try ShortcutObjectReference(identifier: identifier) }
        }
    }

    @Test("Canonically equivalent Unicode and delimiter-like fields remain distinct exact S3 identities")
    func exactUTF8Identity() throws {
        let composed = try ShortcutObjectReference(account: "a", bucket: "b", key: "é")
        let decomposed = try ShortcutObjectReference(account: "a", bucket: "b", key: "e\u{301}")
        #expect(composed != decomposed)
        #expect(Set([composed, decomposed]).count == 2)
        #expect(composed.identifier != decomposed.identifier)
        let restored = try ShortcutObjectReference(identifier: decomposed.identifier)
        #expect(Array(restored.key.utf8) == Array(decomposed.key.utf8))
        let splitA = try ShortcutObjectReference(account: "a/b", bucket: "c", key: "d")
        let splitB = try ShortcutObjectReference(account: "a", bucket: "b/c", key: "d")
        #expect(splitA.identifier != splitB.identifier)
        #expect(try ShortcutObjectReference(identifier: splitA.identifier) == splitA)
        #expect(try ShortcutObjectReference(identifier: splitB.identifier) == splitB)
    }
}

@Suite("N03 fresh Delete shortcut transport lifecycle")
@MainActor
struct N03ShortcutDeleteTests {
    @Test("Fresh transport initializes exactly once and deletes the requested fixture object")
    func initializesBeforeDeleting() async throws {
        let requested = try ShortcutObjectReference(account: "a", bucket: "other", key: "folder//file?+.txt")
        var initialized = false
        var events: [String] = []
        var objects = Set([requested])
        try await ShortcutObjectRequest.delete(requested, initialize: {
            #expect(!initialized)
            initialized = true
            events.append("initialize")
        }, operation: { key, bucket in
            #expect(initialized)
            events.append("delete")
            let deleted = try ShortcutObjectReference(account: "a", bucket: bucket, key: key)
            #expect(objects.remove(deleted) == requested)
        })
        #expect(events == ["initialize", "delete"])
        #expect(objects.isEmpty)
    }

    @Test("Initialization failure propagates and never deletes")
    func initializationFailure() async throws {
        let requested = try ShortcutObjectReference(account: "a", bucket: "b", key: "k")
        var deleted = false
        await #expect(throws: FixtureError.initialize) {
            try await ShortcutObjectRequest.delete(requested, initialize: { throw FixtureError.initialize }, operation: { _, _ in
                deleted = true
            })
        }
        #expect(!deleted)
    }

    @Test("Cancellation after initialization prevents the remote deletion")
    func cancellationAfterInitialization() async throws {
        let requested = try ShortcutObjectReference(account: "a", bucket: "b", key: "k")
        var deleted = false
        let task = Task { @MainActor in
            try await ShortcutObjectRequest.delete(requested, initialize: {
                withUnsafeCurrentTask { $0?.cancel() }
            }, operation: { _, _ in deleted = true })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!deleted)
    }

    @Test("Deletion failure propagates without a false success")
    func deleteFailure() async throws {
        let requested = try ShortcutObjectReference(account: "a", bucket: "b", key: "k")
        await #expect(throws: FixtureError.delete) {
            try await ShortcutObjectRequest.delete(requested, initialize: {}, operation: { _, _ in throw FixtureError.delete })
        }
    }

    private enum FixtureError: Error { case initialize, delete }
}

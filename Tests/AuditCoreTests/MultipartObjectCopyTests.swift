import Foundation
import Testing
@testable import AuditCore

@MainActor
private final class MultipartFixture: MultipartCopyTransport, ObjectTransferTransport {
    enum Failure: Error { case denied, part, complete, abort }
    let bytes = MultipartCopyPlan.singleCopyLimit + 1
    let properties = MultipartCopyProperties(metadata: ["original": "value"], headers: [
        "contentType": "video/mp4", "cacheControl": "max-age=60", "storageClass": "STANDARD_IA",
        "serverSideEncryption": "aws:kms", "ssekmsKeyId": "dummy-kms", "grantRead": "uri=\"public\""
    ], tags: [.init(key: "a?+", value: "b/%")])
    var events: [String] = []
    var parts: [MultipartCopyPart] = []
    var copiedProperties: MultipartCopyProperties?
    var failingPart: Int?
    var completionFails = false
    var abortFails = false
    var cancelAtPart: Int?
    var contextValid = true

    func validateContext() throws { if !contextValid { throw Failure.denied } }
    func create(properties: MultipartCopyProperties) async throws -> String {
        events.append("create"); copiedProperties = properties; return "upload-fixture"
    }
    func copyPart(uploadID: String, part: MultipartCopyPart) async throws -> String {
        #expect(uploadID == "upload-fixture")
        events.append("part-\(part.number)"); parts.append(part)
        if part.number == failingPart { throw Failure.part }
        if part.number == cancelAtPart { withUnsafeCurrentTask { $0?.cancel() } }
        return "etag-\(part.number)"
    }
    func complete(uploadID: String, parts: [MultipartCopiedPart]) async throws {
        events.append("complete")
        #expect(parts.map(\.number) == self.parts.map(\.number))
        #expect(parts.map(\.etag) == self.parts.map { "etag-\($0.number)" })
        if completionFails { throw Failure.complete }
    }
    func abort(uploadID: String) async throws {
        #expect(!Task.isCancelled)
        events.append("abort")
        if abortFails { throw Failure.abort }
    }
    func head(_ location: TransferObjectLocation) async throws -> TransferObjectPresence {
        location.key == "source" ? .present(.init(etag: "etag", versionID: "version", lastModified: .distantPast, size: Int(bytes))) : .absent
    }
    func copy(_ request: ObjectTransferRequest, sourceRevision: TransferObjectRevision) async throws {
        try await MultipartObjectCopy.perform(bytes: bytes, properties: properties, transport: self)
    }
    func delete(_ source: TransferObjectLocation, revision: TransferObjectRevision) async throws { events.append("delete") }
    func request() -> ObjectTransferRequest {
        .init(kind: .move, source: .init(accountScope: "A", bucket: "b", key: "source"),
              destination: .init(accountScope: "A", bucket: "b", key: UUID().uuidString))
    }
}

@MainActor
struct N32MultipartCopyTests {
    @Test func plansCoverEveryByteWithoutExceedingPartLimits() throws {
        for bytes: Int64 in [5_000_000_001, 5 * 1024 * 1024 * 1024 + 1, MultipartCopyPlan.maximumPartBytes * 10_000] {
            let plan = try MultipartCopyPlan(bytes: bytes)
            #expect(plan.parts.count <= 10_000)
            #expect(plan.parts.first?.firstByte == 0)
            #expect(plan.parts.last?.lastByte == bytes - 1)
            var offset: Int64 = 0
            for part in plan.parts {
                #expect(part.firstByte == offset)
                #expect(part.lastByte - part.firstByte + 1 <= MultipartCopyPlan.maximumPartBytes)
                offset = part.lastByte + 1
            }
            #expect(offset == bytes)
        }
        for bytes in [Int64.min, -1, 0, Int64.max] {
            #expect(throws: MultipartCopyError.self) { try MultipartCopyPlan(bytes: bytes) }
        }
    }

    @Test func moveDeletesOnlyAfterConfirmedCompletionAndPreservesProperties() async throws {
        let fixture = MultipartFixture()
        try await ObjectTransferCoordinator(transport: fixture).execute(fixture.request())
        #expect(fixture.copiedProperties == fixture.properties)
        #expect(fixture.events.suffix(2) == ["complete", "delete"])
        #expect(!fixture.events.contains("abort"))
        #expect(fixture.parts.count > 1)
        #expect(fixture.parts.last?.lastByte == fixture.bytes - 1)
    }

    @Test func failedPartOrCompletionAbortsAndRetainsMoveSource() async {
        for atCompletion in [false, true] {
            let fixture = MultipartFixture()
            fixture.completionFails = atCompletion
            fixture.failingPart = atCompletion ? nil : 2
            await #expect(throws: (any Error).self) {
                try await ObjectTransferCoordinator(transport: fixture).execute(fixture.request())
            }
            #expect(fixture.events.last == "abort")
            #expect(!fixture.events.contains("delete"))
            if !atCompletion { #expect(fixture.parts.count == 2) }
        }
    }

    @Test func cancelledCopyAbortsOutsideCancelledTaskAndRetainsSource() async {
        let fixture = MultipartFixture(); fixture.cancelAtPart = 2
        let task = Task { try await ObjectTransferCoordinator(transport: fixture).execute(fixture.request()) }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(fixture.parts.count == 2)
        #expect(fixture.events.last == "abort")
        #expect(!fixture.events.contains("complete"))
        #expect(!fixture.events.contains("delete"))
    }

    @Test func cleanupFailureIncludesUploadIDAndOriginalFailure() async {
        let fixture = MultipartFixture(); fixture.failingPart = 1; fixture.abortFails = true
        let error = await #expect(throws: MultipartCopyError.self) {
            try await ObjectTransferCoordinator(transport: fixture).execute(fixture.request())
        }
        #expect(error?.localizedDescription.contains("upload-fixture") == true)
        #expect(error?.localizedDescription.contains("source was retained") == true)
        #expect(!fixture.events.contains("delete"))
    }
}

struct N31CopyPropertyTests {
    @Test func ownerOnlyPermissionUsesCompatibleExplicitCannedACL() throws {
        let fields = try ObjectCopyProperties.aclHeaders(owner: "owner", destinationOwner: "owner",
            grants: [.init(permission: "FULL_CONTROL", granteeKind: "id", identifier: "owner")])
        #expect(fields == ["acl": "bucket-owner-full-control"])
    }

    @Test func customAndPublicGrantsRemainExplicitForBothCopyModes() throws {
        let fields = try ObjectCopyProperties.aclHeaders(owner: "owner", destinationOwner: "owner", grants: [
            .init(permission: "FULL_CONTROL", granteeKind: "id", identifier: "owner"),
            .init(permission: "READ", granteeKind: "uri", identifier: "http://acs.amazonaws.com/groups/global/AllUsers"),
            .init(permission: "READ", granteeKind: "id", identifier: "other-account"),
            .init(permission: "WRITE_ACP", granteeKind: "id", identifier: "admin")
        ])
        #expect(fields["acl"] == nil)
        #expect(fields["grantFullControl"] == "id=\"owner\"")
        #expect(fields["grantRead"]?.contains("other-account") == true)
        #expect(fields["grantRead"]?.contains("AllUsers") == true)
        #expect(fields["grantWriteACP"] == "id=\"admin\"")
    }

    @Test func crossOwnerCopyRetainsSourceOwnersGrant() throws {
        let fields = try ObjectCopyProperties.aclHeaders(owner: "source-owner", destinationOwner: "new-owner",
            grants: [.init(permission: "FULL_CONTROL", granteeKind: "id", identifier: "source-owner")])
        #expect(fields["acl"] == nil)
        #expect(fields["grantFullControl"] == "id=\"source-owner\"")
    }

    @Test func unknownOwnersOrUnsafeGrantsFailBeforeMutation() {
        #expect(throws: ObjectCopyPropertyError.self) {
            try ObjectCopyProperties.aclHeaders(owner: nil, destinationOwner: "owner", grants: [])
        }
        for grant in [ObjectCopyGrant(permission: "WRITE", granteeKind: "id", identifier: "x"),
                      .init(permission: "READ", granteeKind: "id", identifier: "x\"\nheader")] {
            #expect(throws: ObjectCopyPropertyError.self) {
                try ObjectCopyProperties.aclHeaders(owner: "owner", destinationOwner: "owner", grants: [grant])
            }
        }
    }

    @Test func multipartTagValuesAreEncodedWithoutChangingBytes() {
        let result = ObjectCopyProperties.tagging([.init(key: "a+?&", value: "/%é")])
        #expect(result == "a%2B%3F%26=%2F%25%C3%A9")
    }
}

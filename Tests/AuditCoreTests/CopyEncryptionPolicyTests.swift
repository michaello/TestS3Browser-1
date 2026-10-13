import Foundation
import Testing
@testable import AuditCore

@MainActor
private final class EncryptionCopyFixture: ObjectTransferTransport, MultipartCopyTransport {
    let sourceRevision = TransferObjectRevision(etag: "source-etag", versionID: "v1", lastModified: .distantPast, size: 12)
    var decision: CopyEncryptionDecision = .automatic
    var destination: TransferObjectPresence = .absent
    var returnedETag: String? = "confirmed-copy"
    var writes = 0, deletes = 0
    var singleHeaders: [String: String]?
    var multipartHeaders: [String: String]?
    var request: ObjectTransferRequest {
        .init(kind: .move, source: .init(accountScope: "account", bucket: "source", key: "a//café"),
            destination: .init(accountScope: "account", bucket: "target", key: "b"), generation: UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
    }
    var requirement: CopyEncryptionRequirement {
        .init(request: request, revision: sourceRevision, algorithm: "aws:kms", kmsKeyID: "fixture-key")
    }
    func validateContext() throws {}
    func head(_ location: TransferObjectLocation) async throws -> TransferObjectPresence {
        location == request.source ? .present(sourceRevision) : destination
    }
    func copy(_ request: ObjectTransferRequest, sourceRevision: TransferObjectRevision, destinationPresence: TransferObjectPresence) async throws -> ObjectCopyReceipt {
        let headers = try CopyEncryptionPolicy.headers(request: request, revision: sourceRevision,
            algorithm: "aws:kms", kmsKeyID: "fixture-key", decision: decision)
        singleHeaders = headers
        writes += 1
        let etag = try CopyEncryptionPolicy.requireCopyETag(returnedETag)
        return ObjectCopyReceipt(revision: .init(etag: etag, versionID: "copied", lastModified: .now, size: sourceRevision.size))
    }
    func delete(_ source: TransferObjectLocation, revision: TransferObjectRevision) async throws { deletes += 1 }
    func create(properties: MultipartCopyProperties) async throws -> String {
        multipartHeaders = properties.headers; writes += 1; return "fixture-upload"
    }
    func copyPart(uploadID: String, part: MultipartCopyPart) async throws -> String { "part-etag" }
    func complete(uploadID: String, parts: [MultipartCopiedPart], condition: MultipartDestinationCondition) async throws -> TransferObjectRevision {
        .init(etag: "completed-multipart", versionID: "copied", lastModified: .now, size: sourceRevision.size)
    }
    func abort(uploadID: String) async throws {}
}

@MainActor
struct N31EncryptionPolicyTests {
    @Test func unknownOrDeclinedContextChoiceCannotStartCopyOrSourceDeletion() async {
        let fixture = EncryptionCopyFixture()
        await #expect(throws: CopyEncryptionRequirement.self) {
            try await ObjectTransferCoordinator(transport: fixture).execute(fixture.request)
        }
        #expect(fixture.writes == 0)
        #expect(fixture.deletes == 0)
        // Cancelling/dismissing confirmation leaves the automatic decision unchanged.
        #expect(fixture.decision == .automatic)
    }

    @Test func cancelledConfirmationDoesNotMutateEvenWithAValidContextAvailable() async throws {
        let fixture = EncryptionCopyFixture()
        fixture.decision = .supplied(fixture.requirement, try .init(text: "{\"tenant\":\"fixture\"}"))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await ObjectTransferCoordinator(transport: fixture).execute(fixture.request)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(fixture.writes == 0)
        #expect(fixture.deletes == 0)
    }

    @Test func invalidJSONOrBase64CannotConstructAnApprovedContext() {
        for value in ["", "not-base64", "[]", "null", "{bad}", "{\"tenant\":4}", "{\"tenant\":{}}", Data("[]".utf8).base64EncodedString()] {
            #expect(throws: CopyEncryptionPolicyError.invalidContext) { try ValidatedCopyEncryptionContext(text: value) }
        }
    }

    @Test func suppliedContextPreservesExactJSONBytesAndReachesBothCopyHeaderPaths() async throws {
        let fixture = EncryptionCopyFixture()
        let json = "{\"tenant\":\"cafe\u{301}\",\"path\":\"a//b\"}"
        let context = try ValidatedCopyEncryptionContext(text: json)
        #expect(Data(base64Encoded: context.base64JSON) == Data(json.utf8))
        #expect(try ValidatedCopyEncryptionContext(text: context.base64JSON) == context)
        fixture.decision = .supplied(fixture.requirement, context)
        try await ObjectTransferCoordinator(transport: fixture).execute(fixture.request)
        #expect(fixture.singleHeaders?["ssekmsEncryptionContext"] == context.base64JSON)
        #expect(fixture.deletes == 1)
        let properties = MultipartCopyProperties(headers: try CopyEncryptionPolicy.headers(request: fixture.request,
            revision: fixture.sourceRevision, algorithm: "aws:kms", kmsKeyID: "fixture-key", decision: fixture.decision))
        try await MultipartObjectCopy.perform(bytes: MultipartCopyPlan.singleCopyLimit + 1, properties: properties,
            destination: .absent, transport: fixture)
        #expect(fixture.multipartHeaders?["ssekmsEncryptionContext"] == context.base64JSON)
    }

    @Test func explicitDefaultChoiceRequiresThePermissionChangeDisclosureAndExactRequirement() throws {
        let fixture = EncryptionCopyFixture()
        let headers = try CopyEncryptionPolicy.headers(request: fixture.request, revision: fixture.sourceRevision,
            algorithm: "aws:kms", kmsKeyID: "fixture-key", decision: .useDefault(fixture.requirement))
        #expect(headers["ssekmsEncryptionContext"] == nil)
        #expect(CopyEncryptionRequirement.defaultDisclosure.contains("discards any original additional KMS context"))
        #expect(CopyEncryptionRequirement.defaultDisclosure.contains("permission policies"))
        #expect(throws: CopyEncryptionRequirement.self) {
            try CopyEncryptionPolicy.headers(request: fixture.request.keepingBoth(), revision: fixture.sourceRevision,
                algorithm: "aws:kms", kmsKeyID: "fixture-key", decision: .useDefault(fixture.requirement))
        }
    }

    @Test func sourceRevisionGenerationAndKMSKeyChangesInvalidateContextConsent() throws {
        let fixture = EncryptionCopyFixture()
        let approved = CopyEncryptionDecision.supplied(fixture.requirement, try .init(text: "{}"))
        let changedRevision = TransferObjectRevision(etag: "new", versionID: "v2", lastModified: .now, size: 12)
        #expect(throws: CopyEncryptionRequirement.self) {
            try CopyEncryptionPolicy.headers(request: fixture.request, revision: changedRevision,
                algorithm: "aws:kms", kmsKeyID: "fixture-key", decision: approved)
        }
        var changedRequest = fixture.request; changedRequest.generation = UUID()
        #expect(throws: CopyEncryptionRequirement.self) {
            try CopyEncryptionPolicy.headers(request: changedRequest, revision: fixture.sourceRevision,
                algorithm: "aws:kms", kmsKeyID: "fixture-key", decision: approved)
        }
        #expect(throws: CopyEncryptionRequirement.self) {
            try CopyEncryptionPolicy.headers(request: fixture.request, revision: fixture.sourceRevision,
                algorithm: "aws:kms", kmsKeyID: "different-key", decision: approved)
        }
    }

    @Test func encryptionConsentNeverAuthorizesDestinationReplacement() async throws {
        let fixture = EncryptionCopyFixture()
        fixture.decision = .supplied(fixture.requirement, try .init(text: "{}"))
        fixture.destination = .present(.init(etag: "destination-etag", versionID: nil, lastModified: .now, size: 1))
        await #expect(throws: ObjectTransferError.self) {
            try await ObjectTransferCoordinator(transport: fixture).execute(fixture.request)
        }
        #expect(fixture.writes == 0)
        #expect(fixture.deletes == 0)
    }

    @Test func emptyOrMissingCopyAcknowledgementRetainsSource() async {
        for etag: String? in [nil, ""] {
            let fixture = EncryptionCopyFixture()
            fixture.decision = .useDefault(fixture.requirement)
            fixture.returnedETag = etag
            await #expect(throws: CopyEncryptionPolicyError.unconfirmedCopy) {
                try await ObjectTransferCoordinator(transport: fixture).execute(fixture.request)
            }
            #expect(fixture.writes == 1)
            #expect(fixture.deletes == 0)
        }
    }

    @Test func nonKMSEncryptionNeedsNoContextAndMissingKMSKeyFailsSafely() throws {
        let fixture = EncryptionCopyFixture()
        #expect(try CopyEncryptionPolicy.headers(request: fixture.request, revision: fixture.sourceRevision,
            algorithm: "AES256", kmsKeyID: nil, decision: .automatic).isEmpty)
        #expect(throws: CopyEncryptionPolicyError.missingKMSKey) {
            try CopyEncryptionPolicy.headers(request: fixture.request, revision: fixture.sourceRevision,
                algorithm: "aws:kms", kmsKeyID: nil, decision: .automatic)
        }
        #expect(throws: CopyEncryptionRequirement.self) {
            try CopyEncryptionPolicy.headers(request: fixture.request, revision: fixture.sourceRevision,
                algorithm: "aws:kms:dsse", kmsKeyID: "fixture-key", decision: .automatic)
        }
    }
}

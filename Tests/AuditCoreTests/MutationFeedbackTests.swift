import Foundation
import Testing
@testable import AuditCore

@MainActor
struct N37DumpDeleteFeedbackTests {
    @Test func failedDeleteRetainsRowAndRetryPublishesSuccess() async {
        let state = MutationFeedback()
        var rows = ["object"], requests = 0
        #expect(await state.perform(action: {
            requests += 1; throw CocoaError(.fileWriteNoPermission)
        }, didSucceed: { rows.removeAll() }) == false)
        #expect(rows == ["object"])
        #expect(!state.isRunning)
        #expect(state.errorMessage != nil)
        #expect(await state.perform(action: { requests += 1 }, didSucceed: { rows.removeAll() }))
        #expect(rows.isEmpty)
        #expect(requests == 2)
        #expect(state.errorMessage == nil)
    }

    @Test func duplicateMutationCannotStartDuringActiveRequest() async {
        let state = MutationFeedback(), gate = AsyncStream<Void>.makeStream()
        var calls = 0
        let task = Task { await state.perform { calls += 1; for await _ in gate.stream { break } } }
        while !state.isRunning { await Task.yield() }
        #expect(await state.perform { calls += 1 } == false)
        #expect(calls == 1)
        gate.continuation.yield(()); gate.continuation.finish()
        #expect(await task.value)
        #expect(!state.isRunning)
    }

    @Test func cancelledBeforeStartCannotDeleteOrPublishFailure() async {
        let state = MutationFeedback()
        var calls = 0
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await state.perform { calls += 1 }
        }
        #expect(await task.value == false)
        #expect(calls == 0)
        #expect(!state.isRunning)
        #expect(state.errorMessage == nil)
    }
}

@MainActor
struct N48FolderValidationTests {
    @Test(arguments: ["", "   \n", "a/b", "null\0name", String(repeating: "路径", count: 200)])
    func invalidNamesKeepInputAndShowErrorWithoutSending(_ input: String) async {
        let state = FolderCreationState(); state.name = input
        var calls = 0
        #expect(await state.create(prefix: "folder/") { _ in calls += 1 } == false)
        #expect(calls == 0)
        #expect(state.name == input)
        #expect(state.mutation.errorMessage != nil)
        #expect(!state.mutation.isRunning)
    }

    @Test func correctedNameCanBeSubmittedWithExactSpecialBytes() async {
        let state = FolderCreationState(); state.name = "bad/name"
        #expect(await state.create(prefix: "a//") { _ in Issue.record("Invalid name sent") } == false)
        state.name = "a%2Fb+?#é"
        var sent: String?
        #expect(await state.create(prefix: "a//") { sent = $0 })
        #expect(sent?.utf8.elementsEqual(state.name.utf8) == true)
        #expect(state.mutation.errorMessage == nil)
    }

    @Test func fullPrefixByteLimitAndRemoteFailureAreActionable() async throws {
        #expect(throws: FolderNameError.self) {
            try FolderNameValidation.name("folder", prefix: String(repeating: "x", count: 1020))
        }
        let state = FolderCreationState(); state.name = "folder"
        #expect(await state.create(prefix: "") { _ in throw CocoaError(.fileWriteNoPermission) } == false)
        #expect(state.mutation.errorMessage != nil)
        #expect(state.name == "folder")
    }
}

struct N46ACLAccessSummaryTests {
    let owner = ObjectCopyGrant(permission: "FULL_CONTROL", granteeKind: "id", identifier: "owner")

    @Test func ownerOnlyACLDoesNotClaimBucketPolicyPrivacy() {
        #expect(ObjectACLAccessSummary.summarize(ownerID: "owner", grants: [owner]) == "Owner only (ACL)")
    }
    @Test func anotherCanonicalAccountCannotBeLabeledPrivate() {
        let other = ObjectCopyGrant(permission: "READ", granteeKind: "id", identifier: "another-account")
        #expect(ObjectACLAccessSummary.summarize(ownerID: "owner", grants: [owner, other]) == "Custom principals (ACL)")
    }
    @Test func publicReadAndPublicAdministrativeGrantHaveDifferentSummaries() {
        let uri = "http://acs.amazonaws.com/groups/global/AllUsers"
        #expect(ObjectACLAccessSummary.summarize(ownerID: "owner", grants: [owner,
            .init(permission: "READ", granteeKind: "uri", identifier: uri)]) == "Public read (ACL)")
        #expect(ObjectACLAccessSummary.summarize(ownerID: "owner", grants: [owner,
            .init(permission: "READ_ACP", granteeKind: "uri", identifier: uri)]) == "Public grants (ACL)")
    }
    @Test func unknownOrEmptyACLRemainsUnknown() {
        #expect(ObjectACLAccessSummary.summarize(ownerID: nil, grants: [owner]) == "Unknown (ACL)")
        #expect(ObjectACLAccessSummary.summarize(ownerID: "owner", grants: []) == "Unknown (ACL)")
    }
    @Test func byteDistinctPrincipalIsNeverMergedWithOwner() {
        #expect(ObjectACLAccessSummary.summarize(ownerID: "é", grants: [
            .init(permission: "READ", granteeKind: "id", identifier: "e\u{301}")]) == "Custom principals (ACL)")
    }
}

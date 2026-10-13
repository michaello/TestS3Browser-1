import Foundation
import Testing
@testable import AuditCore

private func selectedObject(_ bucket: String, _ key: String = "same.txt") -> LocalObjectIdentity {
    LocalObjectIdentity(account: "account", bucket: bucket, key: key)
}

@MainActor
struct AuditN19 {
    enum Failure: Error { case denied }
    @Test func secondActivationCannotStartDuplicateDeletesOrChangeTheRunningSelection() async {
        let deletion = BulkObjectDeletion()
        let object = selectedObject("bucket")
        deletion.toggle(object); deletion.captureConfirmation()
        let started = AsyncStream<Void>.makeStream()
        var release: CheckedContinuation<Void, Never>?
        var requests = 0
        #expect(deletion.start { _ in
            requests += 1
            await withCheckedContinuation { release = $0; started.continuation.yield(()) }
        })
        var events = started.stream.makeAsyncIterator(); _ = await events.next()
        deletion.toggle(selectedObject("other")); deletion.captureConfirmation()
        #expect(deletion.start { _ in requests += 1 } == false)
        #expect(deletion.isDeleting)
        #expect(deletion.selected == [object])
        release?.resume()
        await deletion.waitForCompletion()
        #expect(requests == 1)
        #expect(deletion.isDeleting == false)
        #expect(deletion.selected.isEmpty)
    }
    @Test func partialFailureRetainsOnlyTheFailedIdentitiesForRetry() async {
        let deletion = BulkObjectDeletion()
        let success = selectedObject("first"), failed = selectedObject("second")
        deletion.toggle(success); deletion.toggle(failed); deletion.captureConfirmation()
        deletion.start { target in if target == failed { throw Failure.denied } }
        await deletion.waitForCompletion()
        #expect(deletion.selected == [failed])
        #expect(deletion.failureMessage?.contains("second/same.txt") == true)
        deletion.captureConfirmation()
        var retried: [LocalObjectIdentity] = []
        deletion.start { retried.append($0) }
        await deletion.waitForCompletion()
        #expect(retried == [failed])
        #expect(deletion.selected.isEmpty)
    }
    @Test func cancelledOldAccountCannotChangeTheReplacementSelection() async {
        let deletion = BulkObjectDeletion()
        deletion.toggle(selectedObject("old")); deletion.captureConfirmation()
        let started = AsyncStream<Void>.makeStream()
        var release: CheckedContinuation<Void, Never>?
        deletion.start { _ in await withCheckedContinuation { release = $0; started.continuation.yield(()) } }
        var events = started.stream.makeAsyncIterator(); _ = await events.next()
        let old = deletion.cancel(clearSelection: true)
        let replacement = LocalObjectIdentity(account: "new-account", bucket: "new", key: "same.txt")
        deletion.toggle(replacement)
        release?.resume()
        await old?.value
        #expect(deletion.selected == [replacement])
        #expect(deletion.isDeleting == false)
        #expect(deletion.failureMessage == nil)
    }
}

@MainActor
struct AuditN21 {
    @Test func confirmationDeletesTheFrozenSelectionAfterVisibleQueryChanges() async {
        let deletion = BulkObjectDeletion()
        let first = selectedObject("A"), second = selectedObject("B")
        deletion.toggle(first); deletion.toggle(second); deletion.captureConfirmation()
        let visibleAfterSearch = [first]
        #expect(visibleAfterSearch.count == 1)
        #expect(deletion.confirmationCount == 2)
        var requested: Set<LocalObjectIdentity> = []
        deletion.start { requested.insert($0) }
        await deletion.waitForCompletion()
        #expect(requested == [first, second])
        #expect(deletion.selected.isEmpty)
    }
    @Test func selectionCannotMutateAnAlreadyPresentedConfirmation() async {
        let deletion = BulkObjectDeletion()
        let first = selectedObject("A")
        deletion.toggle(first); deletion.captureConfirmation()
        deletion.toggle(selectedObject("B")); deletion.toggle(first)
        #expect(deletion.confirmation == [first])
        #expect(deletion.selected == [first])
        deletion.dismissConfirmation()
        deletion.toggle(first)
        #expect(deletion.selected.isEmpty)
    }
    @Test func exactUnicodeBucketAndKeyIdentitiesSurviveTheSelectionSnapshot() async {
        let deletion = BulkObjectDeletion()
        let first = selectedObject("bucket", "caf\u{e9}.txt"), second = selectedObject("bucket", "cafe\u{301}.txt")
        deletion.toggle(first); deletion.toggle(second); deletion.captureConfirmation()
        #expect(deletion.confirmationCount == 2)
        var requested: Set<LocalObjectIdentity> = []
        deletion.start { requested.insert($0) }
        await deletion.waitForCompletion()
        #expect(requested == [first, second])
    }
}

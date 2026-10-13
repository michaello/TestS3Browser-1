import Foundation
import Testing
@testable import AuditCore

@MainActor
struct N18TransferDismissalTests {
    @Test func cancellingPickerCannotHandOffQueuedWork() {
        var selection = DestinationSelection()
        selection.cancel()
        #expect(selection.confirm("folder/", canConfirm: true) == nil)
        #expect(selection.hasDecided)
    }
    @Test func confirmationHandsOffExactDestinationOnlyOnceAndDismissalDoesNotClaimRollback() {
        var selection = DestinationSelection()
        #expect(selection.confirm("stale/", canConfirm: false) == nil)
        let prefix = "folder//a?%é/"
        #expect(selection.confirm(prefix, canConfirm: true)?.utf8.elementsEqual(prefix.utf8) == true)
        selection.cancel()
        if case .confirmed(let captured) = selection.phase { #expect(captured.utf8.elementsEqual(prefix.utf8)) }
        else { Issue.record("Dismissal changed confirmed intent") }
        #expect(selection.confirm("another/", canConfirm: true) == nil)
    }
    @Test func cancelledRemoteTaskCannotBeginCopyOrDelete() async {
        let fixture = TransferFixture()
        let request = ObjectTransferRequest(kind: .move,
            source: .init(accountScope: "A", bucket: "b", key: "folder/original.txt"),
            destination: .init(accountScope: "A", bucket: "b", key: "other.txt"))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await ObjectTransferCoordinator(transport: fixture).execute(request)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(fixture.heads.isEmpty)
        #expect(fixture.copies.isEmpty)
        #expect(fixture.deletes.isEmpty)
    }
}

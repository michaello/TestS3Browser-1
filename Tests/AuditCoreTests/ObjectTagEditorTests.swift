import Foundation
import Testing
@testable import AuditCore

@MainActor
struct AuditN02 {
    enum Failure: Error { case denied }

    @Test func unknownAndFailedReadsCannotReplaceTags() async {
        let editor = ObjectTagEditor()
        var writes = 0
        editor.beginEditing()
        #expect(editor.isEditing == false)
        #expect(await editor.save { _ in writes += 1 } == false)
        await editor.load { throw Failure.denied }
        editor.beginEditing()
        editor.draft = [ObjectTag(key: "new", value: "value")]
        #expect(editor.canEdit == false)
        #expect(await editor.save { _ in writes += 1 } == false)
        #expect(writes == 0)
        if case .failed = editor.loadState {} else { Issue.record("Read error was hidden") }
    }

    @Test func retryPreservesUneditedRemoteTags() async {
        let editor = ObjectTagEditor()
        await editor.load { throw Failure.denied }
        let old = ObjectTag(key: "owner", value: "existing")
        await editor.load { [old] }
        editor.beginEditing()
        editor.draft.append(ObjectTag(key: "new", value: "value"))
        var remote: [ObjectTag] = []
        #expect(await editor.save { remote = $0 })
        #expect(remote == [old, ObjectTag(key: "new", value: "value")])
        #expect(editor.tags == remote)
        #expect(editor.isEditing == false)
    }

    @Test func successfulEmptyReadAllowsFirstTag() async {
        let editor = ObjectTagEditor()
        await editor.load { [] }
        #expect(editor.canEdit)
        editor.beginEditing()
        editor.draft = [ObjectTag(key: "one", value: "1"), ObjectTag(key: " \n", value: "ignored")]
        var remote: [ObjectTag] = []
        #expect(await editor.save { remote = $0 })
        #expect(remote == [ObjectTag(key: "one", value: "1")])
    }

    @Test func writeFailureRetainsDraftAndRemoteSnapshot() async {
        let editor = ObjectTagEditor()
        let old = ObjectTag(key: "owner", value: "existing")
        await editor.load { [old] }
        editor.beginEditing()
        editor.draft.append(ObjectTag(key: "new", value: "value"))
        #expect(await editor.save { _ in throw Failure.denied } == false)
        #expect(editor.tags == [old])
        #expect(editor.draft.count == 2)
        #expect(editor.isEditing)
        #expect(editor.isSaving == false)
        #expect(editor.saveError != nil)
    }

    @Test func cancelledReadDoesNotBecomeEmptySuccess() async {
        let editor = ObjectTagEditor()
        await editor.load { throw CancellationError() }
        #expect(editor.loadState == .idle)
        #expect(editor.canEdit == false)
    }

    @Test func oldReadCannotAuthorizeEditingAfterNewFailure() async {
        let editor = ObjectTagEditor()
        var release: CheckedContinuation<[ObjectTag], Never>?
        let old = Task { await editor.load { await withCheckedContinuation { release = $0 } } }
        while release == nil { await Task.yield() }
        await editor.load { throw Failure.denied }
        release?.resume(returning: [])
        await old.value
        #expect(editor.canEdit == false)
        if case .failed = editor.loadState {} else { Issue.record("Stale result replaced failure") }
    }
}

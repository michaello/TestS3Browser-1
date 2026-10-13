import Foundation
import Observation

struct ObjectTag: Equatable, Sendable {
    var key: String
    var value: String
}

/// Owns the distinction between unknown remote tags and a successfully empty set.
@MainActor @Observable
final class ObjectTagEditor {
    enum LoadState: Equatable {
        case idle, loading, loaded, failed(String)
    }

    private(set) var loadState: LoadState = .idle
    private(set) var tags: [ObjectTag] = []
    var draft: [ObjectTag] = []
    private(set) var isEditing = false
    private(set) var isSaving = false
    var saveError: String?
    @ObservationIgnored private var generation = UUID()

    var canEdit: Bool { loadState == .loaded && !isSaving }
    var canSave: Bool { canEdit && isEditing }

    func load(using read: () async throws -> [ObjectTag]) async {
        guard !isSaving else { return }
        let request = UUID()
        generation = request
        loadState = .loading
        isEditing = false
        do {
            let result = try await read()
            try Task.checkCancellation()
            guard generation == request else { return }
            tags = result
            loadState = .loaded
        } catch {
            guard generation == request else { return }
            loadState = error is CancellationError ? .idle : .failed(error.localizedDescription)
        }
    }

    func beginEditing() {
        guard canEdit else { return }
        draft = tags
        saveError = nil
        isEditing = true
    }

    func cancelEditing() {
        guard !isSaving else { return }
        isEditing = false
        draft = []
    }

    @discardableResult
    func save(using replace: ([ObjectTag]) async throws -> Void) async -> Bool {
        // Protect the mutation itself, not just the button's enabled state.
        guard canSave else { return false }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        let replacement = draft.filter { !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        do {
            try Task.checkCancellation()
            try await replace(replacement)
            tags = replacement
            isEditing = false
            return true
        } catch {
            if !(error is CancellationError) { saveError = error.localizedDescription }
            return false
        }
    }
}

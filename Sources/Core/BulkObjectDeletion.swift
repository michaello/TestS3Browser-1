import Foundation
import Observation

private struct DeletionOutcome: Sendable {
    let identity: LocalObjectIdentity
    let error: String?
}

/// The selection and confirmation contain complete identities, independent of the
/// visible query. One owned task controls all destructive requests in a batch.
@Observable @MainActor
final class BulkObjectDeletion {
    private(set) var selected: Set<LocalObjectIdentity> = []
    private(set) var confirmation: [LocalObjectIdentity]?
    private(set) var isDeleting = false
    private(set) var failureMessage: String?
    private var task: Task<Void, Never>?
    private var operationID: UUID?
    var confirmationCount: Int { confirmation?.count ?? selected.count }

    func toggle(_ identity: LocalObjectIdentity) {
        guard !isDeleting, confirmation == nil else { return }
        if selected.contains(identity) { selected.remove(identity) } else { selected.insert(identity) }
    }
    func clearSelection() {
        guard !isDeleting else { return }
        selected.removeAll(); confirmation = nil
    }
    func captureConfirmation() {
        guard !isDeleting else { return }
        confirmation = selected.sorted { $0.storageKey < $1.storageKey }
    }
    func dismissConfirmation() { confirmation = nil }

    @discardableResult
    func start(delete: @escaping @MainActor @Sendable (LocalObjectIdentity) async throws -> Void,
               completion: @escaping @MainActor @Sendable () -> Void = {}) -> Bool {
        guard !isDeleting, let snapshot = confirmation, !snapshot.isEmpty else { return false }
        let identifier = UUID()
        operationID = identifier
        isDeleting = true
        failureMessage = nil
        confirmation = nil
        task = Task { @MainActor [self] in
            var failed: Set<LocalObjectIdentity> = []
            var messages: [String] = []
            await withTaskGroup(of: DeletionOutcome.self) { group in
                for identity in snapshot {
                    group.addTask {
                        do {
                            try Task.checkCancellation()
                            try await delete(identity)
                            return DeletionOutcome(identity: identity, error: nil)
                        } catch { return DeletionOutcome(identity: identity, error: error.localizedDescription) }
                    }
                }
                for await outcome in group {
                    if let error = outcome.error {
                        failed.insert(outcome.identity)
                        messages.append(outcome.identity.bucket + "/" + outcome.identity.key + ": " + error)
                    }
                }
            }
            guard operationID == identifier else { return }
            selected = failed
            failureMessage = messages.isEmpty ? nil : messages.joined(separator: "\n")
            isDeleting = false
            task = nil
            completion()
        }
        return true
    }

    func waitForCompletion() async { await task?.value }
    @discardableResult
    func cancel(clearSelection: Bool = false) -> Task<Void, Never>? {
        let cancelled = task
        cancelled?.cancel(); task = nil; operationID = nil
        isDeleting = false; confirmation = nil; failureMessage = nil
        if clearSelection { selected.removeAll() }
        return cancelled
    }
}

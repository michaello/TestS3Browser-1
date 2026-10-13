import Foundation
import Observation

@MainActor @Observable
final class VersionRestoreFlow {
    enum Phase: Equatable { case idle, restoring, refreshing, complete, failed }
    private(set) var phase: Phase = .idle
    private(set) var activeVersion: String?
    private(set) var errorMessage: String?
    func clearError() { errorMessage = nil }

    func restore(_ version: String, isCurrent: () -> Bool,
                 write: () async throws -> Void, invalidate: () async -> Void,
                 content: () async throws -> Void, metadata: () async throws -> Void,
                 versions: () async throws -> Void) async {
        guard activeVersion == nil else { return }
        activeVersion = version; errorMessage = nil; phase = .restoring
        defer { activeVersion = nil }
        do {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            try await write()
            // Invalidation follows a successful remote write even if the caller then cancels.
            await invalidate()
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            phase = .refreshing
            try await content()
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            try await metadata()
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            try await versions()
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            phase = .complete
        } catch {
            if error is CancellationError { phase = .idle }
            else { phase = .failed; errorMessage = error.localizedDescription }
        }
    }
}

struct PreviewRefreshError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

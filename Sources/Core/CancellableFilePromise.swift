import Foundation
import os

/// Resolves a provider callback once, cancels its Progress, and disposes late files.
final class CancellableFilePromise<Value: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Value, any Error>?
        var progress: Progress?
        var finished = false
        var cancelled = false
        var adoptedFile: URL?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let dispose: @Sendable (Value) -> Void
    private let identity: @Sendable (Value) -> URL
    init(identity: @escaping @Sendable (Value) -> URL, dispose: @escaping @Sendable (Value) -> Void) {
        self.identity = identity
        self.dispose = dispose
    }

    @MainActor
    func value(start: (@escaping @Sendable (Result<Value, any Error>) -> Void) -> Progress) async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let shouldStart = state.withLock { current in
                    if current.cancelled { return false }
                    current.continuation = continuation
                    return true
                }
                guard shouldStart else { continuation.resume(throwing: CancellationError()); return }
                let progress = start { self.resolve($0) }
                let cancel = state.withLock { current in
                    if current.finished { return current.cancelled }
                    current.progress = progress
                    return false
                }
                if cancel { progress.cancel() }
            }
        } onCancel: { self.cancel() }
    }

    private func resolve(_ result: Result<Value, any Error>) {
        let resolved = state.withLock { current -> (CheckedContinuation<Value, any Error>?, Bool) in
            if current.finished {
                if case .success(let value) = result { return (nil, current.adoptedFile != identity(value)) }
                return (nil, false)
            }
            current.finished = true
            if case .success(let value) = result { current.adoptedFile = identity(value) }
            let continuation = current.continuation
            current.continuation = nil
            current.progress = nil
            return (continuation, false)
        }
        if let continuation = resolved.0 { continuation.resume(with: result) }
        else if resolved.1, case .success(let value) = result { dispose(value) }
    }

    private func cancel() {
        let previous = state.withLock { current -> (CheckedContinuation<Value, any Error>?, Progress?) in
            guard !current.finished else { return (nil, nil) }
            current.finished = true
            current.cancelled = true
            let previous = (current.continuation, current.progress)
            current.continuation = nil
            current.progress = nil
            return previous
        }
        previous.1?.cancel()
        previous.0?.resume(throwing: CancellationError())
    }
}

extension CancellableFilePromise where Value == URL {
    convenience init(dispose: @escaping @Sendable (URL) -> Void) {
        self.init(identity: { $0 }, dispose: dispose)
    }
}

import Foundation

struct MediaPreviewRequestKey: Hashable, Sendable {
    let object: MediaObjectIdentity
    let pixels: Int
}

/// Expensive poster requests are shared by exact revision and output size. Cancelling
/// one thumbnail consumer preserves other consumers; the last one cancels rendering.
actor MediaPreviewRequests<Value: Sendable> {
    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
        var consumers: [UUID: CheckedContinuation<Value, Error>]
    }
    private var flights: [MediaPreviewRequestKey: Flight] = [:]
    var consumerCount: Int { flights.values.reduce(0) { $0 + $1.consumers.count } }

    func value(for key: MediaPreviewRequestKey,
               operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let consumer = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if var existing = flights[key] {
                    existing.consumers[consumer] = continuation; flights[key] = existing; return
                }
                let id = UUID()
                let task = Task {
                    do {
                        let value = try await operation()
                        try Task.checkCancellation()
                        finish(key, id: id, result: .success(value))
                    } catch { finish(key, id: id, result: .failure(error)) }
                }
                flights[key] = Flight(id: id, task: task, consumers: [consumer: continuation])
            }
        } onCancel: { Task { await self.cancel(consumer, key: key) } }
    }

    private func cancel(_ consumer: UUID, key: MediaPreviewRequestKey) {
        guard var flight = flights[key], let continuation = flight.consumers.removeValue(forKey: consumer) else { return }
        continuation.resume(throwing: CancellationError())
        if flight.consumers.isEmpty { flights.removeValue(forKey: key); flight.task.cancel() }
        else { flights[key] = flight }
    }
    private func finish(_ key: MediaPreviewRequestKey, id: UUID, result: Result<Value, Error>) {
        guard let flight = flights[key], flight.id == id else { return }
        flights.removeValue(forKey: key)
        for continuation in flight.consumers.values { continuation.resume(with: result) }
    }
    func invalidate(account: String, bucket: String, key: String) {
        for candidate in flights.keys.filter({ $0.object.matches(account: account, bucket: bucket, key: key) }) { remove(candidate) }
    }
    func reset() { for key in Array(flights.keys) { remove(key) } }
    private func remove(_ key: MediaPreviewRequestKey) {
        guard let flight = flights.removeValue(forKey: key) else { return }
        flight.task.cancel()
        for continuation in flight.consumers.values { continuation.resume(throwing: CancellationError()) }
    }
}

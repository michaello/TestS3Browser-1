import Foundation
import Observation

enum ResourceRefreshPolicy: Sendable { case automatic, force }

@Observable @MainActor
final class RequestOwnership {
    private var owner: UUID?
    private(set) var isLoading = false
    func begin() -> UUID { let id = UUID(); owner = id; isLoading = true; return id }
    func owns(_ id: UUID) -> Bool { owner == id }
    func finish(_ id: UUID) { if owns(id) { isLoading = false } }
    func reset() { owner = nil; isLoading = false }
}

enum ResourceLoadError: LocalizedError, Equatable {
    case failed(String)
    var errorDescription: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

/// Owns cache, active work and errors for each immutable resource. UI reads the cached
/// value before awaiting refresh. A replacement invalidates the old task's publication.
@Observable @MainActor
final class ResourceLoader<Key: Hashable & Sendable, Value: Sendable> {
    struct Snapshot: Sendable {
        var value: Value
        var refreshedAt: Date?
    }

    private final class Flight {
        let id = UUID()
        var requiresRefresh = false
        var task: Task<Value, Error>!
    }

    private(set) var snapshots: [Key: Snapshot] = [:]
    private(set) var errors: [Key: String] = [:]
    private var attempts: [Key: Date] = [:]
    private var active: [Key: Flight] = [:]
    private let freshness: TimeInterval
    private let now: @MainActor () -> Date

    init(freshness: TimeInterval = 60, now: @escaping @MainActor () -> Date = Date.init) {
        self.freshness = freshness
        self.now = now
    }

    func value(for key: Key) -> Value? { snapshots[key]?.value }
    func isLoading(_ key: Key) -> Bool { active[key] != nil }
    func error(for key: Key) -> String? { errors[key] }

    func seed(_ value: Value, for key: Key, refreshedAt: Date?) {
        snapshots[key] = Snapshot(value: value, refreshedAt: refreshedAt)
    }

    func invalidate(_ key: Key) {
        snapshots[key]?.refreshedAt = nil
        attempts[key] = nil
        active[key]?.requiresRefresh = true
    }

    func cancel(_ key: Key) {
        active.removeValue(forKey: key)?.task.cancel()
    }

    func remove(_ key: Key) {
        cancel(key)
        snapshots.removeValue(forKey: key)
        errors.removeValue(forKey: key)
        attempts.removeValue(forKey: key)
    }

    /// A cache rebuild starts one new owned request and keeps the last good value.
    func prepareRebuild(_ key: Key) {
        cancel(key)
        invalidate(key)
    }

    func reset(clearSnapshots: Bool = true) {
        let flights = active.values
        active.removeAll()
        for flight in flights { flight.task.cancel() }
        errors.removeAll()
        attempts.removeAll()
        if clearSnapshots { snapshots.removeAll() }
    }

    func load(_ key: Key, policy: ResourceRefreshPolicy = .automatic,
              operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        if let flight = active[key] {
            if policy == .force { flight.requiresRefresh = true }
            return try await flight.task.value
        }
        if policy == .automatic {
            if let snapshot = snapshots[key], let date = snapshot.refreshedAt,
               now().timeIntervalSince(date) < freshness { return snapshot.value }
            if let attempted = attempts[key], now().timeIntervalSince(attempted) < freshness,
               let message = errors[key] {
                if let cached = value(for: key) { return cached }
                throw ResourceLoadError.failed(message)
            }
        }

        let flight = Flight()
        active[key] = flight
        flight.task = Task { @MainActor [self] in
            defer {
                if active[key]?.id == flight.id { active.removeValue(forKey: key) }
            }
            while true {
                flight.requiresRefresh = false
                attempts[key] = now()
                do {
                    let result = try await operation()
                    try Task.checkCancellation()
                    guard active[key]?.id == flight.id else { throw CancellationError() }
                    if flight.requiresRefresh { continue }
                    snapshots[key] = Snapshot(value: result, refreshedAt: now())
                    errors[key] = nil
                    return result
                } catch {
                    guard active[key]?.id == flight.id, !Task.isCancelled else { throw CancellationError() }
                    if flight.requiresRefresh { continue }
                    if !(error is CancellationError) { errors[key] = error.localizedDescription }
                    throw error
                }
            }
        }
        return try await flight.task.value
    }
}

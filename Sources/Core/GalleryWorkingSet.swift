import Foundation
import Observation

struct GalleryImageValue<Value> { let value: Value; let bytes: Int }

/// Owns current/adjacent requests and decoded references. Leaving the window cancels demand;
/// shared transfer cancellation only stops its body when no visible/prefetch/export waiter remains.
@MainActor @Observable
final class GalleryWorkingSet<Value> {
    private(set) var values: [MediaObjectIdentity: Value] = [:]
    private(set) var loading: Set<MediaObjectIdentity> = []
    private(set) var errors: [MediaObjectIdentity: String] = [:]
    private(set) var retainedBytes = 0
    @ObservationIgnored private var costs: [MediaObjectIdentity: Int] = [:]
    @ObservationIgnored private var requests: [MediaObjectIdentity: UUID] = [:]
    @ObservationIgnored private var tasks: [MediaObjectIdentity: Task<Void, Never>] = [:]
    @ObservationIgnored private var window: [MediaObjectIdentity] = []
    private let byteLimit: Int
    init(byteLimit: Int = 3 * MediaLimits().displayImageBytes) { self.byteLimit = byteLimit }

    func select(_ identities: [MediaObjectIdentity], index: Int,
                load: @escaping @MainActor (MediaObjectIdentity) async throws -> GalleryImageValue<Value>) {
        guard identities.indices.contains(index) else { clear(); return }
        let positions = [index, index - 1, index + 1].filter { identities.indices.contains($0) }
        window = positions.map { identities[$0] }
        let allowed = Set(window)
        for key in Array(tasks.keys) where !allowed.contains(key) { cancel(key) }
        for key in Array(values.keys) where !allowed.contains(key) { removeValue(key) }
        errors = errors.filter { allowed.contains($0.key) }
        for key in window where values[key] == nil && tasks[key] == nil {
            let request = UUID()
            requests[key] = request; loading.insert(key)
            tasks[key] = Task { @MainActor in
                defer {
                    if self.requests[key] == request {
                        self.requests.removeValue(forKey: key); self.tasks.removeValue(forKey: key); self.loading.remove(key)
                    }
                }
                do {
                    let result = try await load(key)
                    try Task.checkCancellation()
                    guard self.requests[key] == request, self.window.contains(key) else { return }
                    guard result.bytes >= 0, result.bytes <= self.byteLimit else { throw MediaTransferError.invalidProgress }
                    self.values[key] = result.value; self.costs[key] = result.bytes
                    self.retainedBytes = self.costs.values.reduce(0, +)
                    // Current is first in the window. Drop the farthest adjacent references first.
                    for old in self.window.reversed() where self.retainedBytes > self.byteLimit {
                        self.removeValue(old)
                    }
                    self.errors.removeValue(forKey: key)
                } catch {
                    if self.requests[key] == request, !(error is CancellationError) { self.errors[key] = error.localizedDescription }
                }
            }
        }
    }
    private func removeValue(_ key: MediaObjectIdentity) {
        values.removeValue(forKey: key)
        if let bytes = costs.removeValue(forKey: key) { retainedBytes -= bytes }
    }
    private func cancel(_ key: MediaObjectIdentity) {
        requests.removeValue(forKey: key); tasks.removeValue(forKey: key)?.cancel(); loading.remove(key)
    }
    func clear() {
        for key in Array(tasks.keys) { cancel(key) }
        values.removeAll(); costs.removeAll(); errors.removeAll(); window.removeAll(); retainedBytes = 0
    }
    var activeRequestCount: Int { tasks.count }
}

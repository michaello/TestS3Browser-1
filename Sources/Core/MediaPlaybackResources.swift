import Foundation

/// A player keeps its own resource ownership through inline/fullscreen presentation changes.
/// Deinitialization also releases ownership if the entire presentation tree disappears.
actor MediaPlaybackResources {
    private let originals: MediaOriginalStore
    private let limiter: BodyTransferLimiter
    private var original: OriginalFileLease?
    private var permit: UUID?
    private var generation = UUID()
    init(originals: MediaOriginalStore = .shared, limiter: BodyTransferLimiter = .shared) {
        self.originals = originals; self.limiter = limiter
    }
    func acquire(url: URL, identity: MediaObjectIdentity?, requestID: UUID = UUID()) async throws {
        try Task.checkCancellation()
        generation = requestID
        if original != nil || permit != nil { return }
        let current = requestID
        if url.isFileURL {
            guard let identity, let lease = try await originals.cachedFile(for: identity) else { throw MediaTransferError.missingBody }
            guard current == generation, !Task.isCancelled else { await originals.release(lease); throw CancellationError() }
            original = lease
        } else {
            let id = try await limiter.acquireLease()
            guard current == generation, !Task.isCancelled else { await limiter.releaseLease(id); throw CancellationError() }
            permit = id
        }
    }
    func release(ifGeneration requested: UUID? = nil) async {
        if let requested, requested != generation { return }
        generation = UUID()
        let file = original, id = permit
        original = nil; permit = nil
        if let file { await originals.release(file) }
        if let id { await limiter.releaseLease(id) }
    }
    deinit {
        let file = original, id = permit, originals = originals, limiter = limiter
        Task {
            if let file { await originals.release(file) }
            if let id { await limiter.releaseLease(id) }
        }
    }
}

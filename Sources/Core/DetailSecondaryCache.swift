import Foundation

enum DetailSection: Hashable, Sendable { case metadata, versions, tags, permissions, lifecycle }

struct DetailResourceKey: Hashable, Sendable {
    let object: MediaObjectIdentity
    let section: DetailSection

    init(object: MediaObjectIdentity, section: DetailSection) {
        // Bucket rules have no per-object revision, so all files share one fresh read.
        self.object = section == .lifecycle
            ? MediaObjectIdentity(account: object.account, bucket: object.bucket, key: "") : object
        self.section = section
    }
}

/// Visible content finishes before secondary work is admitted. HTML has no visible
/// secondary card until its details sheet is requested.
enum DetailLoadSchedule {
    @MainActor
    static func initial(isHTML: Bool, content: () async -> Void, metadata: () async -> Void) async {
        await content()
        guard !isHTML, !Task.isCancelled else { return }
        await metadata()
    }
}

@MainActor
final class DetailSecondaryCache<Value: Sendable> {
    private let loader: ResourceLoader<DetailResourceKey, Value>
    private let capacity: Int
    private var order: [DetailResourceKey] = []
    var count: Int { order.count }

    init(capacity: Int = 128, freshness: TimeInterval = 60,
         now: @escaping @MainActor () -> Date = Date.init) {
        self.capacity = max(1, capacity)
        loader = ResourceLoader(freshness: freshness, now: now)
    }

    func value(for key: DetailResourceKey) -> Value? { loader.value(for: key) }

    func load(_ key: DetailResourceKey, requested: Bool = true, force: Bool = false,
              operation: @escaping @MainActor () async throws -> Value) async throws -> Value? {
        guard requested else { return nil }
        try Task.checkCancellation()
        touch(key)
        let result = try await loader.load(key, policy: force ? .force : .automatic, operation: operation)
        try Task.checkCancellation()
        return result
    }

    func seed(_ value: Value, for key: DetailResourceKey, refreshedAt: Date = Date()) {
        touch(key)
        loader.seed(value, for: key, refreshedAt: refreshedAt)
    }

    func invalidate(account: String, bucket: String, key: String) {
        let matching = order.filter { $0.section != .lifecycle && $0.object.matches(account: account, bucket: bucket, key: key) }
        for key in matching { loader.remove(key) }
        order.removeAll { matching.contains($0) }
    }

    func reset() { loader.reset(); order.removeAll() }

    private func touch(_ key: DetailResourceKey) {
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > capacity { loader.remove(order.removeFirst()) }
    }
}

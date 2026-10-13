import Foundation
import Observation

struct DerivedRowsKey: Hashable {
    let revision: UUID?
    let fields: [Data]
    init(revision: UUID?, fields: [String]) { self.revision = revision;self.fields = fields.map { Data($0.utf8) } }
}

/// A single latest projection per screen. Progress changes do not change its key.
/// The retained input revision is updated only when source rows or query fields change.
@MainActor
final class DerivedRowsCache<Value> {
    private var key: DerivedRowsKey?
    private var cached: Value?
    private(set) var derivationCount = 0
    private(set) var derivationMilliseconds = 0.0

    func value(for key: DerivedRowsKey, derive: () -> Value) -> Value {
        if self.key == key, let cached { return cached }
        let started = ContinuousClock.now
        let result = derive()
        let elapsed = started.duration(to: .now).components
        derivationMilliseconds += Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
        derivationCount += 1
        self.key = key;cached = result
        return result
    }
}

@Observable @MainActor
final class GalleryIdentityProjection<Value: Sendable, Key: Hashable & Sendable> {
    private(set) var identities: [Key] = []
    private(set) var objects: [Key: Value] = [:]
    private(set) var derivationCount = 0

    func update(_ source: [Value], identity: (Value) -> Key) {
        identities = source.map(identity)
        objects = Dictionary(zip(identities, source), uniquingKeysWith: { first, _ in first })
        derivationCount += 1
    }
}

import Foundation

/// Cache reset and per-object mutations invalidate suspended decoders before publication.
struct MediaCacheEpoch {
    struct Ticket: Sendable {
        fileprivate let generation: UUID
        fileprivate let location: String
        fileprivate let objectGeneration: UUID?
    }
    private var generation = UUID()
    private var active: [String: Int] = [:]
    private var objectGenerations: [String: UUID] = [:]
    mutating func begin(_ identity: MediaObjectIdentity) -> Ticket {
        let location = MediaObjectIdentity(account: identity.account, bucket: identity.bucket, key: identity.key).digest
        active[location, default: 0] += 1
        return Ticket(generation: generation, location: location, objectGeneration: objectGenerations[location])
    }
    func isCurrent(_ ticket: Ticket) -> Bool {
        ticket.generation == generation && ticket.objectGeneration == objectGenerations[ticket.location]
    }
    mutating func finish(_ ticket: Ticket) {
        guard let count = active[ticket.location] else { return }
        if count <= 1 { active.removeValue(forKey: ticket.location); objectGenerations.removeValue(forKey: ticket.location) }
        else { active[ticket.location] = count - 1 }
    }
    mutating func invalidate(account: String, bucket: String, key: String) {
        let location = MediaObjectIdentity(account: account, bucket: bucket, key: key).digest
        if active[location] != nil { objectGenerations[location] = UUID() }
    }
    mutating func reset() { generation = UUID(); objectGenerations.removeAll() }
    func publish<Key: Hashable, Value>(_ ticket: Ticket, into cache: inout ByteCostLRU<Key, Value>,
                                      key: Key, value: Value, cost: Int) -> Bool {
        guard isCurrent(ticket) else { return false }
        cache.insert(value, for: key, cost: cost)
        return true
    }
}

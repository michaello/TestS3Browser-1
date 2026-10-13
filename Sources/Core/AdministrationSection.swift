import Foundation
import Observation

struct AdministrationIdentity: Hashable, Sendable {
    let account: String
    let credentialRevision: String
    let bucket: String
    let prefix: String
    init(configuration: ServiceConfiguration) {
        account = configuration.account; credentialRevision = configuration.credentialRevision
        bucket = configuration.bucket; prefix = configuration.prefix
    }
    private var fields: [Data] { [account, credentialRevision, bucket, prefix].map { Data($0.utf8) } }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.fields == rhs.fields }
    func hash(into hasher: inout Hasher) { hasher.combine(fields) }
}

struct AdministrationLoadRequest: Hashable {
    let identity: AdministrationIdentity
    let expanded: Bool
}

/// The configured service owns these caches across Settings visits. Current identity
/// selects what can render; a late obsolete result cannot replace that selection.
@Observable @MainActor
final class AdministrationSection<Value: Sendable> {
    private let loader = ResourceLoader<AdministrationIdentity, Value>()
    private(set) var identity: AdministrationIdentity?
    var value: Value? { identity.flatMap { loader.value(for: $0) } }
    var isLoading: Bool { identity.map { loader.isLoading($0) } ?? false }
    var hasLoaded: Bool { identity.map { loader.snapshots[$0] != nil } ?? false }
    var error: String? { identity.flatMap { loader.error(for: $0) } }
    func value(for identity: AdministrationIdentity) -> Value? { loader.value(for: identity) }
    func isLoading(_ identity: AdministrationIdentity) -> Bool { loader.isLoading(identity) }
    func hasLoaded(_ identity: AdministrationIdentity) -> Bool { loader.snapshots[identity] != nil }
    func error(for identity: AdministrationIdentity) -> String? { loader.error(for: identity) }

    func activate(_ identity: AdministrationIdentity) {
        guard self.identity != identity else { return }
        if let previous = self.identity { loader.cancel(previous) }
        self.identity = identity
    }
    func load(_ identity: AdministrationIdentity, expanded: Bool, force: Bool = false,
              operation: @escaping @MainActor () async throws -> Value) async {
        guard !Task.isCancelled else { return }
        activate(identity)
        guard expanded else { return }
        do { _ = try await loader.load(identity, policy: force ? .force : .automatic, operation: operation) }
        catch { /* The loader retains the last successful value and publishes its error. */ }
    }
}

struct ConfigurationDraft<Value: Equatable & Sendable> {
    private(set) var applied: Value
    var value: Value
    private(set) var generation = 0
    init(applied: Value) { self.applied = applied; value = applied }
    var hasChanges: Bool { value != applied }
    mutating func discard() { value = applied }
    mutating func receiveApplied(_ value: Value) {
        if applied != value { applied = value; self.value = value; generation += 1 }
    }
    mutating func apply(persist: (Value) throws -> Void) throws {
        guard hasChanges else { return }
        try persist(value)
        applied = value
        generation += 1
    }
}

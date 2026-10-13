import Foundation
import Observation

/// Shares account/bucket-qualified annotation state with TagStore.
@Observable @MainActor
final class StarStore {
    static let shared = StarStore()

    private let state = ObjectAnnotationState.shared
    var starredKeys: Set<LocalObjectIdentity> { state.stars }
    var legacyCount: Int { state.legacyStarKeys.count }
    var storageError: String? { state.storageError }
    private init() {}
    func toggle(_ identity: LocalObjectIdentity) { state.toggleStar(identity) }
    func isStarred(_ identity: LocalObjectIdentity) -> Bool { state.stars.contains(identity) }
    func hasStars(in account: String) -> Bool { state.hasStars(in: account) }
    func clearAll() { state.clearStars() }
}

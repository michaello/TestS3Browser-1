import SwiftUI

/// Local labels are stored under exact account/bucket/key identities in the main app.
@Observable @MainActor
final class TagStore {
    static let shared = TagStore()

    private let state = ObjectAnnotationState.shared
    var tags: [LocalObjectIdentity: String] { state.tags }
    var legacyCount: Int { state.legacyTags.count }
    var storageError: String? { state.storageError }
    private init() {}
    func allTags(in account: String) -> [String] { state.tags(in: account) }
    func setTag(_ tag: String?, for identity: LocalObjectIdentity) { state.setTag(tag, for: identity) }
    func tag(for identity: LocalObjectIdentity) -> String? { state.tags[identity] }
    func clearAll() { state.clearTags() }
}

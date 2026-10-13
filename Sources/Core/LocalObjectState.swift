import Foundation
import Observation

enum LocalObjectRuntimeDefaults {
    static var current: UserDefaults {
        if ProcessInfo.processInfo.environment["S3BROWSER_AUDIT_FIXTURE"] == "1" {
            guard let fixture = UserDefaults(suiteName: "s3browser-audit-fixture-v1") else {
                preconditionFailure("Isolated annotation fixture storage is unavailable")
            }
            return fixture
        }
        return .standard
    }
}

/// Local labels follow the exact object key across revisions, unlike media cache identities.
struct LocalObjectIdentity: Codable, Hashable, Sendable {
    let account: String
    let bucket: String
    let key: String
    var storageKey: String { [account, bucket, key].map { Data($0.utf8).base64EncodedString() }.joined(separator: ".") }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.storageKey == rhs.storageKey }
    func hash(into hasher: inout Hasher) { hasher.combine(storageKey) }
}

@Observable @MainActor
final class ObjectAnnotationState {
    static let shared = ObjectAnnotationState(defaults: LocalObjectRuntimeDefaults.current)
    static let storageKey = "s3ObjectAnnotations.v2"
    private struct Tag: Codable { let identity: LocalObjectIdentity; let value: String }
    private struct Archive: Codable { let version: Int; let stars: [LocalObjectIdentity]; let tags: [Tag] }
    private let defaults: UserDefaults
    private var writable = true
    private(set) var stars: Set<LocalObjectIdentity> = []
    private(set) var tags: [LocalObjectIdentity: String] = [:]
    private(set) var legacyStarKeys: Set<String>
    private(set) var legacyTags: [String: String]
    private(set) var storageError: String?
    private(set) var revision = 0

    init(defaults: UserDefaults) {
        self.defaults = defaults
        // Bare legacy keys have no account/bucket provenance. Retain them without
        // claiming them for whichever account happens to launch first.
        legacyStarKeys = Set(defaults.array(forKey: "s3StarredKeys") as? [String] ?? [])
        legacyTags = defaults.dictionary(forKey: "s3FileTags") as? [String: String] ?? [:]
        if let data = defaults.data(forKey: Self.storageKey) {
            do {
                let archive = try JSONDecoder().decode(Archive.self, from: data)
                guard archive.version == 2 else { throw SecureConfigurationError.unsupportedSchema }
                stars = Set(archive.stars)
                for tag in archive.tags { tags[tag.identity] = tag.value }
            } catch {
                writable = false
                storageError = "Saved stars and tags could not be loaded. The stored data was retained."
            }
        }
    }

    func toggleStar(_ identity: LocalObjectIdentity) {
        var replacement = stars
        if replacement.contains(identity) { replacement.remove(identity) } else { replacement.insert(identity) }
        save(stars: replacement, tags: tags)
    }

    func setTag(_ value: String?, for identity: LocalObjectIdentity) {
        var replacement = tags
        if let value, !value.isEmpty { replacement[identity] = value } else { replacement[identity] = nil }
        save(stars: stars, tags: replacement)
    }

    func relocate(from source: LocalObjectIdentity, to destination: LocalObjectIdentity) {
        guard source != destination else { return }
        var replacementStars = stars
        if replacementStars.remove(source) != nil { replacementStars.insert(destination) }
        var replacementTags = tags
        if let tag = replacementTags.removeValue(forKey: source) { replacementTags[destination] = tag }
        save(stars: replacementStars, tags: replacementTags)
    }

    func clearStars() {
        if save(stars: [], tags: tags) {
            defaults.removeObject(forKey: "s3StarredKeys")
            legacyStarKeys.removeAll()
        }
    }
    func clearTags() {
        if save(stars: stars, tags: [:]) {
            defaults.removeObject(forKey: "s3FileTags")
            legacyTags.removeAll()
        }
    }
    func tags(in account: String) -> [String] {
        Array(Set(tags.filter { $0.key.account.utf8.elementsEqual(account.utf8) }.values)).sorted()
    }
    func hasStars(in account: String) -> Bool { stars.contains { $0.account.utf8.elementsEqual(account.utf8) } }

    @discardableResult
    private func save(stars replacementStars: Set<LocalObjectIdentity>, tags replacementTags: [LocalObjectIdentity: String]) -> Bool {
        guard writable else { return false }
        do {
            let archive = Archive(version: 2, stars: Array(replacementStars), tags: replacementTags.map { Tag(identity: $0.key, value: $0.value) })
            let data = try JSONEncoder().encode(archive)
            defaults.set(data, forKey: Self.storageKey)
            guard defaults.data(forKey: Self.storageKey) == data else { throw SecureConfigurationError.preferenceWriteNotVerified }
            stars = replacementStars
            tags = replacementTags
            revision += 1
            storageError = nil
            return true
        } catch {
            storageError = "Stars and tags could not be saved. The previous visible labels were retained."
            return false
        }
    }
}

/// Seen history is additive across filtered/limited pages. Only explicit clear operations prune it.
struct SeenObjectHistory: Codable, Sendable {
    private var groups: [String: Set<String>] = [:]
    private func scope(account: String, bucket: String, namespace: String) -> String {
        [account, bucket, namespace].map { Data($0.utf8).base64EncodedString() }.joined(separator: ".")
    }
    func hasRecord(account: String, bucket: String, namespace: String = "recent") -> Bool {
        groups[scope(account: account, bucket: bucket, namespace: namespace)] != nil
    }
    func newKeys(_ keys: [String], account: String, bucket: String, namespace: String = "recent") -> [String] {
        guard let seen = groups[scope(account: account, bucket: bucket, namespace: namespace)] else { return [] }
        return keys.filter { !seen.contains(Data($0.utf8).base64EncodedString()) }
    }
    mutating func mark(_ keys: [String], account: String, bucket: String, namespace: String = "recent") {
        groups[scope(account: account, bucket: bucket, namespace: namespace), default: []]
            .formUnion(keys.map { Data($0.utf8).base64EncodedString() })
    }
    mutating func clear(account: String, bucket: String, namespace: String = "recent") {
        groups[scope(account: account, bucket: bucket, namespace: namespace)] = nil
    }
    mutating func clearAll() { groups.removeAll() }
}

struct RecentAnnotationFilter: Equatable {
    var tag: String?
    var starredOnly = false
    var isActive: Bool { tag != nil || starredOnly }
    mutating func reconcile(availableTags: [String], hasStars: Bool) {
        if let tag, !availableTags.contains(tag) { self.tag = nil }
        if !hasStars { starredOnly = false }
    }
    mutating func clear() { tag = nil; starredOnly = false }
}

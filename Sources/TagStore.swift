import SwiftUI

/// Persists a [S3 object key -> tag label] mapping in UserDefaults.
/// The tag is a short, user-defined string (e.g. "important", "review").
/// Stored under key "s3FileTags" in the standard UserDefaults suite so it lives
/// on the main app only (tags are not shared with the widget).
@Observable
final class TagStore {
    static let shared = TagStore()

    private let defaultsKey = "s3FileTags"

    /// Maps S3 object key -> tag string. Keys with no tag are absent.
    private(set) var tags: [String: String] = [:]

    /// All distinct tag values currently in use, sorted alphabetically.
    var allTags: [String] {
        Array(Set(tags.values)).sorted()
    }

    private init() {
        if let stored = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] {
            tags = stored
        }
    }

    /// Assigns a tag to an S3 object key. Pass nil or empty string to remove the tag.
    func setTag(_ tag: String?, forKey key: String) {
        if let tag, !tag.isEmpty {
            tags[key] = tag
        } else {
            tags.removeValue(forKey: key)
        }
        UserDefaults.standard.set(tags, forKey: defaultsKey)
    }

    func tag(forKey key: String) -> String? {
        tags[key]
    }
}

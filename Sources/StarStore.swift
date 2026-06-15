import Foundation
import Observation

/// Persists the set of starred S3 object keys to UserDefaults.
@Observable
final class StarStore {
    static let shared = StarStore()

    private(set) var starredKeys: Set<String> = []

    private let udKey = "s3StarredKeys"

    private init() {
        if let saved = UserDefaults.standard.array(forKey: udKey) as? [String] {
            starredKeys = Set(saved)
        }
    }

    func toggle(_ key: String) {
        if starredKeys.contains(key) {
            starredKeys.remove(key)
        } else {
            starredKeys.insert(key)
        }
        persist()
    }

    func isStarred(_ key: String) -> Bool {
        starredKeys.contains(key)
    }

    func clearAll() {
        starredKeys.removeAll()
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(Array(starredKeys), forKey: udKey)
    }
}

import Foundation
import os.log

/// Owns additive account/bucket/query-independent seen history. Legacy bucket-only
/// history is retained under its old key because its account provenance is unknown.
actor SeenPhotosTracker {
    static let shared = SeenPhotosTracker()
    private let logger = Logger(subsystem: "com.s3browser", category: "SeenPhotosTracker")
    private let userDefaultsKey = "seenObjectsByAccount.v2"
    private let defaults: UserDefaults
    private var history: SeenObjectHistory
    private let writable: Bool

    private init() {
        let defaults = LocalObjectRuntimeDefaults.current
        self.defaults = defaults
        if let data = defaults.data(forKey: "seenObjectsByAccount.v2") {
            do { history = try JSONDecoder().decode(SeenObjectHistory.self, from: data); writable = true }
            catch { history = SeenObjectHistory(); writable = false }
        } else { history = SeenObjectHistory(); writable = true }
    }

    func markAsSeen(photoKeys: [String], bucket: String, account: String, namespace: String = "recent") {
        guard writable else { logger.error("Saved seen history is unreadable and was retained."); return }
        history.mark(photoKeys, account: account, bucket: bucket, namespace: namespace)
        saveToDisk()
    }
    func addSeen(photoKeys: [String], bucket: String, account: String, namespace: String = "recent") {
        markAsSeen(photoKeys: photoKeys, bucket: bucket, account: account, namespace: namespace)
    }
    func findNewPhotos(currentPhotos: [String], bucket: String, account: String, namespace: String = "recent") -> [String] {
        history.newKeys(currentPhotos, account: account, bucket: bucket, namespace: namespace)
    }
    func hasSeenPhotos(for bucket: String, account: String, namespace: String = "recent") -> Bool {
        history.hasRecord(account: account, bucket: bucket, namespace: namespace)
    }
    func clearSeenPhotos(for bucket: String, account: String, namespace: String = "recent") {
        guard writable else { return }
        history.clear(account: account, bucket: bucket, namespace: namespace)
        saveToDisk()
    }
    func clearAll() {
        guard writable else { return }
        history.clearAll()
        saveToDisk()
        defaults.removeObject(forKey: "seenPhotosPerBucket")
    }
    private func saveToDisk() {
        do { defaults.set(try JSONEncoder().encode(history), forKey: userDefaultsKey) }
        catch { logger.error("Failed to encode seen history: \(error.localizedDescription)") }
    }
}

import Foundation
import os.log

/// Tracks which photos have been seen in each bucket to detect new uploads
/// Persists data to UserDefaults keyed by bucket name
actor SeenPhotosTracker {
    static let shared = SeenPhotosTracker()

    private let logger = Logger(subsystem: "com.s3browser", category: "SeenPhotosTracker")
    private let userDefaultsKey = "seenPhotosPerBucket"

    /// In-memory cache of seen photo keys per bucket
    /// Key: bucket name, Value: Set of S3 object keys (etags or keys)
    private var seenPhotos: [String: Set<String>] = [:]

    private init() {
        loadFromDisk()
    }

    // MARK: - Public Interface

    /// Records the current set of photo keys as "seen" for a bucket
    /// - Parameters:
    ///   - photoKeys: Array of S3 object keys currently visible
    ///   - bucket: The bucket name
    func markAsSeen(photoKeys: [String], bucket: String) {
        let keySet = Set(photoKeys)
        seenPhotos[bucket] = keySet
        saveToDisk()
        logger.debug("Marked \(photoKeys.count) photos as seen for bucket: \(bucket)")
    }

    /// Finds new photos that haven't been seen before
    /// - Parameters:
    ///   - currentPhotos: Current array of S3 object keys
    ///   - bucket: The bucket name
    /// - Returns: Array of keys that are new (not previously seen), ordered by their position in currentPhotos
    func findNewPhotos(currentPhotos: [String], bucket: String) -> [String] {
        guard let previouslySeen = seenPhotos[bucket] else {
            // First time seeing this bucket - no "new" photos
            logger.debug("No previous seen photos for bucket: \(bucket)")
            return []
        }

        let newPhotos = currentPhotos.filter { !previouslySeen.contains($0) }
        logger.debug("Found \(newPhotos.count) new photos in bucket: \(bucket)")
        return newPhotos
    }

    /// Checks if we have any record of seen photos for a bucket
    /// - Parameter bucket: The bucket name
    /// - Returns: True if we've previously tracked photos for this bucket
    func hasSeenPhotos(for bucket: String) -> Bool {
        return seenPhotos[bucket] != nil
    }

    /// Clears seen photos for a specific bucket
    /// - Parameter bucket: The bucket name
    func clearSeenPhotos(for bucket: String) {
        seenPhotos.removeValue(forKey: bucket)
        saveToDisk()
        logger.debug("Cleared seen photos for bucket: \(bucket)")
    }

    /// Clears all seen photo data
    func clearAll() {
        seenPhotos.removeAll()
        saveToDisk()
        logger.debug("Cleared all seen photos data")
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else {
            logger.debug("No persisted seen photos data found")
            return
        }

        do {
            let decoded = try JSONDecoder().decode([String: [String]].self, from: data)
            // Convert arrays back to sets
            seenPhotos = decoded.mapValues { Set($0) }
            logger.debug("Loaded seen photos for \(self.seenPhotos.count) buckets")
        } catch {
            logger.error("Failed to decode seen photos: \(error.localizedDescription)")
        }
    }

    private func saveToDisk() {
        do {
            // Convert sets to arrays for JSON encoding
            let encodable = seenPhotos.mapValues { Array($0) }
            let data = try JSONEncoder().encode(encodable)
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        } catch {
            logger.error("Failed to encode seen photos: \(error.localizedDescription)")
        }
    }
}

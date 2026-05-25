import UIKit
import Foundation
import os.log

/// Global actor responsible for caching image thumbnails and full images
/// Maintains separate caches for thumbnails and full-size images to optimize memory usage
/// Thumbnails are persisted to disk for faster loading across app launches
@globalActor
actor ImageCacheActor {
    static let shared = ImageCacheActor()

    private let logger = Logger(subsystem: "com.s3browser", category: "ImageCacheActor")

    // MARK: - Cache Storage

    /// Cache for thumbnail images (smaller, suitable for list views)
    /// Key: S3 object key, Value: Thumbnail UIImage
    private var thumbnailCache: [String: UIImage] = [:]

    /// Cache for full-size images
    /// Key: S3 object key, Value: Full UIImage
    private var fullImageCache: [String: UIImage] = [:]

    /// Tracks the order of cache entries for LRU eviction
    private var accessOrder: [String] = []

    /// Maximum number of thumbnails to keep in memory
    private let maxThumbnailCacheSize = 100

    /// Maximum number of full images to keep in memory
    private let maxFullImageCacheSize = 20

    /// Directory for persistent thumbnail storage
    private let thumbnailCacheDirectory: URL

    /// Maximum number of thumbnails to keep on disk
    private let maxDiskThumbnailCount = 500

    // MARK: - Initialization

    init() {
        // Set up cache directory
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        thumbnailCacheDirectory = cacheDir.appendingPathComponent("thumbnails", isDirectory: true)

        // Create directory if needed
        try? FileManager.default.createDirectory(at: thumbnailCacheDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Thumbnail Operations

    /// Retrieves a cached thumbnail from memory or disk
    /// - Parameter key: S3 object key
    /// - Returns: Cached thumbnail if available, nil otherwise
    func getThumbnail(for key: String) -> UIImage? {
        // Check memory cache first
        if let memCached = thumbnailCache[key] {
            updateAccessOrder(for: key)
            return memCached
        }

        // Check disk cache
        if let diskCached = loadThumbnailFromDisk(for: key) {
            // Promote to memory cache
            thumbnailCache[key] = diskCached
            updateAccessOrder(for: key)
            evictOldThumbnailsIfNeeded()
            return diskCached
        }

        return nil
    }

    /// Caches a thumbnail image to both memory and disk
    /// - Parameters:
    ///   - image: The thumbnail image to cache
    ///   - key: S3 object key
    func cacheThumbnail(_ image: UIImage, for key: String) {
        thumbnailCache[key] = image
        updateAccessOrder(for: key)
        evictOldThumbnailsIfNeeded()

        // Persist to disk asynchronously
        saveThumbnailToDisk(image, for: key)
    }

    /// Generates and caches a thumbnail from full image data
    /// - Parameters:
    ///   - data: Image data
    ///   - key: S3 object key
    ///   - targetSize: Desired thumbnail size (default 60x60)
    /// - Returns: Generated thumbnail image
    func generateAndCacheThumbnail(from data: Data, for key: String, targetSize: CGSize = CGSize(width: 60, height: 60)) -> UIImage? {
        guard let fullImage = UIImage(data: data) else {
            return nil
        }

        // Cache full image as well
        cacheFullImage(fullImage, for: key)

        // Generate thumbnail
        let thumbnail = resizeImage(fullImage, targetSize: targetSize)
        cacheThumbnail(thumbnail, for: key)

        return thumbnail
    }

    // MARK: - Full Image Operations

    /// Retrieves a cached full-size image
    /// - Parameter key: S3 object key
    /// - Returns: Cached full image if available, nil otherwise
    func getFullImage(for key: String) -> UIImage? {
        updateAccessOrder(for: key)
        return fullImageCache[key]
    }

    /// Caches a full-size image
    /// - Parameters:
    ///   - image: The full image to cache
    ///   - key: S3 object key
    func cacheFullImage(_ image: UIImage, for key: String) {
        fullImageCache[key] = image
        updateAccessOrder(for: key)
        evictOldFullImagesIfNeeded()
    }

    /// Caches both full image and thumbnail from data
    /// - Parameters:
    ///   - data: Image data
    ///   - key: S3 object key
    /// - Returns: Full image if successfully created
    func cacheImage(from data: Data, for key: String) -> UIImage? {
        guard let fullImage = UIImage(data: data) else {
            return nil
        }

        cacheFullImage(fullImage, for: key)

        // Also generate and cache thumbnail
        let thumbnail = resizeImage(fullImage, targetSize: CGSize(width: 60, height: 60))
        cacheThumbnail(thumbnail, for: key)

        return fullImage
    }

    // MARK: - Cache Management

    /// Updates the access order for LRU eviction
    /// - Parameter key: S3 object key that was accessed
    private func updateAccessOrder(for key: String) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }

    /// Evicts oldest thumbnails when cache size exceeds limit
    private func evictOldThumbnailsIfNeeded() {
        while thumbnailCache.count > maxThumbnailCacheSize, let oldest = accessOrder.first {
            thumbnailCache.removeValue(forKey: oldest)
            accessOrder.removeFirst()
        }
    }

    /// Evicts oldest full images when cache size exceeds limit
    private func evictOldFullImagesIfNeeded() {
        while fullImageCache.count > maxFullImageCacheSize {
            // Find least recently used full image
            for key in accessOrder {
                if fullImageCache[key] != nil {
                    fullImageCache.removeValue(forKey: key)
                    break
                }
            }
        }
    }

    /// Clears all cached images (memory and disk)
    func clearCache() {
        thumbnailCache.removeAll()
        fullImageCache.removeAll()
        accessOrder.removeAll()
        clearDiskCache()
    }

    /// Removes cached images for a specific key (memory and disk)
    /// - Parameter key: S3 object key to remove from cache
    func removeCachedImages(for key: String) {
        thumbnailCache.removeValue(forKey: key)
        fullImageCache.removeValue(forKey: key)
        accessOrder.removeAll { $0 == key }

        // Remove from disk
        let fileURL = thumbnailFileURL(for: key)
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Image Processing

    /// Resizes an image to fit within target size while maintaining aspect ratio
    /// - Parameters:
    ///   - image: Source image
    ///   - targetSize: Maximum size for the resulting image
    /// - Returns: Resized image
    private func resizeImage(_ image: UIImage, targetSize: CGSize) -> UIImage {
        let size = image.size
        let widthRatio = targetSize.width / size.width
        let heightRatio = targetSize.height / size.height
        let ratio = min(widthRatio, heightRatio)

        let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)

        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    // MARK: - Disk Persistence

    /// Generates a safe filename from an S3 key
    /// - Parameter key: S3 object key
    /// - Returns: Safe filename for disk storage
    private func diskFilename(for key: String) -> String {
        // Use SHA256-like hash approach: base64 encode the key and replace unsafe characters
        let data = Data(key.utf8)
        let base64 = data.base64EncodedString()
        let safe = base64
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return safe + ".jpg"
    }

    /// Returns the file URL for a thumbnail on disk
    /// - Parameter key: S3 object key
    /// - Returns: URL to the thumbnail file
    private func thumbnailFileURL(for key: String) -> URL {
        thumbnailCacheDirectory.appendingPathComponent(diskFilename(for: key))
    }

    /// Saves a thumbnail to disk
    /// - Parameters:
    ///   - image: The thumbnail image
    ///   - key: S3 object key
    private func saveThumbnailToDisk(_ image: UIImage, for key: String) {
        let fileURL = thumbnailFileURL(for: key)

        // Skip if already exists
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return
        }

        guard let data = image.jpegData(compressionQuality: 0.7) else {
            logger.error("Failed to convert thumbnail to JPEG for key: \(key)")
            return
        }

        do {
            try data.write(to: fileURL, options: .atomic)
            cleanupOldDiskThumbnailsIfNeeded()
        } catch {
            logger.error("Failed to save thumbnail to disk for key \(key): \(error.localizedDescription)")
        }
    }

    /// Loads a thumbnail from disk
    /// - Parameter key: S3 object key
    /// - Returns: Loaded thumbnail or nil if not found
    private func loadThumbnailFromDisk(for key: String) -> UIImage? {
        let fileURL = thumbnailFileURL(for: key)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            logger.error("Failed to read thumbnail data from disk for key: \(key)")
            return nil
        }

        // Update access time by touching the file
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)

        return UIImage(data: data)
    }

    /// Removes excess thumbnails from disk using LRU (based on modification date)
    private func cleanupOldDiskThumbnailsIfNeeded() {
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(
                at: thumbnailCacheDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles
            )

            guard fileURLs.count > maxDiskThumbnailCount else { return }

            // Sort by modification date (oldest first)
            let sortedFiles = fileURLs.compactMap { url -> (URL, Date)? in
                guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
                    return nil
                }
                return (url, date)
            }.sorted { $0.1 < $1.1 }

            // Delete oldest files until we're under the limit
            let filesToDelete = sortedFiles.prefix(fileURLs.count - maxDiskThumbnailCount)
            for (url, _) in filesToDelete {
                try? FileManager.default.removeItem(at: url)
            }

            logger.debug("Cleaned up \(filesToDelete.count) old thumbnails from disk")
        } catch {
            logger.error("Failed to cleanup disk thumbnails: \(error.localizedDescription)")
        }
    }

    /// Clears all cached thumbnails from disk
    func clearDiskCache() {
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(
                at: thumbnailCacheDirectory,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            )

            for url in fileURLs {
                try? FileManager.default.removeItem(at: url)
            }

            logger.debug("Cleared \(fileURLs.count) thumbnails from disk cache")
        } catch {
            logger.error("Failed to clear disk cache: \(error.localizedDescription)")
        }
    }
}

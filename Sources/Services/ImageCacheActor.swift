import UIKit
import Foundation

/// Global actor responsible for caching image thumbnails and full images
/// Maintains separate caches for thumbnails and full-size images to optimize memory usage
@globalActor
actor ImageCacheActor {
    static let shared = ImageCacheActor()

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

    // MARK: - Thumbnail Operations

    /// Retrieves a cached thumbnail or creates one from full image if available
    /// - Parameter key: S3 object key
    /// - Returns: Cached thumbnail if available, nil otherwise
    func getThumbnail(for key: String) -> UIImage? {
        updateAccessOrder(for: key)
        return thumbnailCache[key]
    }

    /// Caches a thumbnail image
    /// - Parameters:
    ///   - image: The thumbnail image to cache
    ///   - key: S3 object key
    func cacheThumbnail(_ image: UIImage, for key: String) {
        thumbnailCache[key] = image
        updateAccessOrder(for: key)
        evictOldThumbnailsIfNeeded()
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

    /// Clears all cached images
    func clearCache() {
        thumbnailCache.removeAll()
        fullImageCache.removeAll()
        accessOrder.removeAll()
    }

    /// Removes cached images for a specific key
    /// - Parameter key: S3 object key to remove from cache
    func removeCachedImages(for key: String) {
        thumbnailCache.removeValue(forKey: key)
        fullImageCache.removeValue(forKey: key)
        accessOrder.removeAll { $0 == key }
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
}

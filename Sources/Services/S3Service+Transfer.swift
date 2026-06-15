import Foundation
import AWSS3

/// Download, prefetch, and upload operations for S3Service. Split out of S3Service.swift to keep
/// each file under 500 lines.
extension S3Service {
    /// Downloads an object, optionally from a specific bucket.
    /// Returns prefetched data if available, otherwise downloads from S3.
    func downloadObject(key: String, bucket: String? = nil) async throws -> Data {
        // Check prefetch cache first
        let cacheKey = "\(bucket ?? currentBucket)/\(key)"
        if let cached = prefetchedData[cacheKey] {
            prefetchedData.removeValue(forKey: cacheKey)
            logger.debug("Serving prefetched data for \(key) (\(cached.count) bytes)")
            return cached
        }

        if client == nil {
            try await initializeClient()
        }
        guard let client = client else {
            throw S3ServiceError.clientNotInitialized
        }

        let input = GetObjectInput(
            bucket: bucket ?? currentBucket,
            key: key
        )

        let output = try await client.getObject(input: input)

        guard let body = output.body else {
            throw S3ServiceError.noDataReturned
        }

        // An empty/closed body is a download failure, not a valid zero-byte file - surface it
        // so callers (thumbnails, gallery) show an error instead of silently decoding nothing.
        guard let data = try await body.readData() else {
            throw S3ServiceError.noDataReturned
        }
        return data
    }

    /// Prefetches file data for a list of objects in the background.
    /// Skips images that are already in the image cache.
    func prefetchObjects(_ objects: [S3Object]) {
        prefetchTask?.cancel()
        prefetchTask = Task {
            for object in objects {
                guard !Task.isCancelled else { break }
                let cacheKey = "\(object.bucket ?? currentBucket)/\(object.key)"

                // Skip if already prefetched
                if prefetchedData[cacheKey] != nil { continue }

                // Skip images that are already cached
                if object.fileType == .image {
                    if await ImageCacheActor.shared.getFullImage(for: object.key) != nil { continue }
                }

                do {
                    let data = try await downloadObject(key: object.key, bucket: object.bucket)
                    guard !Task.isCancelled else { break }
                    prefetchedData[cacheKey] = data
                    logger.debug("Prefetched \(object.key) (\(data.count) bytes)")
                } catch {
                    logger.debug("Prefetch failed for \(object.key): \(error.localizedDescription)")
                }
            }
        }
    }

    /// Uploads data to S3 bucket.
    /// - Parameters:
    ///   - data: The data to upload
    ///   - key: The S3 object key (path)
    ///   - contentType: MIME type of the content
    ///   - onProgress: Called on the MainActor with a fraction (0…1) while the upload runs.
    ///     Progress is estimated by time: it ramps to 0.9 over the expected duration, then
    ///     snaps to 1.0 when the SDK call returns. The AWS SDK does not expose a byte-level
    ///     progress hook for PutObject, so time-based estimation is the only option.
    /// - Returns: The key of the uploaded object
    @discardableResult
    func uploadObject(
        data: Data,
        key: String,
        contentType: String = "application/octet-stream",
        onProgress: (@MainActor (Double) -> Void)? = nil
    ) async throws -> String {
        if client == nil {
            try await initializeClient()
        }

        guard let client = client else {
            throw S3ServiceError.clientNotInitialized
        }

        logger.info("Uploading to \(self.currentBucket)/\(key) (\(data.count) bytes)")

        // Estimate upload duration: assume ~500 KB/s on a slow connection, min 1 s.
        let estimatedSeconds = max(1.0, Double(data.count) / 512_000.0)
        let tickInterval: TimeInterval = 0.1
        let maxFraction = 0.9

        let progressTask: Task<Void, Never>? = onProgress.map { callback in
            Task {
                var elapsed = 0.0
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(tickInterval * 1_000_000_000))
                    elapsed += tickInterval
                    // Ease toward maxFraction asymptotically so the bar never stalls at 1.0
                    // before the upload actually finishes.
                    let fraction = maxFraction * (1 - exp(-3 * elapsed / estimatedSeconds))
                    await callback(min(fraction, maxFraction))
                }
            }
        }

        let input = PutObjectInput(
            body: .data(data),
            bucket: currentBucket,
            contentType: contentType,
            key: key
        )

        _ = try await client.putObject(input: input)

        progressTask?.cancel()
        if let onProgress { await onProgress(1.0) }

        logger.info("Upload complete: \(key)")
        return key
    }

    /// Uploads an image to the dump folder with timestamp
    /// - Parameters:
    ///   - imageData: JPEG or PNG image data
    ///   - onProgress: Optional progress callback forwarded to uploadObject.
    /// - Returns: The full S3 key of the uploaded image
    func uploadToDump(
        imageData: Data,
        onProgress: (@MainActor (Double) -> Void)? = nil
    ) async throws -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let filename = "dump/\(timestamp).jpg"

        return try await uploadObject(
            data: imageData,
            key: filename,
            contentType: "image/jpeg",
            onProgress: onProgress
        )
    }
}

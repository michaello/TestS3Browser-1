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

    /// Renames an S3 object by copying it to the new key then deleting the original.
    /// S3 has no native rename, so this is a copy-then-delete. Both steps must succeed;
    /// if the delete fails the copy is left in place and the error is re-thrown.
    /// - Parameters:
    ///   - key: Existing object key
    ///   - newKey: Destination key (must be in the same bucket)
    ///   - bucket: Bucket containing the object (defaults to currentBucket)
    func renameObject(key: String, to newKey: String, bucket: String? = nil) async throws {
        if client == nil { try await initializeClient() }
        guard let client = client else { throw S3ServiceError.clientNotInitialized }

        let targetBucket = bucket ?? currentBucket
        let copySource = "\(targetBucket)/\(key)"

        let copyInput = CopyObjectInput(
            bucket: targetBucket,
            copySource: copySource,
            key: newKey
        )
        _ = try await client.copyObject(input: copyInput)

        let deleteInput = DeleteObjectInput(bucket: targetBucket, key: key)
        _ = try await client.deleteObject(input: deleteInput)

        // Update the in-memory list so the UI reflects the new key without a reload.
        await MainActor.run {
            if let idx = recentFiles.firstIndex(where: { $0.key == key && ($0.bucket ?? currentBucket) == targetBucket }) {
                var updated = recentFiles[idx]
                updated = S3Object(
                    key: newKey,
                    size: updated.size,
                    lastModified: updated.lastModified,
                    etag: updated.etag,
                    bucket: updated.bucket
                )
                recentFiles[idx] = updated
                persistRecentFiles()
            }
        }

        logger.info("Renamed \(key) -> \(newKey) in \(targetBucket)")
    }

    /// Copies an object to a new key, optionally in a different bucket.
    /// The source is not deleted; use this for Copy. For Move, call this then deleteObject.
    /// - Parameters:
    ///   - key: Source object key
    ///   - destKey: Destination key
    ///   - sourceBucket: Bucket containing the source object (defaults to currentBucket)
    ///   - destBucket: Bucket for the destination (defaults to sourceBucket)
    func copyObject(
        key: String,
        to destKey: String,
        sourceBucket: String? = nil,
        destBucket: String? = nil
    ) async throws {
        if client == nil { try await initializeClient() }
        guard let client = client else { throw S3ServiceError.clientNotInitialized }

        let src = sourceBucket ?? currentBucket
        let dst = destBucket ?? src
        let copyInput = CopyObjectInput(
            bucket: dst,
            copySource: "\(src)/\(key)",
            key: destKey
        )
        _ = try await client.copyObject(input: copyInput)
        logger.info("Copied \(src)/\(key) -> \(dst)/\(destKey)")
    }

    /// Creates a virtual folder by PUTting a zero-byte object at `prefix + name + "/"`.
    /// - Parameters:
    ///   - name: Folder name without slashes. The trailing slash is appended automatically.
    ///   - prefix: Parent prefix. Empty string creates at the bucket root.
    ///   - bucket: Target bucket (defaults to `currentBucket`).
    func createFolder(named name: String, prefix: String = "", bucket: String? = nil) async throws {
        if client == nil { try await initializeClient() }
        guard let client = client else { throw S3ServiceError.clientNotInitialized }
        let target = bucket ?? currentBucket
        let key = prefix.isEmpty ? "\(name)/" : "\(prefix)\(name)/"
        let input = PutObjectInput(
            body: .data(Data()),
            bucket: target,
            contentLength: 0,
            contentType: "application/x-directory",
            key: key
        )
        _ = try await client.putObject(input: input)
        logger.info("Created folder \(target)/\(key)")
    }

    /// Lists one page of folders and files directly under a prefix.
    /// Does not touch the service's observable state (items, isLoading, currentPrefix),
    /// so it is safe to call from PrefixBrowserView alongside BucketBrowserView.
    /// - Parameters:
    ///   - prefix: S3 key prefix to list under. Empty string lists the bucket root.
    ///   - bucket: Bucket to list (defaults to currentBucket).
    ///   - continuationToken: Opaque token from a prior call's `nextToken` to fetch the
    ///     next page. Pass nil to start from the beginning.
    /// - Returns: A tuple of the page's items and an optional token for the next page.
    ///   When `nextToken` is nil the listing is complete.
    func listPrefix(
        _ prefix: String,
        bucket: String? = nil,
        continuationToken: String? = nil
    ) async throws -> (items: [S3Item], nextToken: String?) {
        if client == nil { try await initializeClient() }
        guard let client = client else { throw S3ServiceError.clientNotInitialized }

        let targetBucket = bucket ?? currentBucket
        let input = ListObjectsV2Input(
            bucket: targetBucket,
            continuationToken: continuationToken,
            delimiter: "/",
            prefix: prefix.isEmpty ? nil : prefix
        )
        let output = try await client.listObjectsV2(input: input)

        var items: [S3Item] = []
        if let commonPrefixes = output.commonPrefixes {
            for cp in commonPrefixes {
                if let p = cp.prefix {
                    items.append(.folder(S3Folder(prefix: p)))
                }
            }
        }
        if let contents = output.contents {
            for item in contents {
                guard let key = item.key, !key.hasSuffix("/") else { continue }
                items.append(.file(S3Object(
                    key: key,
                    size: Int64(item.size ?? 0),
                    lastModified: item.lastModified ?? Date(),
                    etag: item.eTag,
                    bucket: targetBucket
                )))
            }
        }
        return (items, output.nextContinuationToken)
    }

    /// Fetches metadata for an S3 object via HeadObject without downloading the body.
    /// - Parameters:
    ///   - key: S3 object key
    ///   - bucket: Bucket containing the object (defaults to currentBucket)
    /// - Returns: S3ObjectMetadata with content type, size, storage class, and user-defined metadata
    func headObject(key: String, bucket: String? = nil) async throws -> S3ObjectMetadata {
        if client == nil { try await initializeClient() }
        guard let client = client else { throw S3ServiceError.clientNotInitialized }

        let input = HeadObjectInput(bucket: bucket ?? currentBucket, key: key)
        let output = try await client.headObject(input: input)

        return S3ObjectMetadata(
            contentType: output.contentType,
            contentLength: output.contentLength,
            lastModified: output.lastModified,
            etag: output.eTag,
            storageClass: output.storageClass?.rawValue,
            cacheControl: output.cacheControl,
            contentEncoding: output.contentEncoding,
            versionId: output.versionId,
            expirationDate: parseExpirationDate(output.expiration),
            userMetadata: output.metadata ?? [:]
        )
    }

    /// Parses the `x-amz-expiration` header value into a human-readable date string.
    /// The header looks like: `expiry-date="Thu, 01 Jan 2026 00:00:00 GMT", rule-id="..."`.
    /// Returns nil when the header is absent or the date cannot be parsed.
    private func parseExpirationDate(_ header: String?) -> String? {
        guard let header else { return nil }
        // Extract the value inside expiry-date="..."
        guard let start = header.range(of: "expiry-date=\""),
              let end = header[start.upperBound...].range(of: "\"") else { return nil }
        let rawDate = String(header[start.upperBound..<end.lowerBound])
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = parser.date(from: rawDate) else { return rawDate }
        let display = DateFormatter()
        display.dateStyle = .medium
        display.timeStyle = .none
        return display.string(from: date)
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

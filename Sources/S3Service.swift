import Foundation
import AWSS3
import AWSSDKIdentity
import SmithyIdentity
import Smithy
import os.log
import CommonCrypto

@Observable
final class S3Service {
    private let logger = Logger(subsystem: "com.s3browser", category: "S3Service")
    private(set) var isLoading = false
    private(set) var items: [S3Item] = []
    private(set) var error: String?
    private(set) var availableBuckets: [String] = []
    private(set) var recentFiles: [S3Object] = []

    /// Status message during loading operations (e.g. "Fetching files..." or "Found 42 files")
    private(set) var loadingStatus: String = ""

    /// Current folder prefix being browsed. Empty string for bucket root.
    var currentPrefix: String = ""

    /// Currently selected bucket name
    var currentBucket: String = ""

    private var client: S3Client?
    private var config: S3Config

    /// Prefetch cache for file data downloaded in the background
    private var prefetchedData: [String: Data] = [:]
    private var prefetchTask: Task<Void, Never>?

    init(config: S3Config) {
        self.config = config
        self.currentBucket = config.bucketName
    }

    func updateConfig(_ config: S3Config) async throws {
        self.config = config
        try await initializeClient()
    }

    private func initializeClient() async throws {
        let credentials = SmithyIdentity.AWSCredentialIdentity(
            accessKey: config.accessKey,
            secret: config.secretKey
        )

        let identityResolver = try SmithyIdentity.StaticAWSCredentialIdentityResolver(credentials)

        let s3Config = try await S3Client.S3ClientConfiguration(
            awsCredentialIdentityResolver: identityResolver,
            region: config.region
        )

        client = S3Client(config: s3Config)
    }

    /// Fetches list of available S3 buckets
    func fetchAvailableBuckets() async throws {
        if client == nil {
            try await initializeClient()
        }

        guard let client = client else {
            throw S3ServiceError.clientNotInitialized
        }

        isLoading = true
        error = nil

        do {
            let input = ListBucketsInput()
            let output = try await client.listBuckets(input: input)

            var bucketNames: [String] = []
            if let buckets = output.buckets {
                for bucket in buckets {
                    if let name = bucket.name {
                        bucketNames.append(name)
                    }
                }
            }

            let sortedBuckets = bucketNames.sorted()
            await MainActor.run {
                self.availableBuckets = sortedBuckets
                self.isLoading = false
            }
        } catch {
            self.error = error.localizedDescription
            isLoading = false
            throw error
        }
    }

    /// Lists objects and folders in the current prefix
    func listObjects() async throws {
        if client == nil {
            try await initializeClient()
        }

        guard let client = client else {
            throw S3ServiceError.clientNotInitialized
        }

        isLoading = true
        error = nil
        loadingStatus = "Fetching files..."

        do {
            // Use currentPrefix directly for browsing - config.prefix is only used as initial default
            let input = ListObjectsV2Input(
                bucket: currentBucket,
                delimiter: "/",
                prefix: currentPrefix.isEmpty ? nil : currentPrefix
            )

            self.logger.debug("Calling listObjectsV2 - bucket: \(self.currentBucket), prefix: \(self.currentPrefix.isEmpty ? "(root)" : self.currentPrefix)")
            let output = try await client.listObjectsV2(input: input)
            self.logger.debug("Got response from S3")

            var s3Items: [S3Item] = []
            var folderCount = 0
            var fileCount = 0

            // Parse folders from commonPrefixes
            if let commonPrefixes = output.commonPrefixes {
                for prefix in commonPrefixes {
                    if let folderPrefix = prefix.prefix {
                        let folder = S3Folder(prefix: folderPrefix)
                        s3Items.append(.folder(folder))
                        folderCount += 1
                    }
                }
            }
            self.logger.debug("Found \(folderCount) folders")

            // Parse files from contents
            if let contents = output.contents {
                loadingStatus = "Processing \(contents.count) items..."
                for item in contents {
                    guard let key = item.key else { continue }
                    // Skip items that are just folder markers
                    if key.hasSuffix("/") { continue }

                    let object = S3Object(
                        key: key,
                        size: Int64(item.size ?? 0),
                        lastModified: item.lastModified ?? Date(),
                        etag: item.eTag
                    )
                    s3Items.append(.file(object))
                    fileCount += 1
                }
            }
            self.logger.debug("Found \(fileCount) files, total items: \(s3Items.count)")

            loadingStatus = "Loaded \(fileCount) files, \(folderCount) folders"
            items = s3Items
            isLoading = false
        } catch {
            self.error = error.localizedDescription
            loadingStatus = ""
            isLoading = false
            throw error
        }
    }

    /// Navigates into a folder
    /// - Parameter folderPrefix: The prefix of the folder to navigate into
    func navigateToFolder(_ folderPrefix: String) async throws {
        currentPrefix = folderPrefix
        try await listObjects()
    }

    /// Navigates up one level (to parent folder)
    func navigateUp() async throws {
        let components = currentPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(separator: "/")
        if components.isEmpty {
            currentPrefix = ""
        } else {
            let parentPath = components.dropLast().joined(separator: "/")
            currentPrefix = parentPath.isEmpty ? "" : parentPath + "/"
        }
        try await listObjects()
    }

    /// Returns path components for breadcrumb navigation
    func getPathComponents() -> [String] {
        let clean = currentPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !clean.isEmpty else { return [] }
        return clean.split(separator: "/").map(String.init)
    }

    /// Navigates to a specific path level in the breadcrumb
    /// - Parameter index: Index in the path (0-based), or -1 for root
    func navigateToBreadcrumb(_ index: Int) async throws {
        if index == -1 {
            currentPrefix = ""
        } else {
            let components = getPathComponents()
            guard index < components.count else { return }
            let path = components.prefix(through: index).joined(separator: "/")
            currentPrefix = path + "/"
        }
        try await listObjects()
    }

    /// Switches to a different bucket
    /// - Parameter bucketName: The name of the bucket to switch to
    func switchBucket(_ bucketName: String) async throws {
        currentBucket = bucketName
        currentPrefix = ""
        items = []
        recentFiles = []
        try await listObjects()
    }

    /// Fetches the most recent files from the current bucket recursively
    /// - Parameter limit: Maximum number of files to return (default 20)
    func fetchRecentFiles(limit: Int = 20) async throws {
        if client == nil {
            try await initializeClient()
        }

        guard let client = client else {
            throw S3ServiceError.clientNotInitialized
        }

        isLoading = true
        error = nil
        loadingStatus = "Scanning bucket..."

        do {
            var allFiles: [S3Object] = []
            var continuationToken: String? = nil
            var pageCount = 0

            // Recursively fetch all objects without delimiter to get all files
            repeat {
                let input = ListObjectsV2Input(
                    bucket: currentBucket,
                    continuationToken: continuationToken
                )

                let output = try await client.listObjectsV2(input: input)
                pageCount += 1

                if let contents = output.contents {
                    for item in contents {
                        guard let key = item.key else { continue }
                        // Skip folder markers
                        if key.hasSuffix("/") { continue }

                        let object = S3Object(
                            key: key,
                            size: Int64(item.size ?? 0),
                            lastModified: item.lastModified ?? Date(),
                            etag: item.eTag
                        )
                        allFiles.append(object)
                    }
                }

                loadingStatus = "Found \(allFiles.count) files\(continuationToken != nil ? ", scanning..." : "")"

                // Check for pagination
                continuationToken = output.nextContinuationToken
            } while continuationToken != nil

            // Sort by date descending and take top N
            let sorted = allFiles.sorted { $0.lastModified > $1.lastModified }
            recentFiles = Array(sorted.prefix(limit))
            loadingStatus = "Showing \(recentFiles.count) most recent of \(allFiles.count) files"
            isLoading = false
        } catch {
            self.error = error.localizedDescription
            loadingStatus = ""
            isLoading = false
            throw error
        }
    }

    /// Fetches the most recent files from ALL available buckets concurrently
    /// - Parameter limit: Maximum number of files to return per bucket (default 10)
    func fetchRecentFilesFromAllBuckets(limit: Int = 10) async throws {
        if client == nil {
            try await initializeClient()
        }

        guard let client = client else {
            throw S3ServiceError.clientNotInitialized
        }

        isLoading = true
        error = nil

        // Fetch bucket list if not already loaded
        if availableBuckets.isEmpty {
            try await fetchAvailableBuckets()
        }

        loadingStatus = "Scanning \(availableBuckets.count) buckets..."

        do {
            var allFiles: [S3Object] = []

            // Scan all buckets concurrently; per-bucket errors are skipped so one
            // inaccessible/wrong-region bucket doesn't abort the entire fetch
            await withTaskGroup(of: [S3Object].self) { group in
                for bucketName in availableBuckets {
                    group.addTask {
                        var bucketFiles: [S3Object] = []
                        var continuationToken: String? = nil

                        do {
                            repeat {
                                let input = ListObjectsV2Input(
                                    bucket: bucketName,
                                    continuationToken: continuationToken
                                )

                                let output = try await client.listObjectsV2(input: input)

                                if let contents = output.contents {
                                    for item in contents {
                                        guard let key = item.key else { continue }
                                        if key.hasSuffix("/") { continue }

                                        let object = S3Object(
                                            key: key,
                                            size: Int64(item.size ?? 0),
                                            lastModified: item.lastModified ?? Date(),
                                            etag: item.eTag,
                                            bucket: bucketName
                                        )
                                        bucketFiles.append(object)
                                    }
                                }

                                continuationToken = output.nextContinuationToken
                            } while continuationToken != nil
                        } catch {
                            // Skip buckets that are inaccessible or in a different region
                        }

                        return bucketFiles
                    }
                }

                for await bucketFiles in group {
                    // Cap each bucket's contribution to `limit` most recent files
                    // so a single high-frequency bucket can't crowd out others
                    let capped = bucketFiles.sorted { $0.lastModified > $1.lastModified }.prefix(limit)
                    allFiles.append(contentsOf: capped)
                }
            }

            // Sort combined capped results by date descending and take top N
            let sorted = allFiles.sorted { $0.lastModified > $1.lastModified }
            recentFiles = Array(sorted.prefix(limit))
            loadingStatus = "Showing \(recentFiles.count) most recent across \(availableBuckets.count) buckets"
            isLoading = false
        } catch {
            self.error = error.localizedDescription
            loadingStatus = ""
            isLoading = false
            throw error
        }
    }

    /// Fetches phone-mode reports from the phone-stash bucket in ONE ListObjectsV2
    /// call scoped to the reports/ prefix. The bucket holds only reports (small), and
    /// keys are reports/YYYY/MM/DD/HHMMSS-report.html so sorting by key descending puts
    /// the newest first. One network round-trip - this is the fast Stash path.
    func fetchStashReports(bucket: String = "phone-stash", limit: Int = 100) async throws -> [S3Object] {
        if client == nil { try await initializeClient() }
        guard let client = client else { throw S3ServiceError.clientNotInitialized }

        let input = ListObjectsV2Input(bucket: bucket, maxKeys: 1000, prefix: "reports/")
        let output = try await client.listObjectsV2(input: input)

        var files: [S3Object] = []
        for item in output.contents ?? [] {
            guard let key = item.key, !key.hasSuffix("/") else { continue }
            files.append(S3Object(
                key: key,
                size: Int64(item.size ?? 0),
                lastModified: item.lastModified ?? Date(),
                etag: item.eTag,
                bucket: bucket
            ))
        }
        // Keys are date-sorted, so lexicographic descending == newest first.
        let sorted = files.sorted { $0.key > $1.key }
        return Array(sorted.prefix(limit))
    }

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

        let data = try await body.readData()
        return data ?? Data()
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

    func getPublicURL(for key: String) -> URL? {
        let host = config.region == "us-east-1"
            ? "\(currentBucket).s3.amazonaws.com"
            : "\(currentBucket).s3.\(config.region).amazonaws.com"

        return URL(string: "https://\(host)/\(key)")
    }

    /// Generates a presigned URL for an S3 object that expires after a given duration.
    /// Anyone with the link can access the file until expiration.
    /// - Parameters:
    ///   - key: The S3 object key
    ///   - bucket: Optional bucket (defaults to currentBucket)
    ///   - expiresIn: Seconds until the URL expires (default 7 days, max 7 days)
    /// - Returns: A presigned URL string
    func generatePresignedURL(for key: String, bucket: String? = nil, expiresIn: Int = 86400) -> String? {
        let bucketName = bucket ?? currentBucket
        let region = config.region
        let host = region == "us-east-1"
            ? "\(bucketName).s3.amazonaws.com"
            : "\(bucketName).s3.\(region).amazonaws.com"

        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(identifier: "UTC")

        dateFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = dateFormatter.string(from: now)

        dateFormatter.dateFormat = "yyyyMMdd"
        let dateStamp = dateFormatter.string(from: now)

        let credentialScope = "\(dateStamp)/\(region)/s3/aws4_request"
        let credential = "\(config.accessKey)/\(credentialScope)"

        // URL-encode the key components individually
        let encodedKey = key.split(separator: "/").map { component in
            component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String(component)
        }.joined(separator: "/")

        let signedHeaders = "host"
        // AWS Sig V4 requires / to be encoded as %2F in query parameters
        var awsQueryAllowed = CharacterSet.urlQueryAllowed
        awsQueryAllowed.remove("/")
        let encodedCredential = credential.addingPercentEncoding(withAllowedCharacters: awsQueryAllowed) ?? credential
        let queryParams = [
            "X-Amz-Algorithm=AWS4-HMAC-SHA256",
            "X-Amz-Credential=\(encodedCredential)",
            "X-Amz-Date=\(amzDate)",
            "X-Amz-Expires=\(expiresIn)",
            "X-Amz-SignedHeaders=\(signedHeaders)",
        ].joined(separator: "&")

        let canonicalRequest = [
            "GET",
            "/\(encodedKey)",
            queryParams,
            "host:\(host)",
            "",
            signedHeaders,
            "UNSIGNED-PAYLOAD"
        ].joined(separator: "\n")

        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            credentialScope,
            S3PresignHelper.sha256Hex(canonicalRequest.data(using: .utf8)!)
        ].joined(separator: "\n")

        let kDate = S3PresignHelper.hmacSHA256(key: "AWS4\(config.secretKey)".data(using: .utf8)!, data: dateStamp.data(using: .utf8)!)
        let kRegion = S3PresignHelper.hmacSHA256(key: kDate, data: region.data(using: .utf8)!)
        let kService = S3PresignHelper.hmacSHA256(key: kRegion, data: "s3".data(using: .utf8)!)
        let kSigning = S3PresignHelper.hmacSHA256(key: kService, data: "aws4_request".data(using: .utf8)!)

        let signature = S3PresignHelper.hmacSHA256(key: kSigning, data: stringToSign.data(using: .utf8)!)
            .map { String(format: "%02x", $0) }.joined()

        return "https://\(host)/\(encodedKey)?\(queryParams)&X-Amz-Signature=\(signature)"
    }

    /// Deletes an object from S3
    /// - Parameters:
    ///   - key: The S3 object key to delete
    ///   - bucket: Bucket the object lives in. Defaults to currentBucket. Recent Files
    ///     mixes objects from all buckets, so callers there must pass the object's own bucket -
    ///     deleting a key from the wrong bucket "succeeds" silently and the file stays.
    /// - Throws: S3ServiceError if the client is not initialized or AWS SDK errors
    func deleteObject(key: String, bucket: String? = nil) async throws {
        guard let client = client else {
            throw S3ServiceError.clientNotInitialized
        }

        let targetBucket = bucket ?? currentBucket

        do {
            let input = DeleteObjectInput(
                bucket: targetBucket,
                key: key
            )

            _ = try await client.deleteObject(input: input)

            // Update local arrays to reflect deletion
            await MainActor.run {
                items.removeAll { item in
                    if case .file(let object) = item {
                        return object.key == key
                    }
                    return false
                }
                recentFiles.removeAll { object in
                    object.key == key && (object.bucket ?? currentBucket) == targetBucket
                }
            }
        } catch {
            self.logger.error("Failed to delete object '\(key)' from '\(targetBucket)': \(error.localizedDescription)")
            throw error
        }
    }

    /// Uploads data to S3 bucket
    /// - Parameters:
    ///   - data: The data to upload
    ///   - key: The S3 object key (path)
    ///   - contentType: MIME type of the content
    /// - Returns: The key of the uploaded object
    @discardableResult
    func uploadObject(data: Data, key: String, contentType: String = "application/octet-stream") async throws -> String {
        if client == nil {
            try await initializeClient()
        }

        guard let client = client else {
            throw S3ServiceError.clientNotInitialized
        }

        let input = PutObjectInput(
            body: .data(data),
            bucket: currentBucket,
            contentType: contentType,
            key: key
        )

        logger.info("Uploading to \(self.currentBucket)/\(key) (\(data.count) bytes)")
        _ = try await client.putObject(input: input)
        logger.info("Upload complete: \(key)")

        return key
    }

    /// Fetches all files from the dump/ prefix, sorted by most recent first
    /// - Returns: Array of S3Object from the dump/ folder
    func fetchDumpFiles() async throws -> [S3Object] {
        if client == nil {
            try await initializeClient()
        }

        guard let client = client else {
            throw S3ServiceError.clientNotInitialized
        }

        var allFiles: [S3Object] = []
        var continuationToken: String? = nil

        repeat {
            let input = ListObjectsV2Input(
                bucket: currentBucket,
                continuationToken: continuationToken,
                prefix: "dump/"
            )

            let output = try await client.listObjectsV2(input: input)

            if let contents = output.contents {
                for item in contents {
                    guard let key = item.key else { continue }
                    if key.hasSuffix("/") { continue }

                    let object = S3Object(
                        key: key,
                        size: Int64(item.size ?? 0),
                        lastModified: item.lastModified ?? Date(),
                        etag: item.eTag
                    )
                    allFiles.append(object)
                }
            }

            continuationToken = output.nextContinuationToken
        } while continuationToken != nil

        return allFiles.sorted { $0.lastModified > $1.lastModified }
    }

    /// Uploads an image to the dump folder with timestamp
    /// - Parameter imageData: JPEG or PNG image data
    /// - Returns: The full S3 key of the uploaded image
    func uploadToDump(imageData: Data) async throws -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let filename = "dump/\(timestamp).jpg"

        return try await uploadObject(
            data: imageData,
            key: filename,
            contentType: "image/jpeg"
        )
    }

    /// Uploads media (image or video) to the dump folder with timestamp
    /// - Parameters:
    ///   - data: The file data
    ///   - fileExtension: File extension (e.g. "jpg", "mp4", "mov")
    ///   - contentType: MIME type of the content
    /// - Returns: The full S3 key of the uploaded file
    func uploadToDump(data: Data, fileExtension: String, contentType: String) async throws -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let filename = "dump/\(timestamp).\(fileExtension)"

        return try await uploadObject(
            data: data,
            key: filename,
            contentType: contentType
        )
    }
}

enum S3ServiceError: LocalizedError {
    case clientNotInitialized
    case noDataReturned

    var errorDescription: String? {
        switch self {
        case .clientNotInitialized:
            return "S3 client not initialized. Please configure credentials."
        case .noDataReturned:
            return "No data returned from S3"
        }
    }
}

/// Crypto helpers for AWS Signature V4 presigned URLs
enum S3PresignHelper {
    static func sha256Hex(_ data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    static func hmacSHA256(key: Data, data: Data) -> Data {
        var hmac = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        key.withUnsafeBytes { keyBuffer in
            data.withUnsafeBytes { dataBuffer in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256),
                       keyBuffer.baseAddress, key.count,
                       dataBuffer.baseAddress, data.count,
                       &hmac)
            }
        }
        return Data(hmac)
    }
}


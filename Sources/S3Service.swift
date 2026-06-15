import Foundation
import AWSS3
import AWSSDKIdentity
import SmithyIdentity
import Smithy
import os.log
import CommonCrypto

@Observable
final class S3Service {
    // Internal (not private) so the S3Service+* extension files can reach the client,
    // config, prefetch cache, and logger. Swift file-scopes `private`, so these would be
    // invisible to extensions living in other files.
    let logger = Logger(subsystem: "com.s3browser", category: "S3Service")
    // These four use an internal (not private) setter so the S3Service+* extension files,
    // which live in other files in the same module, can update loading state and results.
    // `private(set)` would file-scope the setter and make it invisible to those extensions.
    internal(set) var isLoading = false
    private(set) var items: [S3Item] = []
    internal(set) var error: String?
    private(set) var availableBuckets: [String] = []
    internal(set) var recentFiles: [S3Object] = []

    /// Status message during loading operations (e.g. "Fetching files..." or "Found 42 files")
    internal(set) var loadingStatus: String = ""

    /// Current folder prefix being browsed. Empty string for bucket root.
    var currentPrefix: String = ""

    /// Currently selected bucket name
    var currentBucket: String = ""

    var client: S3Client?
    var config: S3Config

    /// Prefetch cache for file data downloaded in the background
    var prefetchedData: [String: Data] = [:]
    var prefetchTask: Task<Void, Never>?

    init(config: S3Config) {
        self.config = config
        self.currentBucket = config.bucketName
    }

    func updateConfig(_ config: S3Config) async throws {
        self.config = config
        try await initializeClient()
    }

    func initializeClient() async throws {
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

    /// Clears the in-memory recent files list. recentFiles is private(set), so callers
    /// outside S3Service go through this to empty it (for example the Clear All button).
    @MainActor
    func clearRecentFiles() {
        recentFiles.removeAll()
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


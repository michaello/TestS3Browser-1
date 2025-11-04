import Foundation
import AWSS3
import AWSSDKIdentity
import SmithyIdentity
import Smithy
import os.log

@Observable
final class S3Service {
    private let logger = Logger(subsystem: "com.s3browser", category: "S3Service")
    private(set) var isLoading = false
    private(set) var items: [S3Item] = []
    private(set) var error: String?
    private(set) var availableBuckets: [String] = []
    private(set) var recentFiles: [S3Object] = []

    /// Current folder prefix being browsed. Empty string for bucket root.
    var currentPrefix: String = ""

    /// Currently selected bucket name
    var currentBucket: String = ""

    private var client: S3Client?
    private var config: S3Config

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

        do {
            let prefix = config.prefix.isEmpty ? currentPrefix : (config.prefix + currentPrefix)
            let input = ListObjectsV2Input(
                bucket: currentBucket,
                delimiter: "/",
                prefix: prefix.isEmpty ? nil : prefix
            )

            self.logger.debug("Calling listObjectsV2 - bucket: \(self.currentBucket), prefix: \(prefix.isEmpty ? "(root)" : prefix)")
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

            items = s3Items
            isLoading = false
        } catch {
            self.error = error.localizedDescription
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

        do {
            var allFiles: [S3Object] = []
            var continuationToken: String? = nil

            // Recursively fetch all objects without delimiter to get all files
            repeat {
                let input = ListObjectsV2Input(
                    bucket: currentBucket,
                    continuationToken: continuationToken
                )

                let output = try await client.listObjectsV2(input: input)

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

                // Check for pagination
                continuationToken = output.nextContinuationToken
            } while continuationToken != nil

            // Sort by date descending and take top N
            let sorted = allFiles.sorted { $0.lastModified > $1.lastModified }
            recentFiles = Array(sorted.prefix(limit))
            isLoading = false
        } catch {
            self.error = error.localizedDescription
            isLoading = false
            throw error
        }
    }

    func downloadObject(key: String) async throws -> Data {
        guard let client = client else {
            throw S3ServiceError.clientNotInitialized
        }

        let input = GetObjectInput(
            bucket: currentBucket,
            key: key
        )

        let output = try await client.getObject(input: input)

        guard let body = output.body else {
            throw S3ServiceError.noDataReturned
        }

        let data = try await body.readData()
        return data ?? Data()
    }

    func getPublicURL(for key: String) -> URL? {
        let host = config.region == "us-east-1"
            ? "\(currentBucket).s3.amazonaws.com"
            : "\(currentBucket).s3.\(config.region).amazonaws.com"

        return URL(string: "https://\(host)/\(key)")
    }

    /// Deletes an object from the S3 bucket
    /// - Parameter key: The S3 object key to delete
    /// - Throws: S3ServiceError if the client is not initialized or AWS SDK errors
    func deleteObject(key: String) async throws {
        guard let client = client else {
            throw S3ServiceError.clientNotInitialized
        }

        do {
            let input = DeleteObjectInput(
                bucket: currentBucket,
                key: key
            )

            _ = try await client.deleteObject(input: input)

            // Update local items array to reflect deletion
            await MainActor.run {
                items.removeAll { item in
                    if case .file(let object) = item {
                        return object.key == key
                    }
                    return false
                }
            }
        } catch {
            self.logger.error("Failed to delete object '\(key)': \(error.localizedDescription)")
            throw error
        }
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


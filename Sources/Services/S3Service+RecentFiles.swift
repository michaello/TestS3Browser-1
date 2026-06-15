import Foundation
import AWSS3

/// Recent-files and stash-report listing for S3Service. Split out of S3Service.swift to keep
/// each file under 500 lines. These methods read/write the recentFiles state that lives on the
/// main S3Service type.
extension S3Service {
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

                // Check for pagination
                continuationToken = output.nextContinuationToken
                loadingStatus = "Found \(allFiles.count) files\(continuationToken != nil ? ", scanning..." : "")"
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

        // fetchAvailableBuckets clears isLoading on success, so set it back true for the scan.
        isLoading = true
        loadingStatus = "Scanning \(availableBuckets.count) buckets..."

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
}

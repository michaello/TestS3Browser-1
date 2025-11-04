import Foundation
import AWSS3
import AWSSDKIdentity
import SmithyIdentity
import Smithy

@Observable
final class S3Service {
    private(set) var isLoading = false
    private(set) var objects: [S3Object] = []
    private(set) var error: String?

    private var client: S3Client?
    private var config: S3Config

    init(config: S3Config) {
        self.config = config
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
            let input = ListObjectsV2Input(
                bucket: config.bucketName,
                prefix: config.prefix.isEmpty ? nil : config.prefix
            )

            let output = try await client.listObjectsV2(input: input)

            var s3Objects: [S3Object] = []

            if let contents = output.contents {
                for item in contents {
                    guard let key = item.key else { continue }

                    let object = S3Object(
                        key: key,
                        size: Int64(item.size ?? 0),
                        lastModified: item.lastModified ?? Date(),
                        etag: item.eTag
                    )
                    s3Objects.append(object)
                }
            }

            objects = s3Objects.sorted { $0.lastModified > $1.lastModified }
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
            bucket: config.bucketName,
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
            ? "\(config.bucketName).s3.amazonaws.com"
            : "\(config.bucketName).s3.\(config.region).amazonaws.com"

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
                bucket: config.bucketName,
                key: key
            )

            _ = try await client.deleteObject(input: input)

            // Update local objects array to reflect deletion
            await MainActor.run {
                objects.removeAll { $0.key == key }
            }
        } catch {
            print("[S3Service:134] Failed to delete object '\(key)': \(error.localizedDescription)")
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


import Foundation

extension S3Service {
    func getPublicURL(for key: String, bucket: String? = nil) -> URL? {
        S3ObjectAddress.publicURL(bucket: bucket ?? currentBucket, region: config.region, key: key)
    }

    func generatePresignedURL(for key: String, bucket: String? = nil, expiresIn: Int = 86400) -> String? {
        S3ObjectAddress.presignedURL(bucket: bucket ?? currentBucket, region: config.region, key: key,
            accessKey: config.accessKey, secretKey: config.secretKey, expiresIn: expiresIn)
    }
}

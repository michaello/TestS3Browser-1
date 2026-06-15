import Foundation
import CommonCrypto

/// Public and presigned URL generation for S3Service, plus the AWS Signature V4 crypto helpers.
/// Split out of S3Service.swift to keep each file under 500 lines.
extension S3Service {
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
    ///   - expiresIn: Seconds until the URL expires (default 1 day, max 7 days for presigned GET)
    /// - Returns: A presigned URL string, or nil if any input cannot be UTF-8 encoded
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
            S3PresignHelper.sha256Hex(Data(canonicalRequest.utf8))
        ].joined(separator: "\n")

        let kDate = S3PresignHelper.hmacSHA256(key: Data("AWS4\(config.secretKey)".utf8), data: Data(dateStamp.utf8))
        let kRegion = S3PresignHelper.hmacSHA256(key: kDate, data: Data(region.utf8))
        let kService = S3PresignHelper.hmacSHA256(key: kRegion, data: Data("s3".utf8))
        let kSigning = S3PresignHelper.hmacSHA256(key: kService, data: Data("aws4_request".utf8))

        let signature = S3PresignHelper.hmacSHA256(key: kSigning, data: Data(stringToSign.utf8))
            .map { String(format: "%02x", $0) }.joined()

        return "https://\(host)/\(encodedKey)?\(queryParams)&X-Amz-Signature=\(signature)"
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

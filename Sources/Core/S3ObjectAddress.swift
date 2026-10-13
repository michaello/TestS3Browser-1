import CryptoKit
import Foundation

enum S3URIEncoding {
    /// AWS URI encoding acts on original UTF-8 bytes and never normalizes a key.
    static func encode(_ value: String, preserveSlashes: Bool = false) -> String {
        value.utf8.map { byte in
            if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) ||
                [45, 46, 95, 126].contains(byte) || (preserveSlashes && byte == 47) {
                return String(UnicodeScalar(byte))
            }
            return String(format: "%%%02X", byte)
        }.joined()
    }
}

enum S3ObjectAddress {
    static func host(bucket: String, region: String) -> String {
        region == "us-east-1" ? "\(bucket).s3.amazonaws.com" : "\(bucket).s3.\(region).amazonaws.com"
    }

    static func publicURL(bucket: String, region: String, key: String) -> URL? {
        URL(string: "https://\(host(bucket: bucket, region: region))/\(S3URIEncoding.encode(key, preserveSlashes: true))")
    }

    /// Deterministic clock input supports the published AWS SigV4 regression vector.
    /// https://docs.aws.amazon.com/AmazonS3/latest/developerguide/sigv4-query-string-auth.html
    static func presignedURL(bucket: String, region: String, key: String, accessKey: String,
                             secretKey: String, expiresIn: Int, now: Date = Date()) -> String? {
        guard (1...604_800).contains(expiresIn), !bucket.isEmpty, !region.isEmpty,
              !accessKey.isEmpty, !secretKey.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let timestamp = formatter.string(from: now)
        formatter.dateFormat = "yyyyMMdd"
        let date = formatter.string(from: now)
        let scope = "\(date)/\(region)/s3/aws4_request"
        let query = [
            ("X-Amz-Algorithm", "AWS4-HMAC-SHA256"), ("X-Amz-Credential", accessKey + "/" + scope),
            ("X-Amz-Date", timestamp), ("X-Amz-Expires", String(expiresIn)), ("X-Amz-SignedHeaders", "host")
        ].map { S3URIEncoding.encode($0.0) + "=" + S3URIEncoding.encode($0.1) }.sorted().joined(separator: "&")
        let host = host(bucket: bucket, region: region)
        let path = "/" + S3URIEncoding.encode(key, preserveSlashes: true)
        let canonical = ["GET", path, query, "host:" + host + "\n", "host", "UNSIGNED-PAYLOAD"].joined(separator: "\n")
        let hash = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        let stringToSign = ["AWS4-HMAC-SHA256", timestamp, scope, hash].joined(separator: "\n")
        func hmac(_ key: Data, _ value: String) -> Data {
            Data(HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: SymmetricKey(data: key)))
        }
        let signing = hmac(hmac(hmac(hmac(Data(("AWS4" + secretKey).utf8), date), region), "s3"), "aws4_request")
        let signature = hmac(signing, stringToSign).map { String(format: "%02x", $0) }.joined()
        return "https://" + host + path + "?" + query + "&X-Amz-Signature=" + signature
    }
}

enum S3PrefixPath {
    static func components(_ prefix: String) -> [String] {
        guard !prefix.isEmpty else { return [] }
        let content = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
        return content.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    }

    static func breadcrumb(_ prefix: String, index: Int) -> String? {
        if index == -1 { return "" }
        let parts = components(prefix)
        guard parts.indices.contains(index) else { return nil }
        return parts.prefix(index + 1).joined(separator: "/") + "/"
    }

    static func parent(_ prefix: String) -> String {
        let content = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
        return S3TransferKeys.parentPrefix(of: content)
    }

    static func folderName(_ prefix: String) -> String {
        let content = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
        let name = S3TransferKeys.fileName(of: content)
        return name.isEmpty ? "/" : name
    }
}

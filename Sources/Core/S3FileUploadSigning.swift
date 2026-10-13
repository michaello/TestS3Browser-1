import CryptoKit
import Foundation

struct SignedFileUpload: Sendable {
    let request: URLRequest
    let bytes: Int64
}

actor S3FileUploadSigning {
    static let shared = S3FileUploadSigning()
    func request(file: URL, bucket: String, region: String, key: String, accessKey: String,
                 secretKey: String, contentType: String, now: Date = Date()) throws -> SignedFileUpload {
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var digest = SHA256(), count: Int64 = 0
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            try Task.checkCancellation()
            digest.update(data: chunk)
            count += Int64(chunk.count)
        }
        let payloadHash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        let host = S3ObjectAddress.host(bucket: bucket, region: region)
        let path = "/" + S3URIEncoding.encode(key, preserveSlashes: true)
        guard let url = URL(string: "https://" + host + path) else { throw UploadPreparationError.unavailableRepresentation }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let timestamp = formatter.string(from: now)
        formatter.dateFormat = "yyyyMMdd"
        let date = formatter.string(from: now)
        let scope = date + "/" + region + "/s3/aws4_request"
        let signedHeaders = "content-type;host;x-amz-content-sha256;x-amz-date"
        let canonicalHeaders = "content-type:\(contentType)\nhost:\(host)\nx-amz-content-sha256:\(payloadHash)\nx-amz-date:\(timestamp)\n"
        let canonical = ["PUT", path, "", canonicalHeaders, signedHeaders, payloadHash].joined(separator: "\n")
        let canonicalHash = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        let toSign = ["AWS4-HMAC-SHA256", timestamp, scope, canonicalHash].joined(separator: "\n")
        func hmac(_ key: Data, _ value: String) -> Data {
            Data(HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: SymmetricKey(data: key)))
        }
        let signing = hmac(hmac(hmac(hmac(Data(("AWS4" + secretKey).utf8), date), region), "s3"), "aws4_request")
        let signature = hmac(signing, toSign).map { String(format: "%02x", $0) }.joined()
        var request = URLRequest(url: url, timeoutInterval: 600)
        request.httpMethod = "PUT"
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(timestamp, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(String(count), forHTTPHeaderField: "Content-Length")
        request.setValue("AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
                         forHTTPHeaderField: "Authorization")
        return SignedFileUpload(request: request, bytes: count)
    }
}

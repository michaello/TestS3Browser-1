import Foundation

enum S3TransferKeys {
    static func identifier(bucket: String?, key: String) -> String {
        let bucketField = bucket.map { "1" + Data($0.utf8).base64EncodedString() } ?? "0"
        return bucketField + "." + Data(key.utf8).base64EncodedString()
    }

    static func parentPrefix(of key: String) -> String {
        key.lastIndex(of: "/").map { String(key[...$0]) } ?? ""
    }

    static func fileName(of key: String) -> String {
        key.lastIndex(of: "/").map { String(key[key.index(after: $0)...]) } ?? key
    }

    static func isSameDestination(sourceBucket: String, sourceKey: String,
                                  destinationBucket: String, destinationPrefix: String) -> Bool {
        sourceBucket.utf8.elementsEqual(destinationBucket.utf8) &&
        sourceKey.utf8.elementsEqual((destinationPrefix + fileName(of: sourceKey)).utf8)
    }
}

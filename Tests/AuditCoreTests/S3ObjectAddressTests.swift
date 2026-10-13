import Foundation
import Testing
@testable import AuditCore

struct F24ObjectAddressTests {
    @Test func reservedBytesAndRepeatedSlashesSurvivePublicAndPresignedURLs() throws {
        let key = "/folder//a #?+%20/你好.txt"
        let encoded = "/folder//a%20%23%3F%2B%2520/%E4%BD%A0%E5%A5%BD.txt"
        let publicURL = try #require(S3ObjectAddress.publicURL(bucket: "b", region: "eu-west-1", key: key))
        let components = try #require(URLComponents(url: publicURL, resolvingAgainstBaseURL: false))
        #expect(components.percentEncodedPath == "/" + encoded)
        #expect(components.query == nil)
        #expect(components.fragment == nil)
        #expect(components.path.utf8.elementsEqual(("/" + key).utf8))
        let signed = try #require(S3ObjectAddress.presignedURL(bucket: "b", region: "eu-west-1", key: key,
            accessKey: "dummy/+?%", secretKey: "dummy", expiresIn: 60, now: Date(timeIntervalSince1970: 0)))
        let signedComponents = try #require(URLComponents(string: signed))
        #expect(signedComponents.percentEncodedPath == components.percentEncodedPath)
        #expect(signedComponents.queryItems?.first { $0.name == "X-Amz-Credential" }?.value?.hasPrefix("dummy/+?%/") == true)
    }

    @Test func unicodeByteSpellingsAndLiteralPercentNamesRemainDistinct() throws {
        let keys = ["café", "cafe\u{301}", "%2F", "/", "a//b", "a/b"]
        let addresses = try keys.map { key in
            try #require(S3ObjectAddress.publicURL(bucket: "b", region: "us-east-1", key: key)).absoluteString
        }
        #expect(Set(addresses).count == keys.count)
        #expect(Set(keys.map { S3TransferKeys.identifier(bucket: "b", key: $0) }).count == keys.count)
        #expect(S3TransferKeys.identifier(bucket: nil, key: "a") != S3TransferKeys.identifier(bucket: "", key: "a"))
    }

    @Test func fileNamesAndNavigationNeverInterpretURLSyntax() {
        #expect(S3TransferKeys.fileName(of: "folder//a#?+%2F.txt") == "a#?+%2F.txt")
        #expect(S3PrefixPath.folderName("folder//a#?+%2F/   ") == "   ")
        #expect(S3PrefixPath.components("/a//b/") == ["", "a", "", "b"])
        #expect(S3PrefixPath.parent("/a//b/") == "/a//")
        #expect(S3PrefixPath.parent("/a//") == "/a/")
        #expect(S3PrefixPath.breadcrumb("/a//b/", index: 2) == "/a//")
        #expect(S3PrefixPath.breadcrumb("/a//b/", index: -1) == "")
        #expect(S3PrefixPath.breadcrumb("/a//b/", index: -2) == nil)
    }

    @Test func publishedAWSSigV4ExampleMatches() throws {
        // Public dummy credentials and expected digest from AWS documentation.
        let date = try #require(ISO8601DateFormatter().date(from: "2013-05-24T00:00:00Z"))
        let result = try #require(S3ObjectAddress.presignedURL(bucket: "examplebucket", region: "us-east-1", key: "test.txt",
            accessKey: "AKIAIOSFODNN7EXAMPLE", secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            expiresIn: 86_400, now: date))
        #expect(result.hasSuffix("X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"))
    }

    @Test func invalidExpirationCannotProduceSignedURL() {
        for seconds in [Int.min, -1, 0, 604_801, Int.max] {
            #expect(S3ObjectAddress.presignedURL(bucket: "b", region: "us-east-1", key: "key", accessKey: "dummy",
                secretKey: "dummy", expiresIn: seconds) == nil)
        }
    }
}

struct N30CopySourceEncodingTests {
    @Test func keyAndVersionAreEncodedExactlyOnce() throws {
        let key = "/dir//a?#+%2F/你好"
        let version = "v/+%?&=#é"
        let encoded = S3CopySource.encoded(bucket: "b", key: key, versionID: version)
        #expect(encoded == "b//dir//a%3F%23%2B%252F/%E4%BD%A0%E5%A5%BD?versionId=v%2F%2B%25%3F%26%3D%23%C3%A9")
        let parts = encoded.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        #expect(String(parts[0]).removingPercentEncoding?.utf8.elementsEqual(("b/" + key).utf8) == true)
        let query = try #require(URLComponents(string: "https://fixture/?" + parts[1]))
        #expect(query.queryItems?.count == 1)
        #expect(query.queryItems?.first?.value?.utf8.elementsEqual(version.utf8) == true)
    }

    @Test func literalEncodedLookingKeyAndRealSlashSelectDifferentFixtureObjects() throws {
        let stored: [String: Data] = ["a%2Fb": Data([1]), "a/b": Data([2]), "a//b": Data([3])]
        for (key, expected) in stored {
            let header = S3CopySource.encoded(bucket: "b", key: key)
            let decoded = try #require(header.removingPercentEncoding)
            let receivedKey = String(decoded.dropFirst(2))
            #expect(stored[receivedKey] == expected)
        }
    }

    @Test func unicodeNormalizationDoesNotChangeCopyHeader() {
        #expect(S3CopySource.encoded(bucket: "b", key: "é") != S3CopySource.encoded(bucket: "b", key: "e\u{301}"))
        #expect(S3CopySource.encoded(bucket: "b", key: "key", versionID: nil) == "b/key")
        #expect(S3CopySource.encoded(bucket: "b", key: "key", versionID: "") == "b/key?versionId=")
    }
}

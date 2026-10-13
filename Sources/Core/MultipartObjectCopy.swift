import Foundation

struct MultipartCopyPart: Equatable, Sendable {
    let number: Int
    let firstByte: Int64
    let lastByte: Int64
    var range: String { "bytes=\(firstByte)-\(lastByte)" }
}

struct MultipartCopyPlan: Sendable {
    // S3 limits: 5 GiB per part, 10,000 parts, 5 MiB minimum except the final part.
    // https://docs.aws.amazon.com/AmazonS3/latest/userguide/qfacts.html
    static let singleCopyLimit: Int64 = 5_000_000_000
    static let maximumPartBytes: Int64 = 5 * 1024 * 1024 * 1024
    let parts: [MultipartCopyPart]

    init(bytes: Int64, preferredPartBytes: Int64 = 64 * 1024 * 1024) throws {
        guard bytes > 0, bytes <= Self.maximumPartBytes * 10_000 else { throw MultipartCopyError.invalidSize }
        let required = (bytes - 1) / 10_000 + 1
        let partSize = max(5 * 1024 * 1024, min(Self.maximumPartBytes, max(required, preferredPartBytes)))
        var parts: [MultipartCopyPart] = []
        var offset: Int64 = 0
        while offset < bytes {
            let end = offset + min(partSize, bytes - offset) - 1
            parts.append(.init(number: parts.count + 1, firstByte: offset, lastByte: end))
            offset = end + 1
        }
        self.parts = parts
    }
}

struct MultipartCopyProperties: Equatable, Sendable {
    var metadata: [String: String] = [:]
    var headers: [String: String] = [:]
    var tags: [ObjectTag] = []
}

struct MultipartCopiedPart: Sendable {
    let number: Int
    let etag: String
}

enum MultipartDestinationCondition: Equatable, Sendable {
    case absent, matchingETag(String)
    init(_ presence: TransferObjectPresence) throws {
        switch presence {
        case .absent: self = .absent
        case .present(let revision):
            guard let etag = revision.etag, !etag.isEmpty else { throw MultipartCopyError.destinationRevisionUnavailable }
            self = .matchingETag(etag)
        }
    }
}

enum MultipartCopyError: LocalizedError {
    case invalidSize, invalidResponse, destinationRevisionUnavailable
    case cleanupFailed(uploadID: String, original: String, cleanup: String)
    var errorDescription: String? {
        switch self {
        case .invalidSize: return "The object size cannot be represented by S3 multipart-copy limits."
        case .invalidResponse: return "S3 did not confirm the multipart copy. The source was retained."
        case .destinationRevisionUnavailable: return "S3 did not return the destination ETag required for safe multipart replacement. No copy was started."
        case .cleanupFailed(let id, let original, let cleanup):
            return "Copy failed: \(original). Multipart cleanup failed for upload \(id): \(cleanup). The source was retained."
        }
    }
}

@MainActor
protocol MultipartCopyTransport {
    func validateContext() throws
    func create(properties: MultipartCopyProperties) async throws -> String
    func copyPart(uploadID: String, part: MultipartCopyPart) async throws -> String
    func complete(uploadID: String, parts: [MultipartCopiedPart], condition: MultipartDestinationCondition) async throws -> TransferObjectRevision
    func abort(uploadID: String) async throws
}

@MainActor
enum MultipartObjectCopy {
    @discardableResult
    static func perform(bytes: Int64, properties: MultipartCopyProperties,
                        destination: TransferObjectPresence = .absent,
                        transport: any MultipartCopyTransport) async throws -> TransferObjectRevision {
        let plan = try MultipartCopyPlan(bytes: bytes)
        let condition = try MultipartDestinationCondition(destination)
        try Task.checkCancellation()
        try transport.validateContext()
        let uploadID = try await transport.create(properties: properties)
        guard !uploadID.isEmpty else { throw MultipartCopyError.invalidResponse }
        do {
            var copied: [MultipartCopiedPart] = []
            for part in plan.parts {
                try Task.checkCancellation()
                try transport.validateContext()
                let etag = try await transport.copyPart(uploadID: uploadID, part: part)
                guard !etag.isEmpty else { throw MultipartCopyError.invalidResponse }
                copied.append(.init(number: part.number, etag: etag))
            }
            try Task.checkCancellation()
            try transport.validateContext()
            let revision = try await transport.complete(uploadID: uploadID, parts: copied, condition: condition)
            guard let etag = revision.etag, !etag.isEmpty else { throw MultipartCopyError.invalidResponse }
            return revision
        } catch {
            // An owned cleanup task must run even when the caller is already cancelled.
            let original = error
            do { try await Task { @MainActor in try await transport.abort(uploadID: uploadID) }.value }
            catch { throw MultipartCopyError.cleanupFailed(uploadID: uploadID,
                original: original.localizedDescription, cleanup: error.localizedDescription) }
            throw original
        }
    }
}

struct ObjectCopyGrant: Sendable {
    let permission: String
    let granteeKind: String
    let identifier: String
}

enum ObjectCopyPropertyError: LocalizedError {
    case unknownOwner, invalidGrant, unsupportedCustomerEncryption
    var errorDescription: String? {
        switch self {
        case .unknownOwner: "S3 did not return the ACL owner needed to preserve permissions. No copy was started."
        case .invalidGrant: "An object ACL grant cannot be preserved. No copy was started."
        case .unsupportedCustomerEncryption: "This object uses a customer-provided encryption key. Configure a supported key flow before copying it."
        }
    }
}

enum ObjectCopyProperties {
    static func aclHeaders(owner: String?, destinationOwner: String?, grants: [ObjectCopyGrant]) throws -> [String: String] {
        guard let owner, !owner.isEmpty, let destinationOwner, !destinationOwner.isEmpty else {
            throw ObjectCopyPropertyError.unknownOwner
        }
        // The canned ACL also works for buckets with ACLs disabled. Custom source grants
        // remain explicit; a destination rejecting them fails before copying any parts.
        if owner.utf8.elementsEqual(destinationOwner.utf8), !grants.isEmpty,
           grants.allSatisfy({ $0.permission == "FULL_CONTROL" && $0.granteeKind == "id" &&
               $0.identifier.utf8.elementsEqual(owner.utf8) }) {
            return ["acl": "bucket-owner-full-control"]
        }
        let names = ["FULL_CONTROL": "grantFullControl", "READ": "grantRead", "READ_ACP": "grantReadACP", "WRITE_ACP": "grantWriteACP"]
        var fields: [String: [String]] = [:]
        for grant in grants {
            guard let header = names[grant.permission], ["id", "uri", "emailAddress"].contains(grant.granteeKind),
                  !grant.identifier.isEmpty, !grant.identifier.contains(where: { $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
                throw ObjectCopyPropertyError.invalidGrant
            }
            fields[header, default: []].append(grant.granteeKind + "=\"" + grant.identifier + "\"")
        }
        guard !fields.isEmpty else { throw ObjectCopyPropertyError.invalidGrant }
        return fields.mapValues { $0.joined(separator: ", ") }
    }

    static func tagging(_ tags: [ObjectTag]) -> String {
        tags.map { S3URIEncoding.encode($0.key) + "=" + S3URIEncoding.encode($0.value) }.joined(separator: "&")
    }
}

import Foundation

struct ValidatedCopyEncryptionContext: Equatable, Sendable {
    let base64JSON: String
    init(text: String) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let data: Data
        if text.hasPrefix("{") { data = Data(text.utf8) }
        else if let decoded = Data(base64Encoded: text) { data = decoded }
        else { throw CopyEncryptionPolicyError.invalidContext }
        guard String(data: data, encoding: .utf8) != nil,
              let dictionary = try? JSONSerialization.jsonObject(with: data) as? NSDictionary,
              dictionary.allKeys.allSatisfy({ $0 is String }),
              dictionary.allValues.allSatisfy({ $0 is String }) else { throw CopyEncryptionPolicyError.invalidContext }
        // Preserve original JSON bytes; normalizing Unicode keys can change a KMS context.
        base64JSON = data.base64EncodedString()
    }
}

struct CopyEncryptionRequirement: LocalizedError, Equatable, Sendable {
    let request: ObjectTransferRequest
    let revision: TransferObjectRevision
    let algorithm: String
    let kmsKeyID: String?
    static let defaultDisclosure = "Using the default encryption context discards any original additional KMS context and can change which KMS permission policies allow reading the copied object."
    var errorDescription: String? { "Supply the original KMS encryption context or explicitly choose the default context before copying this object." }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.request == rhs.request && lhs.revision == rhs.revision &&
            lhs.algorithm.utf8.elementsEqual(rhs.algorithm.utf8) && lhs.kmsKeyID.map { Data($0.utf8) } == rhs.kmsKeyID.map { Data($0.utf8) }
    }
}

enum CopyEncryptionDecision: Equatable, Sendable {
    case automatic
    case supplied(CopyEncryptionRequirement, ValidatedCopyEncryptionContext)
    case useDefault(CopyEncryptionRequirement)
}

enum CopyEncryptionPolicyError: LocalizedError, Equatable {
    case invalidContext
    case unconfirmedCopy
    case missingKMSKey
    var errorDescription: String? {
        switch self {
        case .invalidContext: "Enter a JSON object whose keys and values are strings, or its base64-encoded UTF-8 JSON."
        case .unconfirmedCopy: "S3 did not return a copy ETag. The source was retained."
        case .missingKMSKey: "S3 did not return the original KMS key identifier. Retry the source metadata read before copying."
        }
    }
}

enum CopyEncryptionPolicy {
    static func headers(request: ObjectTransferRequest, revision: TransferObjectRevision,
                        algorithm: String?, kmsKeyID: String?, decision: CopyEncryptionDecision) throws -> [String: String] {
        guard let algorithm, algorithm == "aws:kms" || algorithm == "aws:kms:dsse" else { return [:] }
        guard let kmsKeyID, !kmsKeyID.isEmpty else { throw CopyEncryptionPolicyError.missingKMSKey }
        let required = CopyEncryptionRequirement(request: request, revision: revision, algorithm: algorithm, kmsKeyID: kmsKeyID)
        switch decision {
        case .supplied(let approved, let context) where approved == required:
            return ["ssekmsEncryptionContext": context.base64JSON]
        case .useDefault(let approved) where approved == required: return [:]
        default: throw required
        }
    }

    @discardableResult
    static func requireCopyETag(_ etag: String?) throws -> String {
        guard let etag, !etag.isEmpty else { throw CopyEncryptionPolicyError.unconfirmedCopy }
        return etag
    }
}

import AppIntents
import CryptoKit
import Foundation

/// A file returned by list/search keeps its bucket through follow-on Shortcuts actions.
struct S3FileEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "S3 File"
    static let defaultQuery = S3FileEntityQuery()

    let reference: ShortcutObjectReference
    var id: String { reference.identifier }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(reference.fileName)",
            subtitle: "\(reference.bucket)/\(reference.key)"
        )
    }

    init(object: S3Object, account: String) throws {
        // All-bucket listings must provide their own bucket. A default would misroute old data.
        reference = try ShortcutObjectReference(account: account, bucket: object.bucket ?? "", key: object.key)
    }

    init(identifier: String) throws {
        reference = try ShortcutObjectReference(identifier: identifier)
    }

    /// Never expose credentials in an entity identifier. Region/access-key changes invalidate it.
    static func accountScope(for config: S3Config) -> String {
        let fields = [config.region, config.accessKey]
        let data = (try? JSONEncoder().encode(fields)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct S3FileEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [S3FileEntity] {
        // Restoration is local and lossless. The action validates account scope before a request.
        try identifiers.map { try S3FileEntity(identifier: $0) }
    }

    func suggestedEntities() async throws -> [S3FileEntity] { [] }
}

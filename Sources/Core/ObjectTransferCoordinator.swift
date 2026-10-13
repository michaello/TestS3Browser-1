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

/// A captured account and exact bucket/key pair. S3 keys are never path-normalized.
struct TransferObjectLocation: Hashable, Sendable {
    let accountScope: String
    let bucket: String
    let key: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.accountScope.utf8.elementsEqual(rhs.accountScope.utf8) &&
        lhs.bucket.utf8.elementsEqual(rhs.bucket.utf8) && lhs.key.utf8.elementsEqual(rhs.key.utf8)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(Array(accountScope.utf8))
        hasher.combine(Array(bucket.utf8))
        hasher.combine(Array(key.utf8))
    }
}

struct ObjectTransferRequest: Equatable, Sendable {
    enum Kind: Sendable { case copy, move, rename }

    let kind: Kind
    let source: TransferObjectLocation
    let destination: TransferObjectLocation
    var generation: UUID? = nil

    /// Use a new exact destination and run the full conflict check again.
    func keepingBoth(suffix: String = UUID().uuidString) -> Self {
        let key = destination.key
        let split = key.lastIndex(of: "/").map { key.index(after: $0) } ?? key.startIndex
        let prefix = String(key[..<split])
        let name = String(key[split...])
        let dot = name.lastIndex(of: ".")
        let stem = dot.map { String(name[..<$0]) } ?? name
        let ext = dot.map { String(name[$0...]) } ?? ""
        let destination = TransferObjectLocation(
            accountScope: destination.accountScope,
            bucket: destination.bucket,
            key: prefix + stem + " copy " + suffix + ext
        )
        return Self(kind: kind, source: source, destination: destination, generation: generation)
    }
}

struct TransferObjectRevision: Equatable, Sendable {
    let etag: String?
    let versionID: String?
    let lastModified: Date?
    let size: Int?

    static func == (lhs: Self, rhs: Self) -> Bool {
        func exact(_ a: String?, _ b: String?) -> Bool {
            switch (a, b) {
            case (nil, nil): return true
            case (let a?, let b?): return a.utf8.elementsEqual(b.utf8)
            default: return false
            }
        }
        return exact(lhs.etag, rhs.etag) && exact(lhs.versionID, rhs.versionID) &&
            lhs.lastModified == rhs.lastModified && lhs.size == rhs.size
    }
}

enum TransferObjectPresence: Equatable, Sendable {
    case absent
    case present(TransferObjectRevision)
}

/// Approval is tied to the full operation, account and observed destination revision.
struct ObjectReplacementApproval: Equatable, Sendable {
    let request: ObjectTransferRequest
    let destinationRevision: TransferObjectRevision
}

struct ObjectTransferConflict: Equatable, Sendable {
    let request: ObjectTransferRequest
    let destinationRevision: TransferObjectRevision

    var approval: ObjectReplacementApproval {
        ObjectReplacementApproval(request: request, destinationRevision: destinationRevision)
    }
}

enum ObjectTransferError: LocalizedError, Equatable {
    case sameObject
    case invalidDestination
    case contextChanged
    case sourceMissing
    case sourceChangedAfterCopy
    case sourceCannotBeConditionallyDeleted
    case destinationBusy
    case confirmationRequired(ObjectTransferConflict)
    case sourceRetainedAfterCopy(String)

    var errorDescription: String? {
        switch self {
        case .sameObject: return "Source and destination are the same object."
        case .invalidDestination: return "The destination key must contain 1 to 1,024 UTF-8 bytes."
        case .contextChanged: return "The account changed. Start the operation again."
        case .sourceMissing: return "The source object no longer exists."
        case .sourceChangedAfterCopy: return "The source changed after copying."
        case .sourceCannotBeConditionallyDeleted: return "S3 did not return the source ETag needed for safe deletion."
        case .destinationBusy: return "Another operation is using this destination. Try again after it finishes."
        case .confirmationRequired: return "A file already exists at the destination. Confirm replacement first."
        case .sourceRetainedAfterCopy(let reason):
            return "The destination copy completed, but the source was retained: \(reason)"
        }
    }
}

/// Only the transport may classify typed not-found responses as absence. Other errors throw.
@MainActor
protocol ObjectTransferTransport {
    func validateContext() throws
    func head(_ location: TransferObjectLocation) async throws -> TransferObjectPresence
    func copy(_ request: ObjectTransferRequest, sourceRevision: TransferObjectRevision) async throws
    func delete(_ source: TransferObjectLocation, revision: TransferObjectRevision) async throws
}

/// Coordinates copy and source removal without storing a continuation across a user prompt.
/// CopyObject has no atomic destination condition in the pinned SDK. Preflight and revision
/// checks reduce conflicts but cannot reserve a destination against other S3 writers.
@MainActor
struct ObjectTransferCoordinator {
    let transport: any ObjectTransferTransport
    private static var activeDestinations: Set<TransferObjectLocation> = []

    func execute(_ request: ObjectTransferRequest, approval: ObjectReplacementApproval? = nil) async throws {
        guard request.source != request.destination else { throw ObjectTransferError.sameObject }
        guard !request.destination.key.isEmpty, request.destination.key.utf8.count <= 1_024 else {
            throw ObjectTransferError.invalidDestination
        }
        // MainActor reentrancy must not allow two app operations to both observe absence.
        guard Self.activeDestinations.insert(request.destination).inserted else {
            throw ObjectTransferError.destinationBusy
        }
        defer { Self.activeDestinations.remove(request.destination) }
        try transport.validateContext()
        try Task.checkCancellation()
        guard case .present(let sourceRevision) = try await transport.head(request.source) else {
            throw ObjectTransferError.sourceMissing
        }
        try transport.validateContext()
        try Task.checkCancellation()
        let destination = try await transport.head(request.destination)
        if case .present(let revision) = destination {
            let required = ObjectReplacementApproval(request: request, destinationRevision: revision)
            guard approval == required else {
                throw ObjectTransferError.confirmationRequired(
                    ObjectTransferConflict(request: request, destinationRevision: revision)
                )
            }
        }
        try transport.validateContext()
        try Task.checkCancellation()
        try await transport.copy(request, sourceRevision: sourceRevision)

        guard request.kind != .copy else { return }
        do {
            try Task.checkCancellation()
            try transport.validateContext()
            guard try await transport.head(request.source) == .present(sourceRevision) else {
                throw ObjectTransferError.sourceChangedAfterCopy
            }
            try transport.validateContext()
            try Task.checkCancellation()
            guard let etag = sourceRevision.etag, !etag.isEmpty else {
                throw ObjectTransferError.sourceCannotBeConditionallyDeleted
            }
            try await transport.delete(request.source, revision: sourceRevision)
        } catch {
            // A completed destination is not rolled back. Preserve the source on uncertainty.
            throw ObjectTransferError.sourceRetainedAfterCopy(error.localizedDescription)
        }
    }
}

/// S3 copy-source is an HTTP header, not a filesystem path. Preserve slashes and encode
/// reserved bytes including %, +, # and ?. Version IDs are encoded as query values.
enum S3CopySource {
    static func encoded(bucket: String, key: String, versionID: String? = nil) -> String {
        var result = S3URIEncoding.encode(bucket + "/" + key, preserveSlashes: true)
        if let versionID {
            result += "?versionId=" + S3URIEncoding.encode(versionID)
        }
        return result
    }
}

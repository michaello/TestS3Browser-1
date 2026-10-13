import Foundation

/// The persisted Shortcuts identity is an opaque, lossless value rather than a display path.
/// Account scope prevents an old shortcut from silently operating under new credentials.
struct ShortcutObjectReference: Codable, Hashable, Sendable {
    let account: String
    let bucket: String
    let key: String

    init(account: String, bucket: String, key: String) throws {
        guard !account.isEmpty else { throw ShortcutObjectError.missingAccount }
        guard !bucket.isEmpty else { throw ShortcutObjectError.missingBucket }
        guard !key.isEmpty else { throw ShortcutObjectError.missingKey }
        self.account = account
        self.bucket = bucket
        self.key = key
    }

    /// Base64 fields preserve every UTF-8 byte without URL/path normalization.
    var identifier: String {
        "s3-object-v1:" + [account, bucket, key]
            .map { Data($0.utf8).base64EncodedString() }
            .joined(separator: ".")
    }

    init(identifier: String) throws {
        let prefix = "s3-object-v1:"
        guard identifier.hasPrefix(prefix) else { throw ShortcutObjectError.invalidIdentifier }
        let fields = identifier.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        let decoded = fields.compactMap { field -> String? in
            guard let data = Data(base64Encoded: String(field)) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        guard decoded.count == 3, fields.count == 3 else {
            throw ShortcutObjectError.invalidIdentifier
        }
        try self.init(account: decoded[0], bucket: decoded[1], key: decoded[2])
    }

    var fileName: String {
        key.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? key
    }

    // Swift String equality folds canonically equivalent Unicode, while S3 keys are byte-exact.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.account.utf8.elementsEqual(rhs.account.utf8)
            && lhs.bucket.utf8.elementsEqual(rhs.bucket.utf8)
            && lhs.key.utf8.elementsEqual(rhs.key.utf8)
    }

    func hash(into hasher: inout Hasher) {
        for field in [account, bucket, key] {
            hasher.combine(field.utf8.count)
            for byte in field.utf8 { hasher.combine(byte) }
        }
    }
}

enum ShortcutObjectError: LocalizedError, Equatable {
    case missingAccount
    case missingBucket
    case missingKey
    case invalidIdentifier
    case accountChanged
    case conflictingInput

    var errorDescription: String? {
        switch self {
        case .missingAccount: "Configure an S3 account before running this shortcut."
        case .missingBucket: "Specify a bucket or configure a default bucket in Settings."
        case .missingKey: "Choose an S3 file or provide its object key."
        case .invalidIdentifier: "This S3 file reference is invalid. Select the file again."
        case .accountChanged: "This S3 file belongs to a different account. Select it again with the configured account."
        case .conflictingInput: "The supplied key or bucket conflicts with the selected S3 file."
        }
    }
}

/// Resolves both entity input and legacy Key/Bucket parameters through one exact routing rule.
enum ShortcutObjectRequest {
    static func resolve(
        file: ShortcutObjectReference?, key: String?, bucket: String?,
        defaultBucket: String, account: String
    ) throws -> ShortcutObjectReference {
        if let file {
            guard file.account == account else { throw ShortcutObjectError.accountChanged }
            if let key, !key.isEmpty, !key.utf8.elementsEqual(file.key.utf8) { throw ShortcutObjectError.conflictingInput }
            if let bucket, !bucket.isEmpty, !bucket.utf8.elementsEqual(file.bucket.utf8) { throw ShortcutObjectError.conflictingInput }
            return file
        }
        let targetBucket = bucket.flatMap { $0.isEmpty ? nil : $0 } ?? defaultBucket
        return try ShortcutObjectReference(account: account, bucket: targetBucket, key: key ?? "")
    }

    @MainActor
    static func download(
        _ object: ShortcutObjectReference,
        operation: (String, String) async throws -> Data
    ) async throws -> Data {
        try Task.checkCancellation()
        return try await operation(object.key, object.bucket)
    }

    /// A fresh intent service has no client. Initialization must succeed before deletion starts.
    /// MainActor keeps the app's service ownership consistent and closures capture that service.
    @MainActor
    static func delete(
        _ object: ShortcutObjectReference,
        initialize: () async throws -> Void,
        operation: (String, String) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        try await initialize()
        try Task.checkCancellation()
        try await operation(object.key, object.bucket)
    }
}

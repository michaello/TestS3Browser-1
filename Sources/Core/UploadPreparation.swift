import CryptoKit
import Foundation

enum S3AccountScope {
    static func identifier(region: String, accessKey: String) -> String {
        let fields = [region, accessKey].map { Data($0.utf8).base64EncodedString() }.joined(separator: ".")
        return SHA256.hash(data: Data(fields.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct UploadDestination: Sendable {
    let account: String
    let bucket: String
    let prefix: String

    func key(for filename: String) -> String { prefix + filename }
}

struct PreparedUploadPayload: Sendable {
    enum Body: Sendable { case data(Data), file(URL) }
    let body: Body
    let filename: String
    let contentType: String
    let ownsInputFile: Bool

    init(data: Data, filename: String, contentType: String) {
        body = .data(data)
        self.filename = filename
        self.contentType = contentType
        ownsInputFile = false
    }

    init(file: URL, filename: String, contentType: String, ownsInputFile: Bool = false) {
        body = .file(file)
        self.filename = filename
        self.contentType = contentType
        self.ownsInputFile = ownsInputFile
    }

    func cleanInputFile() {
        if ownsInputFile, case .file(let url) = body { try? FileManager.default.removeItem(at: url) }
    }
}

enum UploadPreparationError: LocalizedError {
    case accountChanged, unavailableRepresentation
    var errorDescription: String? {
        switch self {
        case .accountChanged: "The S3 configuration changed. Select the upload again."
        case .unavailableRepresentation: "The selected item could not be loaded. Try again."
        }
    }
}

/// Destination is captured by the event handler before starting asynchronous input loading.
@MainActor
enum UploadPreparation {
    static func perform(
        destination: UploadDestination,
        load: () async throws -> PreparedUploadPayload?,
        isCurrentAccount: () -> Bool,
        send: (PreparedUploadPayload, UploadDestination) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        guard isCurrentAccount() else { throw UploadPreparationError.accountChanged }
        guard let payload = try await load() else { throw UploadPreparationError.unavailableRepresentation }
        defer { payload.cleanInputFile() }
        try Task.checkCancellation()
        guard isCurrentAccount() else { throw UploadPreparationError.accountChanged }
        try await send(payload, destination)
    }
}

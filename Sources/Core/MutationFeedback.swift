import Foundation
import Observation

@MainActor @Observable
final class MutationFeedback {
    private(set) var isRunning = false
    private(set) var errorMessage: String?
    func clearError() { errorMessage = nil }
    @discardableResult
    func perform(action: () async throws -> Void, didSucceed: () -> Void = {}) async -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        errorMessage = nil
        defer { isRunning = false }
        do {
            try Task.checkCancellation()
            try await action()
            didSucceed()
            return true
        } catch is CancellationError { return false }
        catch { errorMessage = error.localizedDescription; return false }
    }
}

enum FolderNameError: LocalizedError {
    case empty, separator, nullByte, tooLong
    var errorDescription: String? {
        switch self {
        case .empty: "Enter a folder name."
        case .separator: "Use a single folder name without a slash."
        case .nullByte: "Folder names cannot contain a null character."
        case .tooLong: "The complete folder path must fit within 1,024 UTF-8 bytes. Use a shorter name."
        }
    }
}

enum FolderNameValidation {
    static func name(_ raw: String, prefix: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw FolderNameError.empty }
        guard !name.contains("/") else { throw FolderNameError.separator }
        guard !name.contains("\0") else { throw FolderNameError.nullByte }
        guard (prefix + name + "/").utf8.count <= 1_024 else { throw FolderNameError.tooLong }
        return name
    }
}

@MainActor @Observable
final class FolderCreationState {
    var name = ""
    let mutation = MutationFeedback()
    func create(prefix: String, send: (String) async throws -> Void) async -> Bool {
        await mutation.perform {
            let valid = try FolderNameValidation.name(name, prefix: prefix)
            try await send(valid)
        }
    }
}

enum ObjectACLAccessSummary {
    static func summarize(ownerID: String?, grants: [ObjectCopyGrant]) -> String {
        guard !grants.isEmpty, let ownerID, !ownerID.isEmpty else { return "Unknown (ACL)" }
        let publicURI = "http://acs.amazonaws.com/groups/global/AllUsers"
        if grants.contains(where: { $0.granteeKind == "uri" && $0.identifier == publicURI }) {
            let read = grants.contains { $0.granteeKind == "uri" && $0.identifier == publicURI &&
                ["READ", "FULL_CONTROL"].contains($0.permission) }
            return read ? "Public read (ACL)" : "Public grants (ACL)"
        }
        if grants.allSatisfy({ $0.granteeKind == "id" && $0.identifier.utf8.elementsEqual(ownerID.utf8) }) {
            return "Owner only (ACL)"
        }
        return "Custom principals (ACL)"
    }
}

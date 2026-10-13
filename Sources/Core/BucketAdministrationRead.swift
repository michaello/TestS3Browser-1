import Foundation

enum BucketAdministrationResource: String, CaseIterable, Sendable {
    case policy, replication, cors, lifecycle
    var absenceCode: String {
        switch self {
        case .policy: "NoSuchBucketPolicy"
        case .replication: "ReplicationConfigurationNotFoundError"
        case .cors: "NoSuchCORSConfiguration"
        case .lifecycle: "NoSuchLifecycleConfiguration"
        }
    }
}

enum BucketAdministrationReadError: LocalizedError, Equatable {
    case invalidResponse(BucketAdministrationResource)
    var errorDescription: String? {
        switch self {
        case .invalidResponse(let resource): "S3 returned an incomplete \(resource.rawValue) configuration. Retry the request."
        }
    }
}

/// Only an explicit service absence code for this operation authorizes an absent
/// result. Transport, permission, bucket, decoding and cancellation errors escape.
enum BucketAdministrationRead {
    @MainActor
    static func perform<Value: Sendable>(_ resource: BucketAdministrationResource, absent: Value,
        serviceCode: (any Error) -> String?, request: () async throws -> Value) async throws -> Value {
        do { return try await request() }
        catch is CancellationError { throw CancellationError() }
        catch {
            if serviceCode(error)?.utf8.elementsEqual(resource.absenceCode.utf8) == true { return absent }
            throw error
        }
    }
}

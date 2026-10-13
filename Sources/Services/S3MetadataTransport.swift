import Foundation
import AWSS3

@MainActor
struct S3MetadataTransport: MetadataCatalogTransport {
    let client: S3Client
    let validate: @MainActor () throws -> Void

    func page(bucket: String, prefix: String?, delimiter: String?, token: String?) async throws -> MetadataListingPage {
        try validate()
        try Task.checkCancellation()
        let output = try await client.listObjectsV2(input: ListObjectsV2Input(bucket: bucket,
            continuationToken: token, delimiter: delimiter, prefix: prefix))
        try validate()
        try Task.checkCancellation()
        let files = (output.contents ?? []).compactMap { object -> MetadataRecord? in
            guard let key = object.key, !key.hasSuffix("/") else { return nil }
            return MetadataRecord(bucket: bucket, key: key, size: Int64(object.size ?? 0),
                                  modified: object.lastModified ?? .distantPast, etag: object.eTag)
        }
        return MetadataListingPage(files: files, folders: (output.commonPrefixes ?? []).compactMap(\.prefix),
                                   nextToken: output.nextContinuationToken)
    }
}

extension MetadataRecord {
    var s3Object: S3Object {
        S3Object(key: key, size: size, lastModified: modified, etag: etag, bucket: bucket)
    }
}

extension S3Service {
    func metadataTransport(generation: UUID) async throws -> any MetadataCatalogTransport {
        let validate: @MainActor () throws -> Void = { [self] in
            guard session.isCurrent(generation) else { throw CancellationError() }
        }
        if let injectedMetadataTransport {
            return ValidatedMetadataTransport(base: injectedMetadataTransport, account: session.configuration.account, validate: validate)
        }
        try await initializeClient()
        try validate()
        guard let client else { throw S3ServiceError.clientNotInitialized }
        return ValidatedMetadataTransport(base: S3MetadataTransport(client: client, validate: validate),
                                          account: session.configuration.account, validate: validate)
    }

    func fetchPrefixMetadataPage(_ query: ListingQuery, token: String?) async throws -> MetadataListingPage {
        let generation = session.generation
        guard query.account == session.configuration.account else { throw CancellationError() }
        let transport = try await metadataTransport(generation: generation)
        return try await transport.page(bucket: query.bucket, prefix: query.prefix.isEmpty ? nil : query.prefix,
                                        delimiter: query.delimiter, token: token)
    }
}

@MainActor
private struct ValidatedMetadataTransport: MetadataCatalogTransport {
    let base: any MetadataCatalogTransport
    let account: String
    let validate: @MainActor () throws -> Void
    func page(bucket: String, prefix: String?, delimiter: String?, token: String?) async throws -> MetadataListingPage {
        try validate()
        let identity = Data([account, bucket, prefix ?? "", delimiter ?? "", token ?? ""].map {
            Data($0.utf8).base64EncodedString()
        }.joined(separator: ".").utf8)
        let request = AuditTelemetry.shared.beginRequest(identity: identity, body: false)
        var succeeded = false
        // The decoded SDK page exposes no wire byte count. Body-transfer bytes are measured separately.
        defer { AuditTelemetry.shared.finishRequest(request, bytes: 0, succeeded: succeeded) }
        let page = try await base.page(bucket: bucket, prefix: prefix, delimiter: delimiter, token: token)
        try validate()
        try Task.checkCancellation()
        succeeded = true
        return page
    }
}

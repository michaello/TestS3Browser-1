import AWSS3
import Foundation

@MainActor
private struct S3MultipartCopyTransport: MultipartCopyTransport {
    let client: S3Client
    let request: ObjectTransferRequest
    let revision: TransferObjectRevision
    let contextGuard: @MainActor () throws -> Void

    func validateContext() throws { try contextGuard() }

    func create(properties: MultipartCopyProperties) async throws -> String {
        var input = CreateMultipartUploadInput(bucket: request.destination.bucket, key: request.destination.key)
        let values = properties.headers
        input.metadata = properties.metadata
        input.contentType = values["contentType"]
        input.contentEncoding = values["contentEncoding"]
        input.contentLanguage = values["contentLanguage"]
        input.contentDisposition = values["contentDisposition"]
        input.cacheControl = values["cacheControl"]
        input.expires = values["expires"]
        input.websiteRedirectLocation = values["websiteRedirectLocation"]
        input.storageClass = values["storageClass"].map(S3ClientTypes.StorageClass.init(rawValue:))
        input.serverSideEncryption = values["serverSideEncryption"].map(S3ClientTypes.ServerSideEncryption.init(rawValue:))
        input.ssekmsKeyId = values["ssekmsKeyId"]
        input.bucketKeyEnabled = values["bucketKeyEnabled"].map { $0 == "true" }
        input.objectLockMode = values["objectLockMode"].map(S3ClientTypes.ObjectLockMode.init(rawValue:))
        input.objectLockLegalHoldStatus = values["objectLockLegalHoldStatus"].map(S3ClientTypes.ObjectLockLegalHoldStatus.init(rawValue:))
        input.objectLockRetainUntilDate = values["objectLockRetainUntilDate"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        input.acl = values["acl"].map(S3ClientTypes.ObjectCannedACL.init(rawValue:))
        input.grantFullControl = values["grantFullControl"]
        input.grantRead = values["grantRead"]
        input.grantReadACP = values["grantReadACP"]
        input.grantWriteACP = values["grantWriteACP"]
        input.tagging = ObjectCopyProperties.tagging(properties.tags)
        let output = try await client.createMultipartUpload(input: input)
        guard let id = output.uploadId, !id.isEmpty else { throw MultipartCopyError.invalidResponse }
        return id
    }

    func copyPart(uploadID: String, part: MultipartCopyPart) async throws -> String {
        let input = UploadPartCopyInput(bucket: request.destination.bucket,
            copySource: S3CopySource.encoded(bucket: request.source.bucket, key: request.source.key, versionID: revision.versionID),
            copySourceIfMatch: revision.etag, copySourceRange: part.range, key: request.destination.key,
            partNumber: part.number, uploadId: uploadID)
        let output = try await client.uploadPartCopy(input: input)
        guard let etag = output.copyPartResult?.eTag, !etag.isEmpty else { throw MultipartCopyError.invalidResponse }
        return etag
    }

    func complete(uploadID: String, parts: [MultipartCopiedPart]) async throws {
        let completed = parts.map { S3ClientTypes.CompletedPart(eTag: $0.etag, partNumber: $0.number) }
        let output = try await client.completeMultipartUpload(input: CompleteMultipartUploadInput(
            bucket: request.destination.bucket, key: request.destination.key,
            multipartUpload: .init(parts: completed), uploadId: uploadID))
        guard let etag = output.eTag, !etag.isEmpty else { throw MultipartCopyError.invalidResponse }
    }

    func abort(uploadID: String) async throws {
        _ = try await client.abortMultipartUpload(input: AbortMultipartUploadInput(
            bucket: request.destination.bucket, key: request.destination.key, uploadId: uploadID))
    }
}

/// Every copy-based action uses the same exact source, property policy and size dispatch.
@MainActor
func performS3ObjectCopy(client: S3Client, request: ObjectTransferRequest,
                         revision: TransferObjectRevision, storageClass: S3ClientTypes.StorageClass? = nil,
                         contextGuard: @escaping @MainActor () throws -> Void) async throws {
    try Task.checkCancellation()
    try contextGuard()
    let source = try await client.headObject(input: HeadObjectInput(bucket: request.source.bucket,
        ifMatch: revision.etag, key: request.source.key, versionId: revision.versionID))
    try contextGuard()
    guard let bytes = source.contentLength, bytes >= 0 else { throw MultipartCopyError.invalidSize }
    if let etag = revision.etag, !(source.eTag?.utf8.elementsEqual(etag.utf8) ?? false) {
        throw ObjectTransferError.sourceChangedAfterCopy
    }
    let capturedRevision = TransferObjectRevision(etag: source.eTag, versionID: revision.versionID ?? source.versionId,
        lastModified: source.lastModified, size: bytes)
    guard source.sseCustomerAlgorithm == nil else { throw ObjectCopyPropertyError.unsupportedCustomerEncryption }
    let acl = try await client.getObjectAcl(input: GetObjectAclInput(bucket: request.source.bucket,
        key: request.source.key, versionId: capturedRevision.versionID))
    try contextGuard()
    let destinationACL = try await client.getBucketAcl(input: GetBucketAclInput(bucket: request.destination.bucket))
    try contextGuard()
    let grants = try (acl.grants ?? []).map { grant -> ObjectCopyGrant in
        guard let grantee = grant.grantee, let permission = grant.permission else { throw ObjectCopyPropertyError.invalidGrant }
        switch grantee.type {
        case .canonicaluser:
            return .init(permission: permission.rawValue, granteeKind: "id", identifier: grantee.id ?? "")
        case .group:
            return .init(permission: permission.rawValue, granteeKind: "uri", identifier: grantee.uri ?? "")
        case .amazoncustomerbyemail:
            return .init(permission: permission.rawValue, granteeKind: "emailAddress", identifier: grantee.emailAddress ?? "")
        default: throw ObjectCopyPropertyError.invalidGrant
        }
    }
    var headers = try ObjectCopyProperties.aclHeaders(owner: acl.owner?.id, destinationOwner: destinationACL.owner?.id, grants: grants)
    headers["contentType"] = source.contentType
    headers["contentEncoding"] = source.contentEncoding
    headers["contentLanguage"] = source.contentLanguage
    headers["contentDisposition"] = source.contentDisposition
    headers["cacheControl"] = source.cacheControl
    headers["expires"] = source.expires
    headers["websiteRedirectLocation"] = source.websiteRedirectLocation
    headers["storageClass"] = (storageClass ?? source.storageClass)?.rawValue
    headers["serverSideEncryption"] = source.serverSideEncryption?.rawValue
    headers["ssekmsKeyId"] = source.ssekmsKeyId
    headers["bucketKeyEnabled"] = source.bucketKeyEnabled.map(String.init)
    headers["objectLockMode"] = source.objectLockMode?.rawValue
    headers["objectLockLegalHoldStatus"] = source.objectLockLegalHoldStatus?.rawValue
    headers["objectLockRetainUntilDate"] = source.objectLockRetainUntilDate.map { String($0.timeIntervalSince1970) }
    if Int64(bytes) > MultipartCopyPlan.singleCopyLimit {
        let tags = try await client.getObjectTagging(input: GetObjectTaggingInput(bucket: request.source.bucket,
            key: request.source.key, versionId: capturedRevision.versionID))
        let preservedTags = try (tags.tagSet ?? []).map { tag -> ObjectTag in
            guard let key = tag.key, let value = tag.value else { throw ObjectCopyPropertyError.invalidGrant }
            return .init(key: key, value: value)
        }
        try contextGuard()
        try await MultipartObjectCopy.perform(bytes: Int64(bytes),
            properties: .init(metadata: source.metadata ?? [:], headers: headers, tags: preservedTags),
            transport: S3MultipartCopyTransport(client: client, request: request, revision: capturedRevision, contextGuard: contextGuard))
    } else {
        try Task.checkCancellation()
        try contextGuard()
        var input = CopyObjectInput(bucket: request.destination.bucket,
            copySource: S3CopySource.encoded(bucket: request.source.bucket, key: request.source.key, versionID: capturedRevision.versionID),
            copySourceIfMatch: capturedRevision.etag, key: request.destination.key, metadataDirective: .copy, taggingDirective: .copy)
        input.storageClass = storageClass ?? source.storageClass
        input.serverSideEncryption = source.serverSideEncryption
        input.ssekmsKeyId = source.ssekmsKeyId
        input.bucketKeyEnabled = source.bucketKeyEnabled
        input.objectLockMode = source.objectLockMode
        input.objectLockLegalHoldStatus = source.objectLockLegalHoldStatus
        input.objectLockRetainUntilDate = source.objectLockRetainUntilDate
        input.websiteRedirectLocation = source.websiteRedirectLocation
        input.acl = headers["acl"].map(S3ClientTypes.ObjectCannedACL.init(rawValue:))
        input.grantFullControl = headers["grantFullControl"]
        input.grantRead = headers["grantRead"]
        input.grantReadACP = headers["grantReadACP"]
        input.grantWriteACP = headers["grantWriteACP"]
        let output = try await client.copyObject(input: input)
        guard output.copyObjectResult != nil else { throw S3ServiceError.noDataReturned }
    }
}

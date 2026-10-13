import Foundation
import AWSS3
import CryptoKit
import SmithyStreams

/// Captures the SDK client and account guard for one operation. Only typed not-found is absence.
@MainActor
private struct S3ObjectTransferTransport: ObjectTransferTransport {
    let client: S3Client
    let contextGuard: @MainActor () throws -> Void

    func validateContext() throws { try contextGuard() }

    func head(_ location: TransferObjectLocation) async throws -> TransferObjectPresence {
        do {
            let output = try await client.headObject(input: HeadObjectInput(bucket: location.bucket, key: location.key))
            return .present(TransferObjectRevision(etag: output.eTag, versionID: output.versionId,
                lastModified: output.lastModified, size: output.contentLength))
        } catch is AWSS3.NotFound {
            return .absent
        } catch is AWSS3.NoSuchKey {
            return .absent
        }
    }

    func copy(_ request: ObjectTransferRequest, sourceRevision: TransferObjectRevision) async throws {
        try await performS3ObjectCopy(client: client, request: request,
            revision: sourceRevision, contextGuard: contextGuard)
    }

    func delete(_ source: TransferObjectLocation, revision: TransferObjectRevision) async throws {
        _ = try await client.deleteObject(input: DeleteObjectInput(bucket: source.bucket,
            ifMatch: revision.etag, key: source.key))
    }
}

/// Download, prefetch, and upload operations for S3Service. Split out of S3Service.swift to keep
/// each file under 500 lines.
extension S3Service {
    func mediaIdentity(for object: S3Object, versionID: String? = nil) -> MediaObjectIdentity {
        MediaObjectIdentity(account: S3AccountScope.identifier(region: config.region, accessKey: config.accessKey),
                            bucket: object.bucket ?? currentBucket, key: object.key, etag: object.etag, version: versionID)
    }

    /// A complete original is streamed into one reusable file, never decoded as a preview.
    func downloadOriginalFile(for object: S3Object, versionID: String? = nil,
                              purpose: MediaTransferPurpose = .visible,
                              onProgress: @escaping @Sendable (Int64) -> Void = { _ in }) async throws -> OriginalFileLease {
        let generation = session.generation
        var identity = mediaIdentity(for: object, versionID: versionID)
        try await initializeClient()
        guard session.isCurrent(generation), let capturedClient = client else { throw CancellationError() }
        var size: Int64? = object.size >= 0 ? object.size : nil
        // Legacy key-only callers lack a revision. Resolve it before cache lookup so external
        // overwrites cannot reuse an indefinitely stale key-only original.
        if identity.etag == nil {
            let metadata = try await capturedClient.headObject(input: HeadObjectInput(
                bucket: identity.bucket, key: identity.key, versionId: identity.version))
            guard session.isCurrent(generation) else { throw CancellationError() }
            identity = MediaObjectIdentity(account: identity.account, bucket: identity.bucket, key: identity.key,
                                           etag: metadata.eTag, version: identity.version)
            size = metadata.contentLength.map(Int64.init)
        }
        let capturedIdentity = identity
        return try await MediaOriginalStore.shared.file(for: identity, knownBytes: size, purpose: purpose,
                                                        progress: onProgress) { @MainActor in
            guard self.session.isCurrent(generation) else { throw CancellationError() }
            let output = try await capturedClient.getObject(input: GetObjectInput(
                bucket: capturedIdentity.bucket, ifMatch: capturedIdentity.etag,
                key: capturedIdentity.key, versionId: capturedIdentity.version))
            guard self.session.isCurrent(generation) else { throw CancellationError() }
            if let expected = capturedIdentity.etag, let actual = output.eTag,
               !expected.utf8.elementsEqual(actual.utf8) { throw MediaTransferError.revisionMismatch }
            guard let body = output.body else { throw MediaTransferError.missingBody }
            switch body {
            case .data(let data):
                guard let data else { throw MediaTransferError.missingBody }
                let reader = MediaDataReader(data)
                return MediaDownloadBody(expectedBytes: output.contentLength.map(Int64.init), read: { await reader.read() })
            case .stream(let stream):
                return MediaDownloadBody(expectedBytes: output.contentLength.map(Int64.init),
                    read: { try await stream.readAsync(upToCount: 65_536) }, close: { stream.close() })
            case .noStream:
                throw MediaTransferError.missingBody
            }
        }
    }

    /// Compatibility for text/small-data consumers. Media and export consumers use file leases.
    func downloadObject(key: String, bucket: String? = nil) async throws -> Data {
        let object = S3Object(key: key, size: -1, lastModified: .distantPast, etag: nil, bucket: bucket ?? currentBucket)
        let lease = try await downloadOriginalFile(for: object)
        do {
            let data = try await MediaFileIO.shared.data(at: lease.url)
            await MediaOriginalStore.shared.release(lease)
            return data
        } catch { await MediaOriginalStore.shared.release(lease); throw error }
    }

    func invalidateMedia(key: String, bucket: String? = nil, account: String? = nil) async {
        let scope = account ?? S3AccountScope.identifier(region: config.region, accessKey: config.accessKey)
        let targetBucket = bucket ?? currentBucket
        DetailMetadataCache.shared.invalidate(account: scope, bucket: targetBucket, key: key)
        await MediaOriginalStore.shared.invalidate(account: scope, bucket: targetBucket, key: key)
        await ImageCacheActor.shared.invalidate(account: scope, bucket: targetBucket, key: key)
    }

    /// Speculate only on the immediate working window; eligible transfers share visible demand.
    func prefetchObjects(_ objects: [S3Object]) {
        prefetchTask?.cancel()
        let captured = Array(objects.prefix(3))
        prefetchTask = Task { @MainActor in
            for object in captured {
                guard !Task.isCancelled else { return }
                guard object.size > 0, object.size <= MediaLimits().speculativeObjectBytes else { continue }
                do {
                    let lease = try await downloadOriginalFile(for: object, purpose: .speculative)
                    await MediaOriginalStore.shared.release(lease)
                } catch is CancellationError { return }
                catch { logger.debug("Speculative original failed: \(error.localizedDescription)") }
            }
        }
    }

    /// Uploads data to S3 bucket.
    /// - Parameters:
    ///   - data: The data to upload
    ///   - key: The S3 object key (path)
    ///   - contentType: MIME type of the content
    ///   - onProgress: Called on the MainActor with a fraction (0…1) while the upload runs.
    ///     Progress is estimated by time: it ramps to 0.9 over the expected duration, then
    ///     snaps to 1.0 when the SDK call returns. The AWS SDK does not expose a byte-level
    ///     progress hook for PutObject, so time-based estimation is the only option.
    /// - Returns: The key of the uploaded object
    @MainActor
    @discardableResult
    func uploadObject(
        data: Data,
        key: String,
        contentType: String = "application/octet-stream",
        bucket: String? = nil,
        expectedConfig: S3Config? = nil,
        expectedGeneration: UUID? = nil,
        onProgress: (@MainActor (Double) -> Void)? = nil
    ) async throws -> String {
        let targetBucket = bucket ?? currentBucket
        let capturedConfig = expectedConfig ?? config
        let capturedGeneration = expectedGeneration ?? session.generation
        guard session.generation == capturedGeneration else { throw UploadPreparationError.accountChanged }
        guard config == capturedConfig else { throw UploadPreparationError.accountChanged }
        try Task.checkCancellation()
        if client == nil {
            try await initializeClient()
        }

        guard config == capturedConfig else { throw UploadPreparationError.accountChanged }
        try Task.checkCancellation()
        guard let client = client else {
            throw S3ServiceError.clientNotInitialized
        }

        logger.info("Uploading to \(targetBucket)/\(key) (\(data.count) bytes)")

        let input = PutObjectInput(
            body: .data(data),
            bucket: targetBucket,
            contentType: contentType,
            key: key
        )

        try await sendUpload(input: input, client: client, byteCount: data.count,
            capturedConfig: capturedConfig, generation: capturedGeneration, onProgress: onProgress)

        logger.info("Upload complete: \(key)")
        return key
    }

    /// A queued payload stays on disk while the SDK streams its body.
    @discardableResult
    func uploadFileObject(file: URL, key: String, contentType: String, bucket: String,
                          expectedConfig: S3Config, expectedGeneration: UUID,
                          onProgress: (@MainActor (Double) -> Void)? = nil) async throws -> String {
        guard config == expectedConfig, session.generation == expectedGeneration else { throw UploadPreparationError.accountChanged }
        if client == nil { try await initializeClient() }
        guard config == expectedConfig else { throw UploadPreparationError.accountChanged }
        guard let client else { throw S3ServiceError.clientNotInitialized }
        let count = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let input = PutObjectInput(body: .stream(FileStream(fileHandle: handle)), bucket: bucket,
            contentLength: count, contentType: contentType, key: key)
        try await sendUpload(input: input, client: client, byteCount: count,
            capturedConfig: expectedConfig, generation: expectedGeneration, onProgress: onProgress)
        return key
    }

    private func sendUpload(input: PutObjectInput, client: S3Client, byteCount: Int,
                            capturedConfig: S3Config, generation: UUID,
                            onProgress: (@MainActor (Double) -> Void)?) async throws {
        let permit = try await BodyTransferLimiter.shared.acquireLease()
        do {
            guard config == capturedConfig, session.generation == generation else { throw UploadPreparationError.accountChanged }
            var etag: String?
            try await EstimatedUploadProgress.perform(byteCount: byteCount, progress: onProgress) {
                etag = try await client.putObject(input: input).eTag
            }
            await BodyTransferLimiter.shared.releaseLease(permit)
            if session.generation == generation, let key = input.key, let bucket = input.bucket {
                recordSuccessfulUpload(key: key, bucket: bucket, size: Int64(byteCount),
                    contentType: input.contentType ?? "application/octet-stream", generation: generation, etag: etag)
                await invalidateMedia(key: key, bucket: bucket)
            }
        } catch {
            await BodyTransferLimiter.shared.releaseLease(permit)
            throw error
        }
    }

    /// Renames an S3 object by copying it to the new key then deleting the original.
    /// S3 has no native rename, so this is a copy-then-delete. Both steps must succeed;
    /// if the delete fails the copy is left in place and the error is re-thrown.
    /// - Parameters:
    ///   - key: Existing object key
    ///   - newKey: Destination key (must be in the same bucket)
    ///   - bucket: Bucket containing the object (defaults to currentBucket)
    @MainActor
    func renameObject(key: String, to newKey: String, bucket: String? = nil,
                      approval: ObjectReplacementApproval? = nil) async throws {
        let request = makeObjectTransferRequest(kind: .rename, key: key, to: newKey,
                                                sourceBucket: bucket, destBucket: bucket)
        try await performObjectTransfer(request, approval: approval)
    }

    /// Copies an object to a new key, optionally in a different bucket.
    /// The source is not deleted. Use a .move request for a guarded copy-then-delete.
    /// - Parameters:
    ///   - key: Source object key
    ///   - destKey: Destination key
    ///   - sourceBucket: Bucket containing the source object (defaults to currentBucket)
    ///   - destBucket: Bucket for the destination (defaults to sourceBucket)
    @MainActor
    func copyObject(
        key: String,
        to destKey: String,
        sourceBucket: String? = nil,
        destBucket: String? = nil,
        approval: ObjectReplacementApproval? = nil
    ) async throws {
        let request = makeObjectTransferRequest(kind: .copy, key: key, to: destKey,
                                                sourceBucket: sourceBucket, destBucket: destBucket)
        try await performObjectTransfer(request, approval: approval)
    }

    /// Capture the operation before the first await and retain it through conflict prompts.
    @MainActor
    func makeObjectTransferRequest(kind: ObjectTransferRequest.Kind, key: String, to destKey: String,
                                   sourceBucket: String? = nil, destBucket: String? = nil) -> ObjectTransferRequest {
        let source = sourceBucket ?? currentBucket
        let account = objectTransferAccountScope
        return ObjectTransferRequest(kind: kind,
            source: TransferObjectLocation(accountScope: account, bucket: source, key: key),
            destination: TransferObjectLocation(accountScope: account, bucket: destBucket ?? source, key: destKey),
            generation: session.generation)
    }

    @MainActor
    private var objectTransferAccountScope: String {
        // Bind approvals to the account without retaining or logging a plaintext credential.
        SHA256.hash(data: Data((config.region + "\u{0}" + config.accessKey).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    @MainActor
    func performObjectTransfer(_ request: ObjectTransferRequest, approval: ObjectReplacementApproval? = nil) async throws {
        let capturedConfig = config
        let capturedGeneration = session.generation
        guard request.generation == nil || request.generation == capturedGeneration else { throw ObjectTransferError.contextChanged }
        guard request.source.accountScope == objectTransferAccountScope,
              request.destination.accountScope == objectTransferAccountScope else {
            throw ObjectTransferError.contextChanged
        }
        if client == nil { try await initializeClient() }
        guard config == capturedConfig else { throw ObjectTransferError.contextChanged }
        guard let client else { throw S3ServiceError.clientNotInitialized }
        let transport = S3ObjectTransferTransport(client: client) { [weak self] in
            guard let self, self.config == capturedConfig, self.session.generation == capturedGeneration else {
                throw ObjectTransferError.contextChanged
            }
        }
        try await ObjectTransferCoordinator(transport: transport).execute(request, approval: approval)

        recordObjectTransfer(request, generation: capturedGeneration)
        if session.generation == capturedGeneration {
            await invalidateMedia(key: request.source.key, bucket: request.source.bucket)
            await invalidateMedia(key: request.destination.key, bucket: request.destination.bucket)
        }
        logger.info("Object transfer completed: \(request.source.bucket)/\(request.source.key) -> \(request.destination.bucket)/\(request.destination.key)")
    }

    /// Creates a virtual folder by PUTting a zero-byte object at `prefix + name + "/"`.
    /// - Parameters:
    ///   - name: Folder name without slashes. The trailing slash is appended automatically.
    ///   - prefix: Parent prefix. Empty string creates at the bucket root.
    ///   - bucket: Target bucket (defaults to `currentBucket`).
    func createFolder(named name: String, prefix: String = "", bucket: String? = nil) async throws {
        if client == nil { try await initializeClient() }
        guard let client = client else { throw S3ServiceError.clientNotInitialized }
        let target = bucket ?? currentBucket
        let key = prefix.isEmpty ? "\(name)/" : "\(prefix)\(name)/"
        let input = PutObjectInput(
            body: .data(Data()),
            bucket: target,
            contentLength: 0,
            contentType: "application/x-directory",
            key: key
        )
        _ = try await client.putObject(input: input)
        logger.info("Created folder \(target)/\(key)")
    }

    /// Lists one page of folders and files directly under a prefix.
    /// Does not touch the service's observable state (items, isLoading, currentPrefix),
    /// so it is safe to call from PrefixBrowserView alongside BucketBrowserView.
    /// - Parameters:
    ///   - prefix: S3 key prefix to list under. Empty string lists the bucket root.
    ///   - bucket: Bucket to list (defaults to currentBucket).
    ///   - continuationToken: Opaque token from a prior call's `nextToken` to fetch the
    ///     next page. Pass nil to start from the beginning.
    /// - Returns: A tuple of the page's items and an optional token for the next page.
    ///   When `nextToken` is nil the listing is complete.
    func listPrefix(
        _ prefix: String,
        bucket: String? = nil,
        continuationToken: String? = nil
    ) async throws -> (items: [S3Item], nextToken: String?) {
        if client == nil { try await initializeClient() }
        guard let client = client else { throw S3ServiceError.clientNotInitialized }

        let targetBucket = bucket ?? currentBucket
        let input = ListObjectsV2Input(
            bucket: targetBucket,
            continuationToken: continuationToken,
            delimiter: "/",
            prefix: prefix.isEmpty ? nil : prefix
        )
        let output = try await client.listObjectsV2(input: input)

        var items: [S3Item] = []
        if let commonPrefixes = output.commonPrefixes {
            for cp in commonPrefixes {
                if let p = cp.prefix {
                    items.append(.folder(S3Folder(prefix: p)))
                }
            }
        }
        if let contents = output.contents {
            for item in contents {
                guard let key = item.key, !key.hasSuffix("/") else { continue }
                items.append(.file(S3Object(
                    key: key,
                    size: Int64(item.size ?? 0),
                    lastModified: item.lastModified ?? Date(),
                    etag: item.eTag,
                    bucket: targetBucket
                )))
            }
        }
        return (items, output.nextContinuationToken)
    }

    /// Fetches metadata for an S3 object via HeadObject without downloading the body.
    /// - Parameters:
    ///   - key: S3 object key
    ///   - bucket: Bucket containing the object (defaults to currentBucket)
    /// - Returns: S3ObjectMetadata with content type, size, storage class, and user-defined metadata
    func headObject(key: String, bucket: String? = nil) async throws -> S3ObjectMetadata {
        if client == nil { try await initializeClient() }
        guard let client = client else { throw S3ServiceError.clientNotInitialized }

        let input = HeadObjectInput(bucket: bucket ?? currentBucket, key: key)
        let output = try await client.headObject(input: input)

        return S3ObjectMetadata(
            contentType: output.contentType,
            contentLength: output.contentLength,
            lastModified: output.lastModified,
            etag: output.eTag,
            storageClass: output.storageClass?.rawValue,
            cacheControl: output.cacheControl,
            contentEncoding: output.contentEncoding,
            versionId: output.versionId,
            expirationDate: parseExpirationDate(output.expiration),
            userMetadata: output.metadata ?? [:],
            replicationStatus: output.replicationStatus?.rawValue
        )
    }

    /// Parses the `x-amz-expiration` header value into a human-readable date string.
    /// The header looks like: `expiry-date="Thu, 01 Jan 2026 00:00:00 GMT", rule-id="..."`.
    /// Returns nil when the header is absent or the date cannot be parsed.
    private func parseExpirationDate(_ header: String?) -> String? {
        guard let header else { return nil }
        // Extract the value inside expiry-date="..."
        guard let start = header.range(of: "expiry-date=\""),
              let end = header[start.upperBound...].range(of: "\"") else { return nil }
        let rawDate = String(header[start.upperBound..<end.lowerBound])
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = parser.date(from: rawDate) else { return rawDate }
        let display = DateFormatter()
        display.dateStyle = .medium
        display.timeStyle = .none
        return display.string(from: date)
    }

    /// Uploads an image to the dump folder with timestamp
    /// - Parameters:
    ///   - imageData: JPEG or PNG image data
    ///   - onProgress: Optional progress callback forwarded to uploadObject.
    /// - Returns: The full S3 key of the uploaded image
    func uploadToDump(
        imageData: Data, bucket: String? = nil, expectedConfig: S3Config? = nil,
        expectedGeneration: UUID? = nil, onProgress: (@MainActor (Double) -> Void)? = nil
    ) async throws -> String {
        let captured = expectedConfig ?? config
        let generation = expectedGeneration ?? session.generation
        guard config == captured, session.generation == generation else { throw UploadPreparationError.accountChanged }
        let image = try ImageUploadRepresentation.decode(imageData)
        let key = UploadKeyFactory.image(extension: image.filenameExtension)
        let context = UploadContext(configuration: captured, bucket: bucket ?? currentBucket,
            prefix: "dump/", generation: generation)
        return try await UploadQueueManager.shared.upload(data: image.data,
            filename: S3TransferKeys.fileName(of: key), key: key, contentType: image.contentType,
            context: context, using: self, onProgress: onProgress)
    }

    func uploadToDump(
        imageFile: URL, bucket: String? = nil, expectedConfig: S3Config? = nil,
        expectedGeneration: UUID? = nil, onProgress: (@MainActor (Double) -> Void)? = nil
    ) async throws -> String {
        let captured = expectedConfig ?? config
        let generation = expectedGeneration ?? session.generation
        guard config == captured, session.generation == generation else { throw UploadPreparationError.accountChanged }
        let descriptor = try UploadFileDescriptor.image(at: imageFile)
        let key = UploadKeyFactory.image(extension: descriptor.filenameExtension)
        let context = UploadContext(configuration: captured, bucket: bucket ?? currentBucket,
            prefix: "dump/", generation: generation)
        return try await UploadQueueManager.shared.upload(file: imageFile,
            filename: S3TransferKeys.fileName(of: key), key: key, contentType: descriptor.contentType,
            context: context, using: self, onProgress: onProgress)
    }

    /// Returns all non-delete-marker versions of an object, newest first.
    /// Returns an empty array when versioning is not enabled on the bucket.
    func listObjectVersions(key: String, bucket: String? = nil) async throws -> [S3VersionEntry] {
        let generation = session.generation
        let target = bucket ?? currentBucket
        if client == nil { try await initializeClient() }
        guard session.isCurrent(generation) else { throw CancellationError() }
        guard let client else { throw S3ServiceError.clientNotInitialized }
        return try await ObjectVersionHistory.load(key: key, isCurrent: { self.session.isCurrent(generation) }) { cursor in
            let output = try await client.listObjectVersions(input: ListObjectVersionsInput(bucket: target,
                keyMarker: cursor.key, prefix: key, versionIdMarker: cursor.version))
            let entries = (output.versions ?? []).compactMap { version -> ObjectVersionHistoryPage.Entry? in
                guard let returnedKey = version.key, let id = version.versionId,
                      let modified = version.lastModified, let size = version.size else { return nil }
                return .init(key: returnedKey, record: S3VersionEntry(versionId: id,
                    lastModified: modified, size: size, isLatest: version.isLatest ?? false))
            }
            return ObjectVersionHistoryPage(entries: entries, isTruncated: output.isTruncated ?? false,
                next: .init(key: output.nextKeyMarker, version: output.nextVersionIdMarker))
        }
    }

    /// Restores a specific version of an object by copying it to the same key, making it the latest.
    func restoreVersion(key: String, versionId: String, bucket: String? = nil) async throws {
        let generation = session.generation
        let account = session.configuration.account
        let target = bucket ?? currentBucket
        if client == nil { try await initializeClient() }
        guard session.isCurrent(generation) else { throw CancellationError() }
        guard let client = client else { throw S3ServiceError.clientNotInitialized }
        let location = TransferObjectLocation(accountScope: account, bucket: target, key: key)
        try await performS3ObjectCopy(client: client,
            request: .init(kind: .copy, source: location, destination: location, generation: generation),
            revision: .init(etag: nil, versionID: versionId, lastModified: nil, size: nil),
            contextGuard: { guard self.session.isCurrent(generation) else { throw CancellationError() } })
        await invalidateMedia(key: key, bucket: target, account: account)
        guard session.isCurrent(generation) else { throw CancellationError() }
        session.listings.invalidate(ListingQuery(account: account, bucket: target,
                                                prefix: S3TransferKeys.parentPrefix(of: key)))
        logger.info("Restored version \(versionId) of \(target)/\(key)")
    }

    /// Changes the storage class of an object by copying it to itself with the new class.
    /// All existing metadata is preserved via metadataDirective: .copy.
    func changeStorageClass(key: String, storageClass: S3ClientTypes.StorageClass, bucket: String? = nil) async throws {
        let generation = session.generation
        let account = session.configuration.account
        let target = bucket ?? currentBucket
        if client == nil { try await initializeClient() }
        guard session.isCurrent(generation) else { throw CancellationError() }
        guard let client = client else { throw S3ServiceError.clientNotInitialized }
        let location = TransferObjectLocation(accountScope: account, bucket: target, key: key)
        try await performS3ObjectCopy(client: client,
            request: .init(kind: .copy, source: location, destination: location, generation: generation),
            revision: .init(etag: nil, versionID: nil, lastModified: nil, size: nil), storageClass: storageClass,
            contextGuard: { guard self.session.isCurrent(generation) else { throw CancellationError() } })
        await invalidateMedia(key: key, bucket: target, account: account)
        guard session.isCurrent(generation) else { throw CancellationError() }
        logger.info("Changed storage class of \(target)/\(key) to \(storageClass.rawValue)")
    }

    /// Returns the S3 object tag set as key-value pairs. Returns an empty array when no tags exist.
    func getObjectTags(key: String, bucket: String? = nil) async throws -> [(key: String, value: String)] {
        if client == nil { try await initializeClient() }
        guard let client = client else { throw S3ServiceError.clientNotInitialized }

        let input = GetObjectTaggingInput(bucket: bucket ?? currentBucket, key: key)
        let output = try await client.getObjectTagging(input: input)
        return (output.tagSet ?? []).compactMap { tag in
            guard let k = tag.key, let v = tag.value else { return nil }
            return (key: k, value: v)
        }
    }

    /// Returns the ACL for an S3 object, summarised as a human-readable label plus a flat list of grants.
    func getObjectAcl(key: String, bucket: String? = nil) async throws -> S3ObjectACL {
        if client == nil { try await initializeClient() }
        guard let client = client else { throw S3ServiceError.clientNotInitialized }

        let target = bucket ?? currentBucket
        let input = GetObjectAclInput(bucket: target, key: key)
        let output = try await client.getObjectAcl(input: input)

        let allUsersURI = "http://acs.amazonaws.com/groups/global/AllUsers"
        let authenticatedURI = "http://acs.amazonaws.com/groups/global/AuthenticatedUsers"

        var grants: [ACLGrant] = []
        var isPublicRead = false

        for grant in output.grants ?? [] {
            let perm = permissionLabel(grant.permission)
            let granteeStr: String
            if let g = grant.grantee {
                switch g.type {
                case .group:
                    if g.uri == allUsersURI {
                        granteeStr = "Everyone (public)"
                        if grant.permission == .read || grant.permission == .fullControl {
                            isPublicRead = true
                        }
                    } else if g.uri == authenticatedURI {
                        granteeStr = "Authenticated AWS users"
                    } else {
                        granteeStr = g.uri ?? "Group"
                    }
                case .canonicaluser:
                    granteeStr = g.displayName ?? String((g.id ?? "unknown").prefix(12)) + "…"
                case .amazoncustomerbyemail:
                    granteeStr = g.emailAddress ?? "email grantee"
                default:
                    granteeStr = "unknown"
                }
            } else {
                granteeStr = "unknown"
            }
            grants.append(ACLGrant(grantee: granteeStr, permission: perm))
        }

        let ownerOnly = grants.allSatisfy { !$0.grantee.contains("public") && !$0.grantee.contains("Authenticated") }
        let summary: String
        if isPublicRead {
            summary = "Public (read)"
        } else if ownerOnly || grants.isEmpty {
            summary = "Private"
        } else {
            summary = "Custom (\(grants.count) grants)"
        }

        logger.info("ACL for \(target)/\(key): \(summary)")
        return S3ObjectACL(summary: summary, grants: grants)
    }

    private func permissionLabel(_ permission: S3ClientTypes.Permission?) -> String {
        switch permission {
        case .fullControl:  return "Full Control"
        case .read:         return "Read"
        case .readAcp:      return "Read ACP"
        case .write:        return "Write"
        case .writeAcp:     return "Write ACP"
        default:            return permission?.rawValue ?? "Unknown"
        }
    }

    /// Replaces the S3 object tag set with the provided key-value pairs.
    func setObjectTags(key: String, tags: [(key: String, value: String)], bucket: String? = nil) async throws {
        if client == nil { try await initializeClient() }
        guard let client = client else { throw S3ServiceError.clientNotInitialized }

        let target = bucket ?? currentBucket
        let tagSet = tags.map { S3ClientTypes.Tag(key: $0.key, value: $0.value) }
        let tagging = S3ClientTypes.Tagging(tagSet: tagSet)
        let input = PutObjectTaggingInput(bucket: target, key: key, tagging: tagging)
        _ = try await client.putObjectTagging(input: input)
        logger.info("Set \(tags.count) tag(s) on \(target)/\(key)")
    }
}

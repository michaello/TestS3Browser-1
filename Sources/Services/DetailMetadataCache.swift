import Foundation

enum DetailMetadataValue: Sendable {
    case metadata(S3ObjectMetadata)
    case versions([S3VersionEntry])
    case tags([ObjectTag])
    case permissions(S3ObjectACL)
    case lifecycle([LifecycleRuleDisplay])
}

/// One bounded secondary cache is shared across detail presentations. Every SDK operation
/// captures its bucket and credential generation before suspension.
@MainActor
final class DetailMetadataCache {
    static let shared = DetailMetadataCache()
    private let cache = DetailSecondaryCache<DetailMetadataValue>()
    private var activeGeneration: UUID?

    func load(_ section: DetailSection, object: S3Object, service: S3Service,
              force: Bool = false) async throws -> DetailMetadataValue? {
        let generation = service.session.generation
        if activeGeneration != generation { cache.reset(); activeGeneration = generation }
        let identity = service.mediaIdentity(for: object)
        let key = DetailResourceKey(object: identity, section: section)
        let value = try await cache.load(key, force: force) {
            guard service.session.isCurrent(generation) else { throw CancellationError() }
            let value: DetailMetadataValue
            switch section {
            case .metadata:
                value = .metadata(try await service.headObject(key: identity.key, bucket: identity.bucket))
            case .versions:
                value = .versions(try await service.listObjectVersions(key: identity.key, bucket: identity.bucket))
            case .tags:
                value = .tags(try await service.getObjectTags(key: identity.key, bucket: identity.bucket)
                    .map { ObjectTag(key: $0.key, value: $0.value) })
            case .permissions:
                value = .permissions(try await service.getObjectAcl(key: identity.key, bucket: identity.bucket))
            case .lifecycle:
                value = .lifecycle(try await service.fetchLifecycleRules(bucket: identity.bucket))
            }
            guard service.session.isCurrent(generation) else { throw CancellationError() }
            return value
        }
        guard service.session.isCurrent(generation) else { throw CancellationError() }
        return value
    }

    func seed(_ value: DetailMetadataValue, section: DetailSection, object: S3Object, service: S3Service) {
        cache.seed(value, for: DetailResourceKey(object: service.mediaIdentity(for: object), section: section))
    }

    func invalidate(account: String, bucket: String, key: String) {
        cache.invalidate(account: account, bucket: bucket, key: key)
    }
    func reset() { cache.reset(); activeGeneration = nil }
}

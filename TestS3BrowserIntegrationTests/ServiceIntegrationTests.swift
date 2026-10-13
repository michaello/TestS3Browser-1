import Foundation
import Testing
import AWSS3
import UIKit
@testable import TestS3Browser

@MainActor
private final class IntegrationTransport: MetadataCatalogTransport {
    var pages: [[MetadataRecord]] = [[]]
    var calls = 0
    var denied = false
    var hold = false
    var release: CheckedContinuation<Void, Never>?

    func page(bucket: String, prefix: String?, delimiter: String?, token: String?) async throws -> MetadataListingPage {
        calls += 1
        if hold { await withCheckedContinuation { release = $0 } }
        if denied { throw ResourceLoadError.failed("Synthetic access denied") }
        let index = token.flatMap(Int.init) ?? 0
        return MetadataListingPage(files: pages[index], folders: [], nextToken: index + 1 < pages.count ? String(index + 1) : nil)
    }
}

@MainActor
struct AppServiceIntegrationTests {
    private let config = S3Config(bucketName: "fixture", region: "us-east-1", accessKey: "DUMMY", secretKey: "DUMMY", prefix: "")

    private func record(_ key: String, seconds: Double = 1) -> MetadataRecord {
        MetadataRecord(bucket: "fixture", key: key, size: 10, modified: Date(timeIntervalSince1970: seconds), etag: key)
    }

    private func store() throws -> (String, UserDefaults) {
        let suite = "s3browser-integration-" + UUID().uuidString
        return (suite, try #require(UserDefaults(suiteName: suite)))
    }

    @Test func appHostUsesSyntheticBoundaries() {
        #expect(AuditAppFixture.isEnabled)
        #expect(AuditAppFixture.config.accessKey == "AUDIT_DUMMY_KEY")
    }

    @Test func cachedRecentRowsArePresentBeforeDelayedServiceResponse() async throws {
        let (suite, defaults) = try store();defer { defaults.removePersistentDomain(forName: suite) }
        let account = S3AccountScope.identifier(region: config.region, accessKey: config.accessKey)
        try MetadataSnapshotStore(defaults: defaults).save(MetadataCatalogSnapshot(records: [record("cached.txt")], failedBuckets: [], refreshedAt: nil), account: account)
        let transport = IntegrationTransport();transport.pages = [[record("fresh.txt", seconds: 2)]];transport.hold = true
        let service = S3Service(config: config, metadataTransport: transport, bucketDiscovery: { ["fixture"] }, snapshotDefaults: defaults, publishWidget: false)
        #expect(service.recentFiles.map(\.key) == ["cached.txt"])
        let refresh = Task { try await service.fetchRecentFilesFromAllBuckets(limit: 50) }
        while transport.release == nil { await Task.yield() }
        #expect(service.recentFiles.map(\.key) == ["cached.txt"])
        transport.release?.resume();transport.hold = false
        try await refresh.value
        #expect(service.recentFiles.map(\.key) == ["fresh.txt"])
        #expect(transport.calls == 1)
        try await service.fetchRecentFilesFromAllBuckets(limit: 50)
        #expect(transport.calls == 1)
        try await service.fetchRecentFilesFromAllBuckets(limit: 50, force: true)
        #expect(transport.calls == 2)
    }

    @Test func actualServicePaginatesMoreThanOneThousandObjects() async throws {
        let transport = IntegrationTransport()
        transport.pages = [(0..<1_001).map { record("old-\($0).txt") }, [record("newest.txt", seconds: 10)]]
        let service = S3Service(config: config, metadataTransport: transport, bucketDiscovery: { ["fixture"] }, snapshotDefaults: nil, publishWidget: false)
        let result = try await service.fetchFiles(prefix: "", bucket: "fixture")
        #expect(result.count == 1_002)
        #expect(result.contains { $0.key == "newest.txt" })
        #expect(transport.calls == 2)
    }

    @Test func failedRefreshPreservesCachedAndPersistedRows() async throws {
        let (suite, defaults) = try store();defer { defaults.removePersistentDomain(forName: suite) }
        let account = S3AccountScope.identifier(region: config.region, accessKey: config.accessKey)
        let store = MetadataSnapshotStore(defaults: defaults)
        try store.save(MetadataCatalogSnapshot(records: [record("keep.txt")], failedBuckets: [], refreshedAt: nil), account: account)
        let transport = IntegrationTransport();transport.denied = true
        let service = S3Service(config: config, metadataTransport: transport, bucketDiscovery: { ["fixture"] }, snapshotDefaults: defaults, publishWidget: false)
        await #expect(throws: MetadataCatalogError.self) { try await service.fetchRecentFilesFromAllBuckets(limit: 50, force: true) }
        #expect(service.recentFiles.map(\.key) == ["keep.txt"])
        #expect(store.load(account: account)?.records.map(\.key) == ["keep.txt"])
        #expect(service.recentRefreshError != nil)
    }

    @Test func staleFolderResponseCannotAppearInNewRoute() async throws {
        let transport = IntegrationTransport();transport.pages = [[record("old/one.txt")]];transport.hold = true
        let service = S3Service(config: config, metadataTransport: transport, bucketDiscovery: { ["fixture"] }, snapshotDefaults: nil, publishWidget: false)
        service.selectRoute(bucket: "fixture", prefix: "old/")
        let pending = Task { try await service.listObjects() }
        while transport.release == nil { await Task.yield() }
        service.selectRoute(bucket: "fixture", prefix: "new/")
        transport.release?.resume();transport.hold = false
        _ = try? await pending.value
        #expect(service.currentPrefix == "new/")
        #expect(service.items.isEmpty)
    }

    @Test func realSDKLifecycleProjectionPreservesDatesAndAndFilter() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2026-12-01T00:00:00Z"))
        let filter = S3ClientTypes.LifecycleRuleFilter(and: .init(objectSizeGreaterThan: 100, objectSizeLessThan: 200, prefix: "logs/", tags: [.init(key: "tier", value: "cold")]))
        let source = S3ClientTypes.LifecycleRule(expiration: .init(date: date), filter: filter, id: "rule", status: .enabled, transitions: [.init(date: date, storageClass: .glacier)])
        let result = S3Service.lifecycleDisplayRules(GetBucketLifecycleConfigurationOutput(rules: [source], transitionDefaultMinimumObjectSize: .allStorageClasses128k))
        let rule = try #require(result.first)
        #expect(rule.expirationDate == date)
        #expect(rule.transitions.first?.date == date)
        #expect(rule.filter.prefix == "logs/")
        #expect(rule.filter.tags == [ObjectTag(key: "tier", value: "cold")])
        #expect(rule.filter.sizeGreaterThan == 100 && rule.filter.sizeLessThan == 200)
        #expect(rule.minimumObjectSizePolicy == "all_storage_classes_128K")
    }

    @Test func nativeImageDecodeAndFileExportPreserveOriginalBytes() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("s3-native-media-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2_000, height: 2_000)).image { context in
            UIColor.red.setFill();context.fill(CGRect(x: 0, y: 0, width: 2_000, height: 2_000))
        }
        let original = try #require(image.pngData())
        let file = folder.appendingPathComponent("source.png");try original.write(to: file)
        let decoded = try #require(ImageDownsampling.image(at: file, maximumPixelSize: 360, byteLimit: 2 * 1_024 * 1_024))
        #expect(max(decoded.width, decoded.height) <= 360)
        #expect(decoded.bytesPerRow * decoded.height <= 2 * 1_024 * 1_024)
        let store = MediaOriginalStore(directory: folder.appendingPathComponent("original-cache"))
        let identity = MediaObjectIdentity(account: "fixture", bucket: "fixture", key: "image.png", version: "one")
        let lease = try await store.file(for: identity, knownBytes: Int64(original.count)) {
            let reader = MediaDataReader(original)
            return MediaDownloadBody(expectedBytes: Int64(original.count), read: { await reader.read() })
        }
        #expect(try Data(contentsOf: lease.url) == original)
        await store.release(lease)
        try await store.clear()
    }

    @Test func galleryRetainsOnlyCurrentAndAdjacentImagesWithinByteBudget() async {
        let identities = (0..<10).map { MediaObjectIdentity(account: "fixture", bucket: "fixture", key: "\($0).png") }
        let gallery = GalleryWorkingSet<Int>(byteLimit: 300)
        gallery.select(identities, index: 5) { _ in GalleryImageValue(value: 1, bytes: 100) }
        for _ in 0..<1_000 { if gallery.loading.isEmpty { break };await Task.yield() }
        #expect(gallery.values.count == 3)
        #expect(gallery.retainedBytes == 300)
        gallery.select(identities, index: 8) { _ in GalleryImageValue(value: 1, bytes: 100) }
        for _ in 0..<1_000 { if gallery.loading.isEmpty { break };await Task.yield() }
        #expect(Set(gallery.values.keys).isSubset(of: Set([identities[7], identities[8], identities[9]])))
        #expect(gallery.retainedBytes <= 300)
        gallery.clear()
        #expect(gallery.retainedBytes == 0)
    }
}

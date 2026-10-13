import Foundation
import AWSS3
import AWSSDKIdentity
import SmithyIdentity
import Smithy
import os.log
import CommonCrypto
import WidgetKit
import CryptoKit

@Observable @MainActor
final class S3Service {
    // Internal (not private) so the S3Service+* extension files can reach the client,
    // config, prefetch cache, and logger. Swift file-scopes `private`, so these would be
    // invisible to extensions living in other files.
    let logger = Logger(subsystem: "com.s3browser", category: "S3Service")
    let session: ServiceSession
    let administration = BucketAdministrationCache()
    private var configurationError: String?
    private var clientInitialization: Task<S3Client, Error>?
    private var clientInitializationID: UUID?

    var isLoading: Bool { session.listings.isLoading(session.route) }
    var items: [S3Item] {
        guard let page = session.listings.value(for: session.route) else { return [] }
        return page.folders.map { .folder(S3Folder(prefix: $0)) } + page.files.map { .file($0.s3Object) }
    }
    var error: String? { configurationError ?? session.listings.error(for: session.route) }
    var availableBuckets: [String] { session.bucketChoices.value(for: session.configuration.account) ?? [] }
    private(set) var recentRevision = UUID()
    internal(set) var recentFiles: [S3Object] = [] { didSet { recentRevision = UUID() } }
    let recentRequest = RequestOwnership()
    var recentSelectionFilter: FileTypeFilter = .all
    var recentSelectionLimit = 50
    var recentRowsFromCache = false
    var isRecentLoading: Bool { recentRequest.isLoading || session.catalogs.isLoading(session.configuration.account) }
    var recentRefreshError: String? {
        if let configurationError { return configurationError }
        if let discoveryError = session.bucketChoices.error(for: session.configuration.account) {
            return "Refresh incomplete: " + discoveryError
        }
        if let message = session.catalogs.error(for: session.configuration.account) { return message }
        let failed = session.catalogs.value(for: session.configuration.account)?.failedBuckets ?? []
        return failed.isEmpty ? nil : "Refresh incomplete: " + failed.map(\.bucket).joined(separator: ", ")
    }
    var lastRecentRefreshAt: Date? { session.catalogs.value(for: session.configuration.account)?.refreshedAt }
    var isCatalogComplete: Bool {
        recentRefreshError == nil && session.catalogs.value(for: session.configuration.account)?.isComplete == true
    }
    var loadingStatus: String { isLoading ? "Fetching files..." : "Loaded \(items.count) items" }
    var recentLoadingStatus: String { isRecentLoading ? "Refreshing metadata..." : "Showing \(recentFiles.count) recent files" }

    /// Current folder prefix being browsed. Empty string for bucket root.
    var currentPrefix: String {
        get { session.route.prefix }
        set { session.selectRoute(bucket: currentBucket, prefix: newValue) }
    }

    /// Currently selected bucket name
    var currentBucket: String {
        get { session.route.bucket }
        set { session.selectRoute(bucket: newValue, prefix: currentPrefix) }
    }

    var client: S3Client?
    private(set) var config: S3Config
    let injectedMetadataTransport: (any MetadataCatalogTransport)?
    let injectedBucketDiscovery: (@MainActor () async throws -> [String])?
    let snapshotDefaults: UserDefaults?
    let publishWidget: Bool

    /// Prefetch cache for file data downloaded in the background
    var prefetchedData: [String: Data] = [:]
    var prefetchTask: Task<Void, Never>?

    init(config: S3Config, metadataTransport: (any MetadataCatalogTransport)? = nil,
         bucketDiscovery: (@MainActor () async throws -> [String])? = nil,
         snapshotDefaults: UserDefaults? = UserDefaults(suiteName: "group.com.crispytoast.TestS3Browser"),
         publishWidget: Bool = true) {
        self.config = config
        injectedMetadataTransport = metadataTransport
        injectedBucketDiscovery = bucketDiscovery
        self.snapshotDefaults = snapshotDefaults
        self.publishWidget = publishWidget
        self.session = ServiceSession(configuration: Self.sessionConfiguration(config))
        AuditTelemetry.shared.cacheHydrationStarted()
        restoreMetadataSnapshot()
    }

    /// Loads the last-saved recentFiles from the shared App Group UserDefaults so
    /// Recent Files is populated on cold launch without a network round-trip.
    func updateConfig(_ config: S3Config) async throws {
        try Task.checkCancellation()
        let changed = session.apply(Self.sessionConfiguration(config))
        self.config = config
        let generation = session.generation
        if changed {
            recentRequest.reset()
            clientInitialization?.cancel()
            clientInitialization = nil
            clientInitializationID = nil
            client = nil
            configurationError = nil
            prefetchTask?.cancel()
            prefetchTask = nil
            prefetchedData.removeAll()
            recentFiles.removeAll()
            restoreMetadataSnapshot()
            ScreensAppIndexCache.shared.reset()
            DetailMetadataCache.shared.reset()
            // Invalidate all pending media publications when account/config changes.
            await ImageCacheActor.shared.clearCache()
        }
        try Task.checkCancellation()
        guard session.isCurrent(generation) else { throw CancellationError() }
        try await initializeClient()
        guard session.isCurrent(generation) else { throw CancellationError() }
        if changed { try await fetchAvailableBuckets() }
    }

    func initializeClient() async throws {
        if injectedMetadataTransport != nil { return }
        if AuditAppFixture.isEnabled { throw S3ServiceError.fixtureOperationUnavailable }
        if client != nil { return }
        let generation = session.generation
        if let clientInitialization {
            let initialized = try await clientInitialization.value
            guard session.isCurrent(generation) else { throw CancellationError() }
            client = initialized
            configurationError = nil
            return
        }
        let captured = config
        let identifier = UUID()
        clientInitializationID = identifier
        let task = Task { @MainActor in
        let credentials = SmithyIdentity.AWSCredentialIdentity(
            accessKey: captured.accessKey,
            secret: captured.secretKey
        )

        let identityResolver = try SmithyIdentity.StaticAWSCredentialIdentityResolver(credentials)

        let s3Config = try await S3Client.S3ClientConfiguration(
            awsCredentialIdentityResolver: identityResolver,
            region: captured.region
        )
            try Task.checkCancellation()
            return S3Client(config: s3Config)
        }
        clientInitialization = task
        defer {
            if clientInitializationID == identifier {
                clientInitialization = nil
                clientInitializationID = nil
            }
        }
        do {
            let initialized = try await task.value
            guard session.isCurrent(generation) else { throw CancellationError() }
            client = initialized
            configurationError = nil
        } catch {
            if session.isCurrent(generation), !(error is CancellationError) { configurationError = error.localizedDescription }
            throw error
        }
    }

    static func sessionConfiguration(_ config: S3Config) -> ServiceConfiguration {
        let fields = [config.region, config.accessKey, config.secretKey].map { Data($0.utf8).base64EncodedString() }
        let revision = SHA256.hash(data: Data(fields.joined(separator: ".").utf8)).map { String(format: "%02x", $0) }.joined()
        return ServiceConfiguration(account: S3AccountScope.identifier(region: config.region, accessKey: config.accessKey),
            credentialRevision: revision, bucket: config.bucketName, prefix: config.prefix)
    }

    /// Discovery has its own loading/error state and never blocks a known folder.
    func fetchAvailableBuckets(force: Bool = false) async throws {
        let generation = session.generation
        let account = session.configuration.account
        if let injectedBucketDiscovery {
            _ = try await session.bucketChoices.load(account, policy: force ? .force : .automatic) { [self] in
                let buckets = try await injectedBucketDiscovery()
                guard session.isCurrent(generation) else { throw CancellationError() }
                return buckets
            }
            return
        }
        try await initializeClient()
        guard session.isCurrent(generation), let client else { throw CancellationError() }
        _ = try await session.bucketChoices.load(account, policy: force ? .force : .automatic) { [self] in
            let output = try await client.listBuckets(input: ListBucketsInput())
            guard session.isCurrent(generation) else { throw CancellationError() }
            return (output.buckets ?? []).compactMap(\.name).sorted()
        }
    }

    /// The visible list is derived from the current immutable route, so an old response
    /// cannot publish into a new folder. Explicit refresh intent survives active work.
    func listObjects(force: Bool = false) async throws {
        let query = session.route
        let generation = session.generation
        let transport = try await metadataTransport(generation: generation)
        guard session.route == query else { throw CancellationError() }
        try await session.browse.reload(query, force: force) { token in
            try await transport.page(bucket: query.bucket, prefix: query.prefix.isEmpty ? nil : query.prefix,
                delimiter: query.delimiter, token: token)
        }
        if session.isCurrent(generation), session.confirmRoute(query) {
            do { try BrowseLocationStore(defaults: snapshotDefaults ?? .standard).save(query, configuration: session.configuration) }
            catch { logger.error("Browse location save failed: \(error.localizedDescription)") }
        }
    }

    func restoredBrowseLocation(legacyBucket: String, legacyPrefix: String) -> ListingQuery {
        BrowseLocationStore(defaults: snapshotDefaults ?? .standard).resolve(session.configuration,
            legacyBucket: legacyBucket, legacyPrefix: legacyPrefix)
    }

    var hasMoreObjects: Bool { session.browse.query == session.route && session.browse.hasMore }
    var isLoadingMoreObjects: Bool { session.browse.isLoadingMore }
    var browsePaginationError: String? { session.browse.query == session.route ? session.browse.error : nil }

    func loadMoreObjects() async throws {
        let query = session.route, generation = session.generation
        let transport = try await metadataTransport(generation: generation)
        guard session.route == query, session.browse.query == query else { throw CancellationError() }
        try await session.browse.loadMore { token in
            try await transport.page(bucket: query.bucket, prefix: query.prefix.isEmpty ? nil : query.prefix,
                delimiter: query.delimiter, token: token)
        }
    }

    func selectRoute(bucket: String, prefix: String) {
        session.selectRoute(bucket: bucket, prefix: prefix)
    }

    func invalidateCurrentListing() { session.listings.invalidate(session.route) }

    /// Navigates into a folder
    /// - Parameter folderPrefix: The prefix of the folder to navigate into
    func navigateToFolder(_ folderPrefix: String) async throws {
        currentPrefix = folderPrefix
        try await listObjects()
    }

    /// Navigates up one level (to parent folder)
    func navigateUp() async throws {
        currentPrefix = S3PrefixPath.parent(currentPrefix)
        try await listObjects()
    }

    /// Returns path components for breadcrumb navigation
    func getPathComponents() -> [String] {
        S3PrefixPath.components(currentPrefix).map { $0.isEmpty ? "/" : $0 }
    }

    /// Navigates to a specific path level in the breadcrumb
    /// - Parameter index: Index in the path (0-based), or -1 for root
    func navigateToBreadcrumb(_ index: Int) async throws {
        guard let prefix = S3PrefixPath.breadcrumb(currentPrefix, index: index) else { return }
        currentPrefix = prefix
        try await listObjects()
    }

    /// Switches to a different bucket
    /// - Parameter bucketName: The name of the bucket to switch to
    func switchBucket(_ bucketName: String) async throws {
        session.selectRoute(bucket: bucketName, prefix: "")
        try await listObjects()
    }

    /// Prepares one Recent cache rebuild while retaining the last successful rows.
    @MainActor
    func clearRecentFiles() {
        // Reset freshness, retaining the last successful rows until rebuilding succeeds.
        session.catalogs.prepareRebuild(session.configuration.account)
    }

    /// Deletes an object from S3
    /// - Parameters:
    ///   - key: The S3 object key to delete
    ///   - bucket: Bucket the object lives in. Defaults to currentBucket. Recent Files
    ///     mixes objects from all buckets, so callers there must pass the object's own bucket -
    ///     deleting a key from the wrong bucket "succeeds" silently and the file stays.
    /// - Throws: S3ServiceError if the client is not initialized or AWS SDK errors
    func deleteObject(key: String, bucket: String? = nil) async throws {
        let generation = session.generation
        let account = session.configuration.account
        let targetBucket = bucket ?? currentBucket
        try await initializeClient()
        guard session.isCurrent(generation) else { throw CancellationError() }
        guard let client = client else {
            throw S3ServiceError.clientNotInitialized
        }

        do {
            let input = DeleteObjectInput(
                bucket: targetBucket,
                key: key
            )

            _ = try await client.deleteObject(input: input)
            await ConfirmedMediaMutation.apply(identity: MediaObjectIdentity(account: account, bucket: targetBucket, key: key),
                isCurrent: { session.isCurrent(generation) }, invalidate: { identity in
                    await invalidateMedia(key: identity.key, bucket: identity.bucket, account: identity.account)
                }, publish: { recordSuccessfulDelete(key: key, bucket: targetBucket, generation: generation) })
            guard session.isCurrent(generation) else { throw CancellationError() }
        } catch {
            self.logger.error("Failed to delete object '\(key)' from '\(targetBucket)': \(error.localizedDescription)")
            throw error
        }
    }

    func fetchDumpFiles(force: Bool = false) async throws -> [S3Object] {
        try await fetchFiles(prefix: "dump/", bucket: currentBucket, force: force)
    }

    func fetchFiles(prefix: String, bucket: String, force: Bool = false) async throws -> [S3Object] {
        try await fetchFileMetadata(prefix: prefix, bucket: bucket, force: force)
            .sorted { $0.modified > $1.modified }.map(\.s3Object)
    }

    func fetchFileMetadata(prefix: String, bucket: String, force: Bool = false) async throws -> [MetadataRecord] {
        let generation = session.generation
        let query = ListingQuery(account: session.configuration.account, bucket: bucket, prefix: prefix, delimiter: nil)
        let transport = try await metadataTransport(generation: generation)
        let page = try await session.listings.load(query, policy: force ? .force : .automatic) {
            try await MetadataCatalogScanner.listing(query, transport: transport)
        }
        guard session.isCurrent(generation) else { throw CancellationError() }
        return page.files
    }
}

enum S3ServiceError: LocalizedError {
    case clientNotInitialized
    case noDataReturned
    case fixtureOperationUnavailable

    var errorDescription: String? {
        switch self {
        case .clientNotInitialized:
            return "S3 client not initialized. Please configure credentials."
        case .noDataReturned:
            return "No data returned from S3"
        case .fixtureOperationUnavailable:
            return "This operation is unavailable in the local audit fixture."
        }
    }
}

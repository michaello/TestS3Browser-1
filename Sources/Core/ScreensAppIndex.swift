import Foundation
import Observation

struct ScreensDesignApp: Codable, Identifiable, Sendable {
    struct Video: Codable, Identifiable, Sendable {
        let key: String
        let label: String
        let frames: Int
        var id: String { key }
    }
    let slug: String
    let name: String
    let videos: [Video]
    let sourceURL: String?
    var id: String { slug }
    var frameCount: Int { videos.reduce(0) { $0 + $1.frames } }
    var source: URL? { URL(string: sourceURL ?? "https://screensdesign.com/apps/\(slug)/") }
}

struct ScreensAppEntry: Codable, Sendable, Identifiable {
    let manifest: MetadataRecord
    let app: ScreensDesignApp
    let cover: MetadataRecord?
    var id: String { Data(manifest.key.utf8).base64EncodedString() }
}

struct ScreensManifestFailure: Codable, Sendable {
    let key: String
    let message: String
}

struct ScreensIndexSnapshot: Codable, Sendable {
    var entries: [ScreensAppEntry]
    var failures: [ScreensManifestFailure]
    var refreshedAt: Date?
    var isComplete: Bool { failures.isEmpty }
}

enum ScreensIndexError: LocalizedError {
    case unavailable([ScreensManifestFailure])
    case oversizedManifest
    var errorDescription: String? {
        switch self {
        case .unavailable(let failures): return "Apps unavailable. \(failures.count) app manifests could not be loaded."
        case .oversizedManifest: return "The app manifest exceeds the 2 MiB limit."
        }
    }
}

@MainActor
protocol ScreensIndexTransport: Sendable {
    func folders(_ identity: MediaObjectIdentity, token: String?) async throws -> (prefixes: [String], nextToken: String?)
    func metadata(bucket: String, key: String) async throws -> MetadataRecord
    func manifest(_ metadata: MetadataRecord) async throws -> Data
}

enum ScreensIndexScanner {
    private struct Outcome: Sendable {
        let key: String
        let entry: ScreensAppEntry?
        let failure: ScreensManifestFailure?
    }

    @MainActor
    static func refresh(_ identity: MediaObjectIdentity, previous: ScreensIndexSnapshot?,
                        transport: any ScreensIndexTransport, concurrency: Int = 4,
                        now: Date = Date(),
                        progress: @MainActor (ScreensIndexSnapshot) -> Void = { _ in }) async throws -> ScreensIndexSnapshot {
        var folders: [String] = [], token: String?, visited: Set<Data> = []
        repeat {
            try Task.checkCancellation()
            let page = try await transport.folders(identity, token: token)
            folders.append(contentsOf: page.prefixes)
            token = page.nextToken
            if let token, !visited.insert(Data(token.utf8)).inserted { throw MetadataCatalogError.repeatedContinuationToken }
        } while token != nil
        let keys = Array(Set(folders.map { Data(($0 + "app.json").utf8) })).map { String(decoding: $0, as: UTF8.self) }.sorted()
        let old = Dictionary((previous?.entries ?? []).map { (Data($0.manifest.key.utf8), $0) }, uniquingKeysWith: { first, _ in first })
        let freshCoverMetadata = previous?.refreshedAt.map { now.timeIntervalSince($0) < 60 } ?? false
        var outcomes: [Outcome] = []
        await withTaskGroup(of: Outcome.self) { group in
            var iterator = keys.makeIterator()
            for _ in 0..<max(1, min(4, concurrency)) {
                if let key = iterator.next() { group.addTask { await load(key, identity: identity, old: old[Data(key.utf8)], reuseCover: freshCoverMetadata, transport: transport) } }
            }
            while let outcome = await group.next() {
                outcomes.append(outcome)
                if !Task.isCancelled {
                    progress(assemble(keys: keys, outcomes: outcomes, old: old, refreshedAt: nil))
                    if let key = iterator.next() { group.addTask { await load(key, identity: identity, old: old[Data(key.utf8)], reuseCover: freshCoverMetadata, transport: transport) } }
                }
            }
        }
        try Task.checkCancellation()
        let result = assemble(keys: keys, outcomes: outcomes, old: old, refreshedAt: now)
        if !keys.isEmpty, !outcomes.contains(where: { $0.entry != nil }) { throw ScreensIndexError.unavailable(result.failures) }
        return result
    }

    @MainActor
    private static func load(_ key: String, identity: MediaObjectIdentity, old: ScreensAppEntry?,
                             reuseCover: Bool, transport: any ScreensIndexTransport) async -> Outcome {
        do {
            try Task.checkCancellation()
            let metadata = try await transport.metadata(bucket: identity.bucket, key: key)
            if let old, let etag = metadata.etag, let previous = old.manifest.etag,
               etag.utf8.elementsEqual(previous.utf8) {
                if reuseCover { return Outcome(key: key, entry: old, failure: nil) }
                // A stable manifest does not imply its cover stayed unchanged forever.
                let cover = await coverMetadata(old.app, identity: identity, transport: transport) ?? old.cover
                try Task.checkCancellation()
                return Outcome(key: key, entry: ScreensAppEntry(manifest: metadata, app: old.app, cover: cover), failure: nil)
            }
            guard metadata.size <= 2 * 1024 * 1024 else { throw ScreensIndexError.oversizedManifest }
            let data = try await transport.manifest(metadata)
            try Task.checkCancellation()
            guard data.count <= 2 * 1024 * 1024 else { throw ScreensIndexError.oversizedManifest }
            let app = try JSONDecoder().decode(ScreensDesignApp.self, from: data)
            let cover = await coverMetadata(app, identity: identity, transport: transport)
            try Task.checkCancellation()
            return Outcome(key: key, entry: ScreensAppEntry(manifest: metadata, app: app, cover: cover), failure: nil)
        } catch {
            return Outcome(key: key, entry: nil, failure: ScreensManifestFailure(key: key, message: error.localizedDescription))
        }
    }

    @MainActor
    private static func coverMetadata(_ app: ScreensDesignApp, identity: MediaObjectIdentity,
                                      transport: any ScreensIndexTransport) async -> MetadataRecord? {
        guard let first = app.videos.first else { return nil }
        return try? await transport.metadata(bucket: identity.bucket,
            key: identity.key + app.slug + "/" + first.key + "/screen-001.webp")
    }

    private static func assemble(keys: [String], outcomes: [Outcome], old: [Data: ScreensAppEntry], refreshedAt: Date?) -> ScreensIndexSnapshot {
        let completed = Dictionary(outcomes.map { (Data($0.key.utf8), $0) }, uniquingKeysWith: { _, last in last })
        let entries = keys.compactMap { key in completed[Data(key.utf8)]?.entry ?? old[Data(key.utf8)] }
            .sorted { $0.app.name.localizedCompare($1.app.name) == .orderedAscending }
        return ScreensIndexSnapshot(entries: entries, failures: outcomes.compactMap(\.failure), refreshedAt: refreshedAt)
    }
}

actor ScreensIndexDiskStore {
    static let shared = ScreensIndexDiskStore(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("screens-index-v1", isDirectory: true))
    private struct Envelope: Codable { let version: Int; let identity: MediaObjectIdentity; let snapshot: ScreensIndexSnapshot }
    private let directory: URL
    init(directory: URL) { self.directory = directory }
    func load(_ identity: MediaObjectIdentity) -> ScreensIndexSnapshot? {
        let url = directory.appendingPathComponent(identity.digest + ".json")
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4 * 1024 * 1024,
              let data = try? Data(contentsOf: url), let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.version == 1, envelope.identity == identity else { return nil }
        return envelope.snapshot
    }
    func save(_ snapshot: ScreensIndexSnapshot, identity: MediaObjectIdentity) throws {
        let data = try JSONEncoder().encode(Envelope(version: 1, identity: identity, snapshot: snapshot))
        guard data.count <= 4 * 1024 * 1024 else { throw ScreensIndexError.oversizedManifest }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(identity.digest + ".json")
        try data.write(to: url, options: .atomic)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "json" && $0 != url }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for old in files.dropFirst(7) { try? FileManager.default.removeItem(at: old) }
    }
}

/// The shared cache survives view recreation; an isolated disk store supplies launch data.
@Observable @MainActor
final class ScreensAppIndexCache {
    static let shared = ScreensAppIndexCache()
    private let requests: ResourceLoader<MediaObjectIdentity, ScreensIndexSnapshot>
    private let store: ScreensIndexDiskStore
    private let now: @MainActor () -> Date
    private var partial: [MediaObjectIdentity: ScreensIndexSnapshot] = [:]
    private var epochs: [MediaObjectIdentity: UUID] = [:]
    private var order: [MediaObjectIdentity] = []
    init(store: ScreensIndexDiskStore = .shared, now: @escaping @MainActor () -> Date = Date.init) {
        self.store = store; self.now = now; requests = ResourceLoader(now: now)
    }
    func value(for identity: MediaObjectIdentity) -> ScreensIndexSnapshot? { partial[identity] ?? requests.value(for: identity) }
    func hasLoaded(_ identity: MediaObjectIdentity) -> Bool { value(for: identity) != nil || error(identity) != nil }
    func isLoading(_ identity: MediaObjectIdentity) -> Bool { requests.isLoading(identity) }
    func error(_ identity: MediaObjectIdentity) -> String? { requests.error(for: identity) }
    func load(_ identity: MediaObjectIdentity, force: Bool = false, transport: any ScreensIndexTransport) async {
        if requests.value(for: identity) == nil, let saved = await store.load(identity), requests.value(for: identity) == nil {
            requests.seed(saved, for: identity, refreshedAt: saved.refreshedAt)
        }
        order.removeAll { $0 == identity }; order.append(identity)
        while order.count > 8 {
            let old = order.removeFirst(); requests.remove(old); partial[old] = nil; epochs[old] = nil
        }
        do {
            _ = try await requests.load(identity, policy: force ? .force : .automatic) { [self] in
                let epoch = UUID(); epochs[identity] = epoch; partial[identity] = nil
                let snapshot = try await ScreensIndexScanner.refresh(identity, previous: requests.value(for: identity), transport: transport, now: now()) {
                    if epochs[identity] == epoch { partial[identity] = $0 }
                }
                try Task.checkCancellation()
                guard epochs[identity] == epoch else { throw CancellationError() }
                try await store.save(snapshot, identity: identity)
                guard epochs[identity] == epoch else { throw CancellationError() }
                partial[identity] = nil
                return snapshot
            }
        } catch { /* Explicit errors and partial results are retained for retry and offline display. */ }
    }
    func reset() { requests.reset(); partial.removeAll(); epochs.removeAll(); order.removeAll() }
}

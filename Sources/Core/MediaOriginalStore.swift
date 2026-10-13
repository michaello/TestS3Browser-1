import Foundation

struct OriginalFileLease: Sendable {
    let id: UUID
    let identity: MediaObjectIdentity
    let url: URL
    let bytes: Int64
}

/// File-backed single-flight transfers. Every consumer owns a lease; eviction never removes
/// a player's or exporter's active file. Completed originals are reusable across features.
actor MediaOriginalStore {
    static let shared = MediaOriginalStore(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("s3-originals-v2", isDirectory: true))
    private struct Entry: Codable {
        let identity: MediaObjectIdentity
        let filename: String
        let bytes: Int64
        var accessed: Date
        var expires: Date?
        var cached: Bool
    }
    private struct Waiter {
        let continuation: CheckedContinuation<OriginalFileLease, Error>
        let progress: @Sendable (Int64) -> Void
        let purpose: MediaTransferPurpose
    }
    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: Waiter]
        let reserved: Int64
        var bytes: Int64 = 0
    }
    private let directory: URL
    private let limits: MediaLimits
    private let limiter: BodyTransferLimiter
    private var entries: [String: Entry] = [:]
    private var flights: [MediaObjectIdentity: Flight] = [:]
    private var leases: [UUID: URL] = [:]
    private var ready = false
    private var reservedSpeculative: Int64 = 0
    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    init(directory: URL, limits: MediaLimits = MediaLimits(), limiter: BodyTransferLimiter = .shared) {
        self.directory = directory; self.limits = limits; self.limiter = limiter
    }

    private func prepare() throws {
        guard !ready else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL), let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            for (digest, entry) in decoded where digest == entry.identity.digest && !entry.filename.contains("/") && entry.filename.hasPrefix(digest + "-") {
                let path = directory.appendingPathComponent(entry.filename)
                let size = (try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
                if size == entry.bytes && entry.cached { entries[digest] = entry }
            }
        }
        ready = true
        // One startup sweep removes crashed partial/staging files. Normal saves never scan.
        let retained = Set(entries.values.map(\.filename)).union(["index.json"])
        for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            if !retained.contains(url.lastPathComponent) { try? FileManager.default.removeItem(at: url) }
        }
        trim(needed: 0)
    }

    func file(for identity: MediaObjectIdentity, knownBytes: Int64? = nil,
              purpose: MediaTransferPurpose = .visible,
              progress: @escaping @Sendable (Int64) -> Void = { _ in },
              fetch: @escaping @Sendable () async throws -> MediaDownloadBody) async throws -> OriginalFileLease {
        try prepare()
        try Task.checkCancellation()
        purgeExpired(at: Date())
        if var entry = entries[identity.digest], FileManager.default.fileExists(atPath: directory.appendingPathComponent(entry.filename).path) {
            entry.accessed = Date()
            if purpose == .visible { entry.expires = nil }
            entries[identity.digest] = entry
            progress(entry.bytes)
            return makeLease(entry)
        }
        if purpose == .speculative, flights[identity] == nil {
            if let size = knownBytes {
                for (digest, entry) in entries.sorted(by: { $0.value.accessed < $1.value.accessed }) where entry.expires != nil {
                    if speculativeCachedBytes + reservedSpeculative <= limits.speculativeBytes - size { break }
                    if !leases.values.contains(directory.appendingPathComponent(entry.filename)) { removeEntry(digest) }
                }
            }
            guard let size = knownBytes, size > 0, size <= limits.speculativeObjectBytes,
                  speculativeCachedBytes + reservedSpeculative <= limits.speculativeBytes - size else { throw MediaTransferError.speculativeIneligible }
        }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                let waiter = Waiter(continuation: continuation, progress: progress, purpose: purpose)
                if var flight = flights[identity] {
                    flight.waiters[waiterID] = waiter; flights[identity] = flight
                    progress(flight.bytes)
                    if purpose == .visible { Task { await limiter.promote(flight.id) } }
                    return
                }
                let id = UUID()
                let reserve = purpose == .speculative ? (knownBytes ?? 0) : 0
                reservedSpeculative += reserve
                let staging = directory.appendingPathComponent("partial-" + id.uuidString)
                let maxBytes = purpose == .speculative ? reserve : nil
                let task = Task { [limiter] in
                    do {
                        let bytes = try await limiter.withPermit(id: id, purpose: purpose) {
                            let body = try await fetch()
                            return try await MediaFileIO.shared.write(body, to: staging, maximumBytes: maxBytes) { value in
                                Task { await self.report(identity, flightID: id, bytes: value) }
                            }
                        }
                        self.finish(identity, flightID: id, staging: staging, result: .success(bytes))
                    } catch { self.finish(identity, flightID: id, staging: staging, result: .failure(error)) }
                }
                flights[identity] = Flight(id: id, task: task, waiters: [waiterID: waiter], reserved: reserve)
            }
        } onCancel: { Task { await self.cancelWaiter(waiterID, for: identity) } }
    }

    private func report(_ identity: MediaObjectIdentity, flightID: UUID, bytes: Int64) {
        guard var flight = flights[identity], flight.id == flightID else { return }
        // Progress callbacks can arrive through separate executor hops; never move backwards.
        guard bytes >= flight.bytes else { return }
        flight.bytes = bytes; flights[identity] = flight
        for waiter in flight.waiters.values { waiter.progress(bytes) }
    }

    private func finish(_ identity: MediaObjectIdentity, flightID: UUID, staging: URL, result: Result<Int64, Error>) {
        guard let flight = flights[identity], flight.id == flightID else {
            try? FileManager.default.removeItem(at: staging); return
        }
        flights.removeValue(forKey: identity)
        reservedSpeculative -= flight.reserved
        do {
            let bytes = try result.get()
            guard !flight.waiters.isEmpty else { try? FileManager.default.removeItem(at: staging); return }
            if bytes <= limits.diskBytes { trim(needed: bytes) }
            let canCache = bytes <= limits.diskBytes && cachedBytes <= limits.diskBytes - bytes && entries.count < 4_096
            let filename = identity.digest + "-" + flightID.uuidString + "." + identity.fileExtension
            let final = directory.appendingPathComponent(filename)
            try FileManager.default.moveItem(at: staging, to: final)
            let speculativeOnly = flight.waiters.values.allSatisfy { $0.purpose == .speculative }
            let entry = Entry(identity: identity, filename: filename, bytes: bytes, accessed: Date(),
                              expires: speculativeOnly ? Date().addingTimeInterval(limits.speculativeLifetime) : nil, cached: canCache)
            entries[identity.digest] = entry
            for waiter in flight.waiters.values {
                waiter.progress(bytes)
                waiter.continuation.resume(returning: makeLease(entry))
            }
            persist()
        } catch {
            try? FileManager.default.removeItem(at: staging)
            for waiter in flight.waiters.values { waiter.continuation.resume(throwing: error) }
        }
    }

    private func makeLease(_ entry: Entry) -> OriginalFileLease {
        let id = UUID(), url = directory.appendingPathComponent(entry.filename)
        leases[id] = url
        return OriginalFileLease(id: id, identity: entry.identity, url: url, bytes: entry.bytes)
    }

    func cachedFile(for identity: MediaObjectIdentity) throws -> OriginalFileLease? {
        try prepare()
        purgeExpired(at: Date())
        guard var entry = entries[identity.digest], FileManager.default.fileExists(atPath: directory.appendingPathComponent(entry.filename).path) else { return nil }
        entry.accessed = Date(); entry.expires = nil; entries[identity.digest] = entry
        return makeLease(entry)
    }

    func release(_ lease: OriginalFileLease) {
        guard let url = leases.removeValue(forKey: lease.id), !leases.values.contains(url) else { return }
        if let pair = entries.first(where: { directory.appendingPathComponent($0.value.filename) == url }) {
            if !pair.value.cached { removeEntry(pair.key) }
        } else { try? FileManager.default.removeItem(at: url) }
        trim(needed: 0)
    }

    private func cancelWaiter(_ id: UUID, for identity: MediaObjectIdentity) {
        guard var flight = flights[identity], let waiter = flight.waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(throwing: CancellationError())
        flights[identity] = flight
        if flight.waiters.isEmpty { flight.task.cancel() }
    }

    func invalidate(account: String, bucket: String, key: String) {
        for identity in Array(flights.keys) where identity.matches(account: account, bucket: bucket, key: key) {
            cancelFlight(identity)
        }
        for (digest, entry) in entries where entry.identity.matches(account: account, bucket: bucket, key: key) { removeEntry(digest) }
        persist()
    }
    private func cancelFlight(_ identity: MediaObjectIdentity) {
        guard let flight = flights.removeValue(forKey: identity) else { return }
        reservedSpeculative -= flight.reserved; flight.task.cancel()
        for waiter in flight.waiters.values { waiter.continuation.resume(throwing: CancellationError()) }
    }
    func clear() throws {
        try prepare()
        for identity in Array(flights.keys) { cancelFlight(identity) }
        for digest in Array(entries.keys) { removeEntry(digest) }
        persist()
    }
    func purgeExpired(at date: Date) {
        for (digest, entry) in entries where entry.expires.map({ $0 <= date }) == true {
            removeEntry(digest)
        }
        persist()
    }
    private func removeEntry(_ digest: String) {
        guard let entry = entries.removeValue(forKey: digest) else { return }
        let url = directory.appendingPathComponent(entry.filename)
        if !leases.values.contains(url) { try? FileManager.default.removeItem(at: url) }
    }
    private func trim(needed: Int64) {
        for (digest, entry) in entries.sorted(by: { $0.value.accessed < $1.value.accessed }) {
            guard cachedBytes > limits.diskBytes - needed || entries.count >= 4_096 else { break }
            if !leases.values.contains(directory.appendingPathComponent(entry.filename)) { removeEntry(digest) }
        }
    }
    private func persist() {
        guard ready, let data = try? JSONEncoder().encode(entries.filter { $0.value.cached }) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
    var cachedBytes: Int64 { entries.values.filter(\.cached).reduce(0) { $0 + $1.bytes } }
    var activeLeaseCount: Int { leases.count }
    var speculativeReservedBytes: Int64 { reservedSpeculative }
    var speculativeCachedBytes: Int64 { entries.values.filter { $0.expires != nil }.reduce(0) { $0 + $1.bytes } }
    var activeFlightCount: Int { flights.count }
}

struct ExportFileLease: Sendable { let id: UUID; let url: URL }

actor MediaExportStore {
    static let shared = MediaExportStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("s3-exports-v2"))
    private let directory: URL
    private var active: [UUID: URL] = [:]
    private var prepared = false
    init(directory: URL) { self.directory = directory }
    func stage(_ original: OriginalFileLease) throws -> ExportFileLease {
        try Task.checkCancellation()
        if !prepared {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                if UUID(uuidString: url.lastPathComponent) != nil { try? FileManager.default.removeItem(at: url) }
            }
            prepared = true
        }
        let id = UUID(), folder = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // A bounded component is required even when S3's legal key/basename is 1,024 bytes.
            let raw = original.identity.key.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? "file"
            let stem = (raw as NSString).deletingPathExtension
            var bounded = ""
            for character in stem where character != ":" && character != "/" && character != "\0" {
                if bounded.utf8.count + String(character).utf8.count > 120 { break }
                bounded.append(character)
            }
            if bounded.isEmpty || bounded == "." || bounded == ".." { bounded = "file" }
            let url = folder.appendingPathComponent(bounded + "." + original.identity.fileExtension)
            try FileManager.default.copyItem(at: original.url, to: url)
            try Task.checkCancellation()
            active[id] = folder
            return ExportFileLease(id: id, url: url)
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }
    func release(_ lease: ExportFileLease) {
        guard let folder = active.removeValue(forKey: lease.id) else { return }
        try? FileManager.default.removeItem(at: folder)
    }
    var activeLeaseCount: Int { active.count }
}

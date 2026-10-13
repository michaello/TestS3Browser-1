import CryptoKit
import Foundation
import CoreGraphics
import ImageIO

struct MediaObjectIdentity: Codable, Hashable, Sendable {
    let account: String
    let bucket: String
    let key: String
    var etag: String? = nil
    var version: String? = nil

    private var encodedFields: String {
        [account, bucket, key, etag.map { "present:" + $0 } ?? "absent", version.map { "present:" + $0 } ?? "absent"]
            .map { Data($0.utf8).base64EncodedString() }.joined(separator: ".")
    }
    var digest: String { SHA256.hash(data: Data(encodedFields.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.encodedFields == rhs.encodedFields }
    func hash(into hasher: inout Hasher) { hasher.combine(encodedFields) }
    func matches(account: String, bucket: String, key: String) -> Bool {
        self.account.utf8.elementsEqual(account.utf8) && self.bucket.utf8.elementsEqual(bucket.utf8) && self.key.utf8.elementsEqual(key.utf8)
    }
    var fileExtension: String {
        let name = key.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let ext = (name as NSString).pathExtension.lowercased()
        return !ext.isEmpty && ext.utf8.count <= 16 && ext.utf8.allSatisfy { (48...57).contains($0) || (97...122).contains($0) } ? ext : "bin"
    }
    var filename: String { digest + "." + fileExtension }
}

struct MediaLimits: Sendable {
    var decodedBytes = 64 * 1024 * 1024
    var displayImageBytes = 16 * 1024 * 1024
    var diskBytes: Int64 = 512 * 1024 * 1024
    var speculativeBytes: Int64 = 16 * 1024 * 1024
    var speculativeObjectBytes: Int64 = 2 * 1024 * 1024
    var speculativeLifetime: TimeInterval = 60
}

/// One bookkeeping table owns every decoded entry, including its variant and cost.
struct ByteCostLRU<Key: Hashable, Value> {
    let limit: Int
    private var values: [Key: (Value, Int)] = [:]
    private var order: [Key] = []
    private(set) var cost = 0
    var count: Int { values.count }
    mutating func value(for key: Key) -> Value? {
        guard let entry = values[key] else { return nil }
        order.removeAll { $0 == key }; order.append(key)
        return entry.0
    }
    mutating func insert(_ value: Value, for key: Key, cost newCost: Int) {
        remove(key)
        guard newCost >= 0, newCost <= limit else { return }
        while cost > limit - newCost, let oldest = order.first { remove(oldest) }
        values[key] = (value, newCost); order.append(key); cost += newCost
    }
    mutating func remove(_ key: Key) {
        if let entry = values.removeValue(forKey: key) { cost -= entry.1 }
        order.removeAll { $0 == key }
    }
    mutating func removeAll() { values.removeAll(); order.removeAll(); cost = 0 }
    var keys: [Key] { Array(values.keys) }
}

enum ImageDownsampling {
    static func image(at url: URL, maximumPixelSize: Int, byteLimit: Int) -> CGImage? {
        guard maximumPixelSize > 0, byteLimit >= 4,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let boundedPixels = min(maximumPixelSize, Int(Double(byteLimit / 4).squareRoot()))
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: boundedPixels
        ] as CFDictionary), image.bytesPerRow <= byteLimit / max(1, image.height) else { return nil }
        return image
    }
}

enum MediaTransferError: LocalizedError, Equatable {
    case speculativeIneligible, missingBody, sizeMismatch, revisionMismatch, invalidProgress, invalidResponse
    var errorDescription: String? {
        switch self {
        case .speculativeIneligible: "This object exceeds the speculative download policy."
        case .missingBody: "The downloaded object has no readable body."
        case .sizeMismatch: "The downloaded object size does not match its response metadata."
        case .revisionMismatch: "The object changed during this download. Refresh and try again."
        case .invalidProgress: "The download exceeded its declared byte limit."
        case .invalidResponse: "The download returned an invalid response."
        }
    }
}

enum MediaTransferPurpose: Sendable, Equatable { case visible, speculative }

/// Process-wide body permits include streaming, not only response headers.
actor BodyTransferLimiter {
    static let shared = BodyTransferLimiter(limit: 4)
    private struct Waiter { let id: UUID; var purpose: MediaTransferPurpose; let continuation: CheckedContinuation<Void, Error> }
    private let limit: Int
    private var active: Set<UUID> = []
    private var waiters: [Waiter] = []
    private(set) var peak = 0
    init(limit: Int) { self.limit = max(1, limit) }
    func acquireLease() async throws -> UUID {
        let id = UUID()
        try await acquire(id, purpose: .visible)
        return id
    }
    func releaseLease(_ id: UUID) { release(id) }
    func withPermit<T: Sendable>(id: UUID = UUID(), purpose: MediaTransferPurpose = .visible,
                                operation: @Sendable () async throws -> T) async throws -> T {
        try await acquire(id, purpose: purpose)
        do {
            try Task.checkCancellation()
            let value = try await operation()
            release(id)
            return value
        } catch { release(id); throw error }
    }
    private func acquire(_ id: UUID, purpose: MediaTransferPurpose) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                if active.count < limit { active.insert(id); peak = max(peak, active.count); continuation.resume() }
                else { waiters.append(Waiter(id: id, purpose: purpose, continuation: continuation)) }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    func promote(_ id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) { waiters[index].purpose = .visible }
    }
    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
    private func release(_ id: UUID) {
        guard active.remove(id) != nil else { return }
        guard !waiters.isEmpty else { return }
        let index = waiters.firstIndex(where: { $0.purpose == .visible }) ?? 0
        let next = waiters.remove(at: index)
        active.insert(next.id); peak = max(peak, active.count); next.continuation.resume()
    }
    var waitingCount: Int { waiters.count }
    var activeCount: Int { active.count }
}

struct MediaDownloadBody: Sendable {
    let expectedBytes: Int64?
    let read: @Sendable () async throws -> Data?
    var close: @Sendable () -> Void = {}
}

actor MediaFileIO {
    static let shared = MediaFileIO()
    func write(_ body: MediaDownloadBody, to url: URL, maximumBytes: Int64?,
               progress: @Sendable (Int64) -> Void) async throws -> Int64 {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close(); body.close() }
        return try await withTaskCancellationHandler {
            var bytes: Int64 = 0
            while let chunk = try await body.read(), !chunk.isEmpty {
                try Task.checkCancellation()
                guard Int64(chunk.count) <= Int64.max - bytes else { throw MediaTransferError.invalidProgress }
                bytes += Int64(chunk.count)
                if let maximumBytes, bytes > maximumBytes { throw MediaTransferError.invalidProgress }
                try handle.write(contentsOf: chunk)
                progress(bytes)
            }
            try Task.checkCancellation()
            if let expected = body.expectedBytes, expected != bytes { throw MediaTransferError.sizeMismatch }
            return bytes
        } onCancel: { body.close() }
    }
    func data(at url: URL) throws -> Data { try Data(contentsOf: url, options: .mappedIfSafe) }
    func dataURL(at url: URL, mimeType: String) throws -> String {
        let data = try Data(contentsOf: url)
        let actualType = MediaContentType.imageSignature(data) ?? mimeType
        return "data:" + actualType + ";base64," + data.base64EncodedString()
    }
}

enum MediaContentType {
    static func imageSignature(_ data: Data) -> String? {
        let prefix = Array(data.prefix(12))
        if prefix.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) { return "image/png" }
        if prefix.starts(with: [255, 216, 255]) { return "image/jpeg" }
        if prefix.starts(with: Array("GIF87a".utf8)) || prefix.starts(with: Array("GIF89a".utf8)) { return "image/gif" }
        if prefix.count >= 12, Array(prefix[0..<4]) == Array("RIFF".utf8), Array(prefix[8..<12]) == Array("WEBP".utf8) { return "image/webp" }
        return nil
    }
}

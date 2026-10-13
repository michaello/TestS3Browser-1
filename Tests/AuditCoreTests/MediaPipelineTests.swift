import AVFoundation
import CoreGraphics
import CoreVideo
import CryptoKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AuditCore

private actor MediaFixtureGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !open { await withCheckedContinuation { waiters.append($0) } } }
    func release() { open = true; let pending = waiters; waiters.removeAll(); pending.forEach { $0.resume() } }
}
private actor MediaFixtureCounter {
    nonisolated let started = AsyncStream<Void>.makeStream()
    private(set) var calls = 0
    private(set) var events: [String] = []
    func increment(_ event: String = "fetch") { calls += 1; events.append(event); started.continuation.yield(()) }
}
private actor MediaFixtureProgress {
    private(set) var values: [Int64] = []
    func append(_ value: Int64) { values.append(value) }
}
private func mediaTemp() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("media-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
private func identity(_ key: String, account: String = "a", bucket: String = "b", etag: String = "v1") -> MediaObjectIdentity {
    MediaObjectIdentity(account: account, bucket: bucket, key: key, etag: etag)
}
private func fixtureBody(_ data: Data, expected: Int64? = nil) -> MediaDownloadBody {
    let reader = MediaDataReader(data)
    return MediaDownloadBody(expectedBytes: expected ?? Int64(data.count), read: { await reader.read() })
}
private struct MediaFixtureReadinessTimeout: Error {
    let file: String
    let line: UInt
}
private func mediaEventually(file: StaticString = #fileID, line: UInt = #line,
                             _ predicate: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while ContinuousClock.now < deadline {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw MediaFixtureReadinessTimeout(file: String(describing: file), line: line)
}
private func imageFixture(at url: URL, width: Int = 2048, height: Int = 1024, gif: Bool = false) throws {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, (gif ? UTType.gif.identifier : UTType.png.identifier) as CFString, gif ? 2 : 1, nil))
    if gif { CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary) }
    for _ in 0..<(gif ? 2 : 1) {
        CGImageDestinationAddImage(destination, image, gif ? [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary : nil)
    }
    #expect(CGImageDestinationFinalize(destination))
}

@Suite("F10 bounded decoded preview production paths", .timeLimit(.minutes(1)))
struct F10MediaPreviewTests {
    @Test("ImageIO thumbnails do not decode or return original dimensions and respect single-image bytes")
    func actualDownsample() throws {
        let folder = try mediaTemp(); defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("large.png")
        try imageFixture(at: url)
        let preview = try #require(ImageDownsampling.image(at: url, maximumPixelSize: 360, byteLimit: 2 * 1024 * 1024))
        #expect(preview.width <= 360 && preview.height <= 360)
        #expect(preview.bytesPerRow * preview.height <= 2 * 1024 * 1024)
        let limited = try #require(ImageDownsampling.image(at: url, maximumPixelSize: 10_000, byteLimit: 4096))
        #expect(limited.bytesPerRow * limited.height <= 4096)
        #expect(limited.width < 2048)
        let invalid = folder.appendingPathComponent("invalid.jpg"); try Data("invalid".utf8).write(to: invalid)
        #expect(ImageDownsampling.image(at: invalid, maximumPixelSize: 360, byteLimit: 1024) == nil)
    }

    @Test("AVFoundation poster renderer extracts bounded frame from asset URL without original loader")
    @MainActor
    func actualVideoPoster() async throws {
        let folder = try mediaTemp(); defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("fixture.mov")
        try await makeFixtureVideo(at: url)
        let poster = try await VideoPosterRenderer.shared.image(at: url, maximumPixels: 120)
        #expect(poster.width <= 120 && poster.height <= 120)
        // The renderer's only input is the asset URL. Original-file transport is absent here;
        // HTTP-range delivery itself remains an integrated asset-loader check in E01.
    }
}

@Suite("F11 original single-flight and transfer policy", .timeLimit(.minutes(1)))
struct F11MediaTransferTests {
    @Test("Identical video poster consumers share rendering and individual cancellation keeps other consumers")
    func videoPosterSingleFlight() async throws {
        let requests = MediaPreviewRequests<Int>(), gate = MediaFixtureGate(), count = MediaFixtureCounter()
        let key = MediaPreviewRequestKey(object: identity("video.mov"), pixels: 360)
        let consumers = (0..<6).map { _ in Task {
            try await requests.value(for: key) { await count.increment(); await gate.wait(); return 7 }
        } }
        try await mediaEventually { await requests.consumerCount == 6 }
        consumers[0].cancel()
        await #expect(throws: CancellationError.self) { try await consumers[0].value }
        #expect(await requests.consumerCount == 5)
        await gate.release()
        for task in consumers.dropFirst() { #expect(try await task.value == 7) }
        #expect(await count.calls == 1)
        #expect(await requests.consumerCount == 0)
    }

    @Test("Invalidation cancels obsolete poster consumers and late callback cannot satisfy replacement")
    func videoPosterInvalidation() async throws {
        let requests = MediaPreviewRequests<Int>(), oldGate = MediaFixtureGate(), newGate = MediaFixtureGate()
        let key = MediaPreviewRequestKey(object: identity("video.mov"), pixels: 360)
        let old = Task { try await requests.value(for: key) { await oldGate.wait(); return 1 } }
        try await mediaEventually { await requests.consumerCount == 1 }
        await requests.invalidate(account: "a", bucket: "b", key: "video.mov")
        await #expect(throws: CancellationError.self) { try await old.value }
        let replacement = Task { try await requests.value(for: key) { await newGate.wait(); return 2 } }
        try await mediaEventually { await requests.consumerCount == 1 }
        await oldGate.release()
        #expect(await requests.consumerCount == 1)
        await newGate.release()
        #expect(try await replacement.value == 2)
        #expect(await requests.consumerCount == 0)
    }

    @Test("Concurrent row/gallery/export requests share one transfer and completed persistent original")
    func singleFlight() async throws {
        try await checkSingleFlight(delayedByOccupiedPermit: false)
    }

    @Test("A delayed body permit preserves single-flight and persistent-original reuse")
    func singleFlightBehindOccupiedPermit() async throws {
        try await checkSingleFlight(delayedByOccupiedPermit: true)
    }

    private func checkSingleFlight(delayedByOccupiedPermit: Bool) async throws {
        let folder = try mediaTemp(); defer { try? FileManager.default.removeItem(at: folder) }
        let limiter = BodyTransferLimiter(limit: 1)
        let heldPermit = delayedByOccupiedPermit ? try await limiter.acquireLease() : nil
        let store = MediaOriginalStore(directory: folder, limiter: limiter), gate = MediaFixtureGate(), counter = MediaFixtureCounter()
        var started = counter.started.stream.makeAsyncIterator()
        let key = identity("same.png"), bytes = Data(repeating: 4, count: 128_001)
        let requests = (0..<6).map { _ in Task {
            try await store.file(for: key) { await counter.increment(); await gate.wait(); return fixtureBody(bytes) }
        } }
        if let heldPermit {
            try await mediaEventually { await limiter.waitingCount == 1 }
            #expect(await store.activeFlightCount == 1)
            // Admission can legitimately wait longer than the old 17 ms, 20,000-yield
            // fixture deadline. No SDK response exists until a body permit is available.
            try await Task.sleep(for: .milliseconds(50))
            #expect(await counter.calls == 0)
            await limiter.releaseLease(heldPermit)
        }
        try #require(await started.next() != nil)
        await gate.release()
        var leases: [OriginalFileLease] = []
        for task in requests { leases.append(try await task.value) }
        #expect(Set(leases.map(\.url)).count == 1)
        #expect(Set(leases.map(\.id)).count == 6)
        #expect(await counter.calls == 1)
        #expect(try Data(contentsOf: leases[0].url) == bytes)
        for lease in leases { await store.release(lease) }
        let reopened = MediaOriginalStore(directory: folder, limiter: limiter)
        let cached = try await reopened.file(for: key) { await counter.increment(); return fixtureBody(Data()) }
        #expect(try Data(contentsOf: cached.url) == bytes)
        #expect(await counter.calls == 1)
        await reopened.release(cached)
    }

    @Test("Four permits bound complete bodies and cancelled waiters leave no slot leak")
    func bodyCeilingAndCancellation() async throws {
        let limiter = BodyTransferLimiter(limit: 4), gate = MediaFixtureGate(), counter = MediaFixtureCounter()
        var tasks = (0..<4).map { _ in Task {
            try await limiter.withPermit { await counter.increment(); await gate.wait(); return 1 }
        } }
        try await mediaEventually { await limiter.activeCount == 4 }
        tasks += (0..<8).map { _ in Task {
            try await limiter.withPermit { await counter.increment(); await gate.wait(); return 1 }
        } }
        try await mediaEventually {
            let active = await limiter.activeCount, waiting = await limiter.waitingCount
            return active == 4 && waiting == 8
        }
        tasks[11].cancel()
        try await mediaEventually { await limiter.waitingCount == 7 }
        try await mediaEventually { await counter.calls == 4 }
        #expect(await counter.calls == 4)
        await gate.release()
        for (index, task) in tasks.enumerated() {
            if index == 11 { await #expect(throws: CancellationError.self) { try await task.value } }
            else { #expect(try await task.value == 1) }
        }
        #expect(await limiter.peak == 4)
        #expect(await limiter.activeCount == 0)
        #expect(await limiter.waitingCount == 0)
    }

    @Test("Visible work precedes speculation and prefetch bytes/size/lifetime stay bounded")
    func speculativePolicy() async throws {
        let limiter = BodyTransferLimiter(limit: 1), gate = MediaFixtureGate(), order = MediaFixtureCounter()
        let first = Task { try await limiter.withPermit { await gate.wait(); return 0 } }
        try await mediaEventually { await limiter.activeCount == 1 }
        let speculative = Task { try await limiter.withPermit(purpose: .speculative) { await order.increment("speculative"); return 0 } }
        try await mediaEventually { await limiter.waitingCount == 1 }
        let visible = Task { try await limiter.withPermit { await order.increment("visible"); return 0 } }
        try await mediaEventually { await limiter.waitingCount == 2 }
        await gate.release(); _ = try await first.value; _ = try await visible.value; _ = try await speculative.value
        #expect(await order.events == ["visible", "speculative"])
        let folder = try mediaTemp(); defer { try? FileManager.default.removeItem(at: folder) }
        var limits = MediaLimits(); limits.speculativeBytes = 16; limits.speculativeObjectBytes = 2
        let store = MediaOriginalStore(directory: folder, limits: limits)
        for index in 0..<12 {
            let lease = try await store.file(for: identity("\(index).txt"), knownBytes: 2, purpose: .speculative) { fixtureBody(Data([1, 2])) }
            await store.release(lease)
            #expect(await store.speculativeCachedBytes <= 16)
            #expect(await store.speculativeReservedBytes == 0)
        }
        await #expect(throws: MediaTransferError.speculativeIneligible) {
            try await store.file(for: identity("large"), knownBytes: 3, purpose: .speculative) { Issue.record("Ineligible object reached transport"); return fixtureBody(Data()) }
        }
        await store.purgeExpired(at: .distantFuture)
        #expect(await store.speculativeCachedBytes == 0)
        #expect(await store.cachedBytes == 0)
    }
}

@Suite("F12 exact media identities and invalidation", .timeLimit(.minutes(1)))
struct F12MediaIdentityTests {
    @Test("Account/bucket/key/ETag/version and Unicode variants never collide on disk")
    func exactIdentity() async throws {
        let folder = try mediaTemp(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = MediaOriginalStore(directory: folder)
        var versioned = identity("same.jpg"); versioned.version = "2"
        let keys = [identity("same.jpg"), identity("same.jpg", account: "other"), identity("same.jpg", bucket: "other"),
                    identity("same.jpg", etag: "v2"), versioned, identity("a/b.jpg"), identity("a_b.jpg"), identity("é.jpg"), identity("e\u{301}.jpg")]
        #expect(Set(keys).count == keys.count)
        #expect(Set(keys.map(\.filename)).count == keys.count)
        var leases: [OriginalFileLease] = []
        for (index, key) in keys.enumerated() {
            let data = Data([UInt8(index)])
            let lease = try await store.file(for: key) { fixtureBody(data) }
            #expect(try Data(contentsOf: lease.url) == data)
            leases.append(lease)
        }
        await store.invalidate(account: "a", bucket: "b", key: "same.jpg")
        #expect(FileManager.default.fileExists(atPath: leases[0].url.path))
        let replacement = try await store.file(for: keys[0]) { fixtureBody(Data([255])) }
        #expect(replacement.url != leases[0].url)
        #expect(try Data(contentsOf: replacement.url) == Data([255]))
        for lease in leases { await store.release(lease) }
        #expect(FileManager.default.fileExists(atPath: leases[0].url.path) == false)
        await store.release(replacement)
    }

    @Test("Account reset cancels late transfers instead of publishing their files")
    func accountReset() async throws {
        let folder = try mediaTemp(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = MediaOriginalStore(directory: folder), gate = MediaFixtureGate(), counter = MediaFixtureCounter()
        var started = counter.started.stream.makeAsyncIterator()
        let task = Task { try await store.file(for: identity("old")) { await counter.increment(); await gate.wait(); return fixtureBody(Data([1])) } }
        _ = await started.next()
        try await store.clear(); await gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        try await mediaEventually { await store.activeFlightCount == 0 }
        #expect(await store.cachedBytes == 0)
    }
}

@Suite("F13 cost-aware decoded eviction")
struct F13DecodedCacheTests {
    @Test("Thumbnail churn cannot orphan bookkeeping or immediately evict newest full entry")
    func variantChurn() {
        var cache = ByteCostLRU<String, Int>(limit: 100)
        for index in 0..<10 { cache.insert(index, for: "full-\(index)", cost: 10) }
        for index in 0..<150 { cache.insert(index, for: "thumb-\(index)", cost: 1) }
        cache.insert(999, for: "full-new", cost: 40)
        #expect(cache.value(for: "full-new") == 999)
        #expect(cache.cost <= 100)
        #expect(cache.keys.count == cache.count)
        #expect(cache.keys.allSatisfy { cache.value(for: $0) != nil })
        cache.insert(1, for: "oversized", cost: 101)
        #expect(cache.value(for: "oversized") == nil)
        cache.removeAll(); #expect(cache.count == 0 && cache.cost == 0)
    }
}

@Suite("F14 gallery working window and request lifetime", .timeLimit(.minutes(1)))
@MainActor
struct F14GalleryWindowTests {
    @Test("Long swipe sessions retain only current and at most two adjacent images within bytes")
    func longSwipe() async throws {
        let window = GalleryWorkingSet<Int>(byteLimit: 30), keys = (0..<100).map { identity("\($0)") }
        for index in keys.indices {
            window.select(keys, index: index) { key in GalleryImageValue(value: try #require(Int(key.key)), bytes: 10) }
            try await mediaEventually { await window.activeRequestCount == 0 }
            #expect(window.values.count <= 3 && window.retainedBytes <= 30)
            #expect(window.values[keys[index]] == index)
        }
        window.clear(); #expect(window.activeRequestCount == 0 && window.loading.isEmpty && window.values.isEmpty)
    }

    @Test("Obsolete preload and decode failure always clear loading and cannot publish stale images")
    func obsoleteAndFailure() async throws {
        let window = GalleryWorkingSet<Int>(byteLimit: 30), keys = (0..<10).map { identity("\($0)") }, gate = MediaFixtureGate()
        window.select(keys, index: 0) { _ in await gate.wait(); try Task.checkCancellation(); return GalleryImageValue(value: 0, bytes: 10) }
        await Task.yield()
        window.select(keys, index: 9) { _ in throw MediaTransferError.missingBody }
        await gate.release()
        try await mediaEventually { await window.activeRequestCount == 0 }
        #expect(window.loading.isEmpty)
        #expect(window.values.isEmpty)
        #expect(window.errors[keys[9]] != nil)
        #expect(window.errors[keys[0]] == nil)
    }
}

@Suite("F15 file-backed original reuse and lease-safe disk budget", .timeLimit(.minutes(1)))
struct F15OriginalFileTests {
    @Test("Chunked original reuses preview/open/export bytes and active leases survive disk pressure")
    func filesAndLeaseBudget() async throws {
        let folder = try mediaTemp(); defer { try? FileManager.default.removeItem(at: folder) }
        var limits = MediaLimits(); limits.diskBytes = 128
        let store = MediaOriginalStore(directory: folder, limits: limits), counter = MediaFixtureCounter()
        let original = Data(repeating: 7, count: 128)
        let a = try await store.file(for: identity("same.mov")) { await counter.increment(); return fixtureBody(original) }
        let b = try await store.file(for: identity("same.mov")) { await counter.increment(); return fixtureBody(Data()) }
        #expect(a.url == b.url)
        let progress = MediaFixtureProgress()
        let huge = try await store.file(for: identity("other/same.mov"), progress: { bytes in Task { await progress.append(bytes) } }) {
            fixtureBody(Data(repeating: 9, count: 262_145))
        }
        try await mediaEventually { await progress.values.count > 1 }
        let recorded = await progress.values
        #expect(recorded.last == 262_145)
        #expect(recorded == recorded.sorted())
        #expect(a.url != huge.url)
        #expect(try Data(contentsOf: a.url) == original)
        #expect(await store.cachedBytes <= 128)
        #expect(huge.bytes == 262_145)
        await store.release(huge)
        #expect(FileManager.default.fileExists(atPath: huge.url.path) == false)
        #expect(FileManager.default.fileExists(atPath: a.url.path))
        #expect(await counter.calls == 1)
        await store.release(a); await store.release(b)
    }

    @Test("Truncated streams fail and remove their partial files")
    func truncatedFailure() async throws {
        let folder = try mediaTemp(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = MediaOriginalStore(directory: folder)
        await #expect(throws: MediaTransferError.sizeMismatch) {
            try await store.file(for: identity("broken.mov")) { fixtureBody(Data([1]), expected: 2) }
        }
        #expect(await store.activeLeaseCount == 0)
        #expect(await store.activeFlightCount == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).allSatisfy { !$0.hasPrefix("partial-") })
    }

    @Test("Player resource owner retains an evicted file through presentation changes")
    func playerFileOwnership() async throws {
        let folder = try mediaTemp(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = MediaOriginalStore(directory: folder), key = identity("video.mov")
        let lease = try await store.file(for: key) { fixtureBody(Data([1, 2, 3])) }
        let resources = MediaPlaybackResources(originals: store)
        try await resources.acquire(url: lease.url, identity: key)
        await store.release(lease)
        await store.invalidate(account: "a", bucket: "b", key: "video.mov")
        #expect(FileManager.default.fileExists(atPath: lease.url.path))
        await resources.release()
        #expect(FileManager.default.fileExists(atPath: lease.url.path) == false)
        #expect(await store.activeLeaseCount == 0)
    }

    @Test("Old presentation cleanup cannot release a newer stream and deinit releases final permit")
    func playerPermitOwnership() async throws {
        let limiter = BodyTransferLimiter(limit: 1)
        var resources: MediaPlaybackResources? = MediaPlaybackResources(limiter: limiter)
        let url = try #require(URL(string: "https://fixture.invalid/video.mov")), old = UUID(), current = UUID()
        try await resources?.acquire(url: url, identity: nil, requestID: old)
        try await resources?.acquire(url: url, identity: nil, requestID: current)
        await resources?.release(ifGeneration: old)
        #expect(await limiter.activeCount == 1)
        resources = nil
        try await mediaEventually { await limiter.activeCount == 0 }
        #expect(await limiter.waitingCount == 0)
    }
}

@Suite("F18 original export hashes and truthful Data URL formats", .timeLimit(.minutes(1)))
struct F18OriginalExportTests {
    @Test("PNG/JPEG/GIF/WebP Data URLs follow actual original signature and round-trip bytes", arguments: [
        ("image/png", Data([137, 80, 78, 71, 13, 10, 26, 10, 1, 2])),
        ("image/jpeg", Data([255, 216, 255, 0, 1, 2])),
        ("image/gif", Data("GIF89aoriginal".utf8)),
        ("image/webp", Data("RIFF1234WEBPoriginal".utf8))
    ])
    func truthfulDataURLs(fixture: (String, Data)) async throws {
        let folder = try mediaTemp(); defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("original")
        try fixture.1.write(to: url)
        let dataURL = try await MediaFileIO.shared.dataURL(at: url, mimeType: "application/octet-stream")
        #expect(dataURL.hasPrefix("data:" + fixture.0 + ";base64,"))
        #expect(Data(base64Encoded: String(dataURL.split(separator: ",", maxSplits: 1)[1])) == fixture.1)
    }
    @Test("Animated GIF export preserves all bytes/frames and Data URL declares original signature")
    func originalGIF() async throws {
        let folder = try mediaTemp(); defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.gif"); try imageFixture(at: source, width: 40, height: 20, gif: true)
        let original = try Data(contentsOf: source), store = MediaOriginalStore(directory: folder.appendingPathComponent("cache"))
        let lease = try await store.file(for: identity("animated.gif")) { fixtureBody(original) }
        let exports = MediaExportStore(directory: folder.appendingPathComponent("exports"))
        let staged = try await exports.stage(lease), exported = try Data(contentsOf: staged.url)
        #expect(SHA256.hash(data: exported) == SHA256.hash(data: original))
        #expect(staged.url.pathExtension == "gif")
        let imageSource = try #require(CGImageSourceCreateWithURL(staged.url as CFURL, nil))
        #expect(CGImageSourceGetCount(imageSource) == 2)
        let dataURL = try await MediaFileIO.shared.dataURL(at: lease.url, mimeType: "image/jpeg")
        #expect(dataURL.hasPrefix("data:image/gif;base64,"))
        #expect(Data(base64Encoded: String(dataURL.split(separator: ",", maxSplits: 1)[1])) == original)
        await exports.release(staged); await store.release(lease)
    }
}

@Suite("F19 bounded hashed local paths", .timeLimit(.minutes(1)))
struct F19MediaPathTests {
    @Test("190-byte,308-byte,UUID-plus-long basename and Unicode keys write and persist safely")
    func longKeys() async throws {
        let folder = try mediaTemp(); defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appendingPathComponent("cache"), store = MediaOriginalStore(directory: cache)
        let exports = MediaExportStore(directory: folder.appendingPathComponent("exports"))
        let keys = [String(repeating: "x", count: 186) + ".jpg", String(repeating: "y", count: 304) + ".jpg",
                    "UUID-" + String(repeating: "z", count: 250) + ".mov", String(repeating: "路径/", count: 100) + "照片.png"]
        for key in keys {
            let lease = try await store.file(for: identity(key)) { fixtureBody(Data([1, 2, 3])) }
            #expect(lease.url.lastPathComponent.utf8.count <= 128)
            let staged = try await exports.stage(lease)
            #expect(staged.url.lastPathComponent.utf8.count <= 137)
            #expect(try Data(contentsOf: staged.url) == Data([1, 2, 3]))
            await exports.release(staged); await store.release(lease)
        }
        let reopened = MediaOriginalStore(directory: cache)
        for key in keys {
            let lease = try #require(try await reopened.cachedFile(for: identity(key)))
            #expect(try Data(contentsOf: lease.url) == Data([1, 2, 3]))
            await reopened.release(lease)
        }
    }
}

@Suite("N44 export staging lifetime", .timeLimit(.minutes(1)))
struct N44MediaLeaseTests {
    @Test("Share completion/cancellation release is idempotent and failure leaves no staging files")
    func stagingCleanup() async throws {
        let folder = try mediaTemp(); defer { try? FileManager.default.removeItem(at: folder) }
        let originalURL = folder.appendingPathComponent("original"); try Data([1, 2]).write(to: originalURL)
        let original = OriginalFileLease(id: UUID(), identity: identity("file.png"), url: originalURL, bytes: 2)
        let output = folder.appendingPathComponent("exports"), store = MediaExportStore(directory: output)
        let completed = try await store.stage(original), cancelled = try await store.stage(original)
        #expect(await store.activeLeaseCount == 2)
        await store.release(completed); await store.release(cancelled); await store.release(cancelled)
        #expect(FileManager.default.fileExists(atPath: completed.url.path) == false)
        #expect(FileManager.default.fileExists(atPath: cancelled.url.path) == false)
        #expect(FileManager.default.fileExists(atPath: originalURL.path))
        let missing = OriginalFileLease(id: UUID(), identity: identity("missing.png"), url: folder.appendingPathComponent("missing"), bytes: 0)
        await #expect(throws: (any Error).self) { try await store.stage(missing) }
        #expect(await store.activeLeaseCount == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.stage(original)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
    }
}

@Suite("N13 restore refresh and visible terminal failures", .timeLimit(.minutes(1)))
@MainActor
struct N13VersionRestoreTests {
    @Test("Successful restore invalidates original and refreshes visible bytes/metadata/version state")
    func successfulRestore() async throws {
        let folder = try mediaTemp(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = MediaOriginalStore(directory: folder), flow = VersionRestoreFlow()
        let old = try await store.file(for: identity("file.gif", etag: "old")) { fixtureBody(Data([1])) }
        await store.release(old)
        var events: [String] = [], displayed = Data([1]), metadata = "old", versions = ["old"]
        await flow.restore("historical", isCurrent: { true }, write: {
            events.append("restore")
        }, invalidate: {
            events.append("invalidate")
            await store.invalidate(account: "a", bucket: "b", key: "file.gif")
        }, content: {
            events.append("content")
            let fresh = try await store.file(for: identity("file.gif", etag: "new")) { fixtureBody(Data([2])) }
            displayed = try Data(contentsOf: fresh.url)
            await store.release(fresh)
        }, metadata: {
            events.append("metadata"); metadata = "new"
        }, versions: {
            events.append("versions"); versions = ["restored", "old"]
        })
        #expect(events == ["restore", "invalidate", "content", "metadata", "versions"])
        #expect(displayed == Data([2]) && metadata == "new" && versions == ["restored", "old"])
        #expect(flow.phase == .complete && flow.activeVersion == nil && flow.errorMessage == nil)
        #expect(FileManager.default.fileExists(atPath: old.url.path) == false)
    }

    @Test("Write failure produces a visible error without stale success and remains retryable")
    func writeFailureAndRetry() async {
        let flow = VersionRestoreFlow()
        var refreshed = false
        await flow.restore("v", isCurrent: { true }, write: {
            throw PreviewRefreshError(message: "restore denied")
        }, invalidate: { Issue.record("Failed write invalidated cache") }, content: {
            refreshed = true
        }, metadata: {}, versions: {})
        #expect(flow.phase == .failed)
        #expect(flow.errorMessage == "restore denied")
        #expect(refreshed == false)
        #expect(flow.activeVersion == nil)
        await flow.restore("v", isCurrent: { true }, write: {}, invalidate: {}, content: {
            refreshed = true
        }, metadata: {}, versions: {})
        #expect(flow.phase == .complete && flow.errorMessage == nil)
        #expect(refreshed)
    }

    @Test("Refresh failure cannot report restore flow complete")
    func refreshFailure() async {
        let flow = VersionRestoreFlow()
        var versionsRefreshed = false
        await flow.restore("v", isCurrent: { true }, write: {}, invalidate: {}, content: {}, metadata: {
            throw PreviewRefreshError(message: "metadata refresh failed")
        }, versions: { versionsRefreshed = true })
        #expect(flow.phase == .failed)
        #expect(flow.errorMessage == "metadata refresh failed")
        #expect(versionsRefreshed == false)
        #expect(flow.activeVersion == nil)
    }

    @Test("Cancellation following successful remote write still invalidates but publishes no success")
    func cancelAfterWrite() async {
        let flow = VersionRestoreFlow()
        var invalidated = false, refreshed = false
        let task = Task { @MainActor in
            await flow.restore("v", isCurrent: { true }, write: {
                withUnsafeCurrentTask { $0?.cancel() }
            }, invalidate: { invalidated = true }, content: { refreshed = true }, metadata: {}, versions: {})
        }
        await task.value
        #expect(invalidated)
        #expect(refreshed == false)
        #expect(flow.phase == .idle && flow.activeVersion == nil)
    }
}

@Suite("N25 cache reset rejects suspended thumbnails", .timeLimit(.minutes(1)))
struct N25MediaCacheResetTests {
    @Test("Old decoded publication is rejected after reset while new generation can populate")
    func decodedReset() {
        let key = identity("thumbnail.png")
        var epoch = MediaCacheEpoch(), cache = ByteCostLRU<MediaObjectIdentity, Int>(limit: 64)
        let old = epoch.begin(key)
        epoch.reset(); cache.removeAll()
        #expect(epoch.publish(old, into: &cache, key: key, value: 1, cost: 16) == false)
        #expect(cache.count == 0 && cache.cost == 0)
        let fresh = epoch.begin(key)
        #expect(epoch.publish(fresh, into: &cache, key: key, value: 2, cost: 16))
        #expect(cache.value(for: key) == 2)
        epoch.finish(old); epoch.finish(fresh)
    }

    @Test("A suspended thumbnail original cannot repopulate disk after clear; fresh request succeeds")
    func diskReset() async throws {
        let folder = try mediaTemp(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = MediaOriginalStore(directory: folder), gate = MediaFixtureGate(), counter = MediaFixtureCounter(), key = identity("thumbnail.png")
        let old = Task { try await store.file(for: key) { await counter.increment(); await gate.wait(); return fixtureBody(Data([1])) } }
        try await mediaEventually { await counter.calls == 1 }
        try await store.clear(); await gate.release()
        await #expect(throws: CancellationError.self) { try await old.value }
        let fresh = try await store.file(for: key) { fixtureBody(Data([2])) }
        #expect(try Data(contentsOf: fresh.url) == Data([2]))
        #expect(await store.cachedBytes == 1)
        await store.release(fresh)
    }
}

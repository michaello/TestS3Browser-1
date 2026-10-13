import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum ProcessResidentMemory {
    static func peakBytes() -> UInt64? {
#if canImport(Darwin)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size_max) : nil
#else
        return nil
#endif
    }
}

enum AuditViewSurface: String, CaseIterable, Sendable {
    case browse, recent, prefix, dump, stash, gallery
}

struct AuditViewConstructionMetric: Codable, Sendable {
    var count = 0
    var totalMilliseconds = 0.0
    var maximumMilliseconds = 0.0
}

struct AuditPerformanceSnapshot: Codable, Sendable {
    var viewConstruction: [String: AuditViewConstructionMetric] = [:]
    var viewConstructionScope = "SwiftUI view construction only; excludes layout, drawing and framework work after body returns."
    var launchToFirstContentMilliseconds: Double?
    var cacheToFirstContentMilliseconds: Double?
    var refreshMilliseconds: [Double] = []
    var requestCount = 0
    var duplicateBodyRequests = 0
    var receivedBytes: Int64 = 0
    var confirmedUploadPayloadBytes: Int64 = 0
    var maximumOwnedBodyTransfers: Int?
    var unavailableMeasurements = ["Native AVFoundation HTTP wire bytes and requests", "Partial failed-upload bytes"]
    var byteMeasurementScope = "Consumed SDK object-download bytes and confirmed upload payload sizes; excludes HTTP overhead and retransmission."
    var failedRequests = 0
    var peakResidentBytes: UInt64?
    var maximumFrameGapMilliseconds: Double?
    var scrollingStalls = 0
}

/// Local aggregate measurements contain no credentials, bucket names or object keys.
/// Missing measurements remain nil, rather than being reported as measured zero.
@MainActor
final class AuditTelemetry {
    static let shared = AuditTelemetry()
    private let now: () -> Double
    private var launchStarted: Double
    private var cacheStarted: Double?
    private var requests: [UUID: (started: Double, identity: Data, body: Bool)] = [:]
    private var activeBodies: [Data: Int] = [:]
    private var refreshes: [UUID: Double] = [:]
    private var scrolling = false
    private(set) var snapshot = AuditPerformanceSnapshot()

    init(now: (() -> Double)? = nil) {
        let origin = ContinuousClock.now
        let clock = now ?? {
            let elapsed = origin.duration(to: .now).components
            return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        }
        self.now = clock
        launchStarted = clock()
    }

    func measureViewConstruction<Value>(_ surface: AuditViewSurface, build: () -> Value) -> Value {
        let started = now()
        let value = build()
        let elapsed = max(0, now() - started) * 1_000
        var metric = snapshot.viewConstruction[surface.rawValue] ?? AuditViewConstructionMetric()
        metric.count += 1
        metric.totalMilliseconds += elapsed
        metric.maximumMilliseconds = max(metric.maximumMilliseconds, elapsed)
        snapshot.viewConstruction[surface.rawValue] = metric
        return value
    }

    func cacheHydrationStarted() { cacheStarted = now() }
    func firstContentVisible(fromCache: Bool) {
        guard snapshot.launchToFirstContentMilliseconds == nil else { return }
        snapshot.launchToFirstContentMilliseconds = max(0, now() - launchStarted) * 1_000
        if fromCache, let cacheStarted {
            snapshot.cacheToFirstContentMilliseconds = max(0, now() - cacheStarted) * 1_000
        }
    }

    func beginRequest(identity: Data, body: Bool) -> UUID {
        let token = UUID()
        snapshot.requestCount += 1
        if body {
            if activeBodies[identity, default: 0] > 0 { snapshot.duplicateBodyRequests += 1 }
            activeBodies[identity, default: 0] += 1
        }
        requests[token] = (now(), identity, body)
        return token
    }

    func finishRequest(_ token: UUID, bytes: Int64, succeeded: Bool, confirmedUploadBytes: Int64 = 0) {
        guard let request = requests.removeValue(forKey: token) else { return }
        if request.body {
            activeBodies[request.identity, default: 1] -= 1
            if activeBodies[request.identity] == 0 { activeBodies[request.identity] = nil }
        }
        snapshot.receivedBytes += max(0, bytes)
        if succeeded { snapshot.confirmedUploadPayloadBytes += max(0, confirmedUploadBytes) }
        if !succeeded { snapshot.failedRequests += 1 }
    }

    func recordOwnedBodyTransfers(current: Int, peak: Int) {
        guard current >= 0, peak >= current else { return }
        snapshot.maximumOwnedBodyTransfers = max(snapshot.maximumOwnedBodyTransfers ?? 0, peak)
    }

    func beginRefresh() -> UUID {
        let token = UUID(); refreshes[token] = now(); return token
    }
    func finishRefresh(_ token: UUID) {
        guard let start = refreshes.removeValue(forKey: token) else { return }
        // Keep the instrumentation itself bounded during a long-running app session.
        snapshot.refreshMilliseconds.append(max(0, now() - start) * 1_000)
        if snapshot.refreshMilliseconds.count > 120 { snapshot.refreshMilliseconds.removeFirst() }
    }
    func setScrolling(_ scrolling: Bool) { self.scrolling = scrolling }
    func frameGap(seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        snapshot.maximumFrameGapMilliseconds = max(snapshot.maximumFrameGapMilliseconds ?? 0, seconds * 1_000)
        if scrolling && seconds > 0.05 { snapshot.scrollingStalls += 1 }
    }
    func residentMemory(peakBytes: UInt64) {
        snapshot.peakResidentBytes = max(snapshot.peakResidentBytes ?? 0, peakBytes)
    }
    func encodedSnapshot() throws -> Data { try JSONEncoder().encode(snapshot) }
}

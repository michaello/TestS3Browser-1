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

struct AuditPerformanceSnapshot: Codable, Sendable {
    var launchToFirstContentMilliseconds: Double?
    var cacheToFirstContentMilliseconds: Double?
    var refreshMilliseconds: [Double] = []
    var requestCount = 0
    var duplicateBodyRequests = 0
    var receivedBytes: Int64 = 0
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

    func finishRequest(_ token: UUID, bytes: Int64, succeeded: Bool) {
        guard let request = requests.removeValue(forKey: token) else { return }
        if request.body {
            activeBodies[request.identity, default: 1] -= 1
            if activeBodies[request.identity] == 0 { activeBodies[request.identity] = nil }
        }
        snapshot.receivedBytes += max(0, bytes)
        if !succeeded { snapshot.failedRequests += 1 }
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

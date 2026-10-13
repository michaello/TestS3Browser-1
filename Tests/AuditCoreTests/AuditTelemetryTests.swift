import Foundation
import Testing
@testable import AuditCore

@MainActor
struct F36PerformanceTests {
    @Test func aggregateEventsAreBoundedAndDoNotExportIdentities() throws {
        var clock = 0.0
        let telemetry = AuditTelemetry(now: { clock })
        clock = 0.01; telemetry.cacheHydrationStarted()
        clock = 0.02; telemetry.firstContentVisible(fromCache: true)
        let one = telemetry.beginRequest(identity: Data("private-object-identity".utf8), body: true)
        let two = telemetry.beginRequest(identity: Data("private-object-identity".utf8), body: true)
        telemetry.finishRequest(one, bytes: 10, succeeded: true)
        telemetry.finishRequest(two, bytes: 20, succeeded: false)
        telemetry.finishRequest(two, bytes: 20, succeeded: false)
        for _ in 0..<200 { let token = telemetry.beginRefresh();clock += 0.01;telemetry.finishRefresh(token) }
        let result = telemetry.snapshot
        #expect(result.launchToFirstContentMilliseconds == 20)
        #expect(result.cacheToFirstContentMilliseconds == 10)
        #expect(result.requestCount == 2)
        #expect(result.duplicateBodyRequests == 1)
        #expect(result.receivedBytes == 30)
        #expect(result.failedRequests == 1)
        #expect(result.refreshMilliseconds.count == 120)
        #expect(String(decoding: try telemetry.encodedSnapshot(), as: UTF8.self).contains("private-object-identity") == false)
    }

    @Test func unmeasuredValuesStayUnknownAndScrollingStallsAreScoped() {
        let telemetry = AuditTelemetry()
        #expect(telemetry.snapshot.peakResidentBytes == nil)
        #expect(telemetry.snapshot.cacheToFirstContentMilliseconds == nil)
        telemetry.frameGap(seconds: 0.1)
        #expect(telemetry.snapshot.scrollingStalls == 0)
        telemetry.setScrolling(true)
        telemetry.frameGap(seconds: 0.08)
        #expect(telemetry.snapshot.scrollingStalls == 1)
        telemetry.residentMemory(peakBytes: 100)
        telemetry.residentMemory(peakBytes: 90)
        #expect(telemetry.snapshot.peakResidentBytes == 100)
    }

    @Test func fixtureBenchmarkUsesActualCacheAndJoinedProductionLoader() async throws {
        let telemetry = AuditTelemetry()
        let loader = ResourceLoader<String, String>()
        telemetry.cacheHydrationStarted()
        loader.seed("saved", for: "fixture", refreshedAt: nil)
        #expect(loader.value(for: "fixture") == "saved")
        telemetry.firstContentVisible(fromCache: true)
        let refresh = telemetry.beginRefresh()
        let operation: @MainActor () async throws -> String = {
            let request = telemetry.beginRequest(identity: Data("fixture".utf8), body: true)
            try await Task.sleep(for: .milliseconds(20))
            telemetry.finishRequest(request, bytes: 512, succeeded: true)
            return "refreshed"
        }
        let first = Task { try await loader.load("fixture", operation: operation) }
        let second = Task { try await loader.load("fixture", operation: operation) }
        #expect(try await first.value == "refreshed")
        #expect(try await second.value == "refreshed")
        telemetry.finishRefresh(refresh)
        telemetry.setScrolling(true)
        telemetry.frameGap(seconds: 0.016)
        let peak = try #require(ProcessResidentMemory.peakBytes())
        telemetry.residentMemory(peakBytes: peak)
        #expect(telemetry.snapshot.requestCount == 1)
        #expect(telemetry.snapshot.duplicateBodyRequests == 0)
        #expect(telemetry.snapshot.receivedBytes == 512)
        #expect(telemetry.snapshot.peakResidentBytes ?? 0 > 0)
        #expect(telemetry.snapshot.refreshMilliseconds.first ?? 0 >= 10)
        let metrics = try JSONSerialization.jsonObject(with: telemetry.encodedSnapshot())
        let artifact: [String: Any] = ["metrics": metrics, "measurement_environment": "macOS production-core fixture",
            "scope": "Actual monotonic cache/refresh durations and process peak memory; joined fake transport bytes/counts. Frame gap is a deterministic fixture, not a simulator scrolling measurement."]
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("artifacts/audit")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("F36-benchmark.json")
        try JSONSerialization.data(withJSONObject: artifact, options: [.prettyPrinted, .sortedKeys]).write(to: path, options: .atomic)
        #expect((try Data(contentsOf: path)).isEmpty == false)
    }
}

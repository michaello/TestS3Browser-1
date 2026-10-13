import Foundation
import Testing
@testable import AuditCore

private actor BodyObservationProbe {
    var closes = 0
    func close() { closes += 1 }
}

@Suite("F36 actual consumed SDK body telemetry", .timeLimit(.minutes(1)))
@MainActor
struct F36MediaBodyObservationTests {
    @Test("Successful streamed body records real consumed bytes and owned permit peak")
    func successfulBody() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("body-observation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bytes = Data(repeating: 7, count: 180_001), reader = MediaDataReader(Data(repeating: 7, count: 180_001))
        let telemetry = AuditTelemetry(), token = telemetry.beginRequest(identity: Data("fixture".utf8), body: true)
        let limiter = BodyTransferLimiter(limit: 4), output = folder.appendingPathComponent("original.bin")
        let body = MediaDownloadBody(expectedBytes: Int64(bytes.count), read: { await reader.read() }, completion: { received, success in
            await MainActor.run { telemetry.finishRequest(token, bytes: received, succeeded: success) }
        })
        let actual = try await limiter.withPermit {
            let current = await limiter.activeCount, peak = await limiter.peak
            await MainActor.run { telemetry.recordOwnedBodyTransfers(current: current, peak: peak) }
            return try await MediaFileIO.shared.write(body, to: output, maximumBytes: nil, progress: { _ in })
        }
        let file = try Data(contentsOf: output)
        #expect(actual == Int64(bytes.count))
        #expect(file == bytes)
        #expect(telemetry.snapshot.receivedBytes == Int64(bytes.count))
        #expect(telemetry.snapshot.requestCount == 1)
        #expect(telemetry.snapshot.failedRequests == 0)
        #expect(telemetry.snapshot.maximumOwnedBodyTransfers == 1)
        #expect(telemetry.snapshot.unavailableMeasurements.contains("Native AVFoundation HTTP wire bytes and requests"))
    }

    @Test("Truncated body records consumed partial bytes and a failed request exactly once")
    func truncatedBody() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("body-truncated-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let telemetry = AuditTelemetry(), token = telemetry.beginRequest(identity: Data("partial".utf8), body: true)
        let reader = MediaDataReader(Data(repeating: 1, count: 7))
        let body = MediaDownloadBody(expectedBytes: 10, read: { await reader.read() }, completion: { received, success in
            await MainActor.run { telemetry.finishRequest(token, bytes: received, succeeded: success) }
        })
        await #expect(throws: MediaTransferError.sizeMismatch) {
            try await MediaFileIO.shared.write(body, to: url, maximumBytes: nil, progress: { _ in })
        }
        #expect(telemetry.snapshot.receivedBytes == 7)
        #expect(telemetry.snapshot.failedRequests == 1)
        // A repeated close or callback cannot double-count this actual request token.
        telemetry.finishRequest(token, bytes: 7, succeeded: false)
        #expect(telemetry.snapshot.receivedBytes == 7)
    }

    @Test("Destination creation failure finishes telemetry and closes unread SDK body")
    func unreadBodyCleanup() async throws {
        let unavailable = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("missing/original")
        let telemetry = AuditTelemetry(), token = telemetry.beginRequest(identity: Data("disk-failure".utf8), body: true)
        let probe = BodyObservationProbe()
        let body = MediaDownloadBody(expectedBytes: 10, read: { Issue.record("Unavailable destination must not read SDK body"); return Data([1]) },
            close: { Task { await probe.close() } }, completion: { received, success in
                await MainActor.run { telemetry.finishRequest(token, bytes: received, succeeded: success) }
            })
        await #expect(throws: (any Error).self) {
            try await MediaFileIO.shared.write(body, to: unavailable, maximumBytes: nil, progress: { _ in })
        }
        for _ in 0..<1000 { if await probe.closes > 0 { break }; await Task.yield() }
        #expect(await probe.closes == 1)
        #expect(telemetry.snapshot.receivedBytes == 0)
        #expect(telemetry.snapshot.failedRequests == 1)
        #expect(FileManager.default.fileExists(atPath: unavailable.path) == false)
    }
}

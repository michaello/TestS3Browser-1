import Foundation
import Testing
@testable import AuditCore

@MainActor @Suite(.timeLimit(.minutes(1)))
struct F35FileUploadQueueTests {
    enum Failure: Error { case denied }

    @Test func successfulUploadReadsOwnedFileAndCleansPayload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data((0..<10_000).map { UInt8($0 % 255) })
        var requests: [String] = []
        let queue = FileUploadQueue(store: UploadPayloadStore(directory: directory)) { job, progress in
            let actualBytes = try Data(contentsOf: job.fileURL)
            #expect(actualBytes == bytes)
            requests.append(job.account + ":" + job.bucket + "/" + job.key)
            progress(0.5)
        }
        let job = try await queue.enqueue(filename: String(repeating: "你好", count: 500), key: "folder//a?+.jpg",
            bucket: "original", account: "captured-account", contentType: "image/jpeg", data: bytes)
        #expect(try await queue.waitForCompletion(id: job.id) == "folder//a?+.jpg")
        #expect(requests == ["captured-account:original/folder//a?+.jpg"])
        #expect(job.isDone)
        #expect(FileManager.default.fileExists(atPath: job.fileURL.path) == false)
        #expect(job.fileURL.lastPathComponent.utf8.count < 64)
        #expect(job.byteCount == Int64(bytes.count))
    }

    @Test func failedUploadRetainsFileAndRetryUsesSameDestination() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var attempts = 0
        let queue = FileUploadQueue(store: UploadPayloadStore(directory: directory)) { job, _ in
            attempts += 1
            #expect(job.bucket == "first")
            let actualBytes = try Data(contentsOf: job.fileURL)
            #expect(actualBytes == Data([7]))
            if attempts == 1 { throw Failure.denied }
        }
        let job = try await queue.enqueue(filename: "one", key: "key", bucket: "first", account: "A",
            contentType: "application/octet-stream", data: Data([7]))
        await #expect(throws: (any Error).self) { try await queue.waitForCompletion(id: job.id) }
        #expect(job.isFailed)
        #expect(FileManager.default.fileExists(atPath: job.fileURL.path))
        queue.retry(id: job.id)
        #expect(try await queue.waitForCompletion(id: job.id) == "key")
        #expect(attempts == 2)
        #expect(job.retryCount == 1)
        #expect(FileManager.default.fileExists(atPath: job.fileURL.path) == false)
    }

    @Test func cancellationOfActiveUploadCleansOwnedFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var started = false
        let queue = FileUploadQueue(store: UploadPayloadStore(directory: directory)) { _, _ in
            started = true
            while !Task.isCancelled { await Task.yield() }
            try Task.checkCancellation()
        }
        let job = try await queue.enqueue(filename: "one", key: "key", bucket: "bucket", account: "A",
            contentType: "application/octet-stream", data: Data([1]))
        while !started { await Task.yield() }
        await queue.cancel(id: job.id)
        await #expect(throws: CancellationError.self) { try await queue.waitForCompletion(id: job.id) }
        if case .cancelled = job.state {} else { Issue.record("Cancelled upload remained active") }
        #expect(FileManager.default.fileExists(atPath: job.fileURL.path) == false)
    }

    @Test func cancelledQueuedJobNeverStartsAndOtherJobsContinue() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var release: CheckedContinuation<Void, Never>?
        var keys: [String] = []
        let queue = FileUploadQueue(store: UploadPayloadStore(directory: directory)) { job, _ in
            keys.append(job.key)
            if job.key == "first" { await withCheckedContinuation { release = $0 } }
        }
        let first = try await queue.enqueue(filename: "one", key: "first", bucket: "b", account: "A", contentType: "text/plain", data: Data())
        while release == nil { await Task.yield() }
        let second = try await queue.enqueue(filename: "two", key: "second", bucket: "b", account: "A", contentType: "text/plain", data: Data())
        await queue.cancel(id: second.id)
        #expect(keys == ["first"])
        #expect(FileManager.default.fileExists(atPath: second.fileURL.path) == false)
        release?.resume()
        #expect(try await queue.waitForCompletion(id: first.id) == "first")
        await #expect(throws: CancellationError.self) { try await queue.waitForCompletion(id: second.id) }
    }

    @Test func fileInputIsOwnedCopyAndProducerDisappearanceDoesNotStopQueue() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let input = directory.appendingPathComponent("input")
        try Data([1, 2, 3]).write(to: input)
        var release: CheckedContinuation<Void, Never>?
        let queue = FileUploadQueue(store: UploadPayloadStore(directory: directory.appendingPathComponent("queue"))) { job, _ in
            await withCheckedContinuation { release = $0 }
            let actualBytes = try Data(contentsOf: job.fileURL)
            #expect(actualBytes == Data([1, 2, 3]))
        }
        let job = try await queue.enqueue(filename: "input", key: "key", bucket: "b", account: "A", contentType: "text/plain", file: input)
        while release == nil { await Task.yield() }
        try FileManager.default.removeItem(at: input)
        let producer = Task { try await queue.waitForCompletion(id: job.id) }
        producer.cancel()
        release?.resume()
        #expect(try await producer.value == "key")
        #expect(job.isDone)
        #expect(FileManager.default.fileExists(atPath: job.fileURL.path) == false)
    }
}

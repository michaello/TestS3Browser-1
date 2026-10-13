import CryptoKit
import Foundation
import Testing
@testable import AuditCore

private struct ShareFileFixture: Sendable {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    func payload(_ index: Int) throws -> PreparedUploadPayload {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("input-\(index).png")
        try Data([UInt8(index % 255)]).write(to: url)
        return .init(file: url, filename: url.lastPathComponent, contentType: "image/png", ownsInputFile: true)
    }
    func cleanup() { try? FileManager.default.removeItem(at: folder) }
}

@MainActor
struct F31SharePipelineTests {
    @Test func attachmentsAreLoadedSentAndCleanedOneAtATime() async throws {
        let fixture = ShareFileFixture(); defer { fixture.cleanup() }
        var peak = 0, sent = 0
        let sources = (0..<40).map { index in
            ShareAttachmentSource(name: "image-\(index)") {
                let payload = try fixture.payload(index)
                peak = max(peak, try FileManager.default.contentsOfDirectory(atPath: fixture.folder.path).count)
                return payload
            }
        }
        let report = await ShareAttachmentPipeline.process(sources) { payload in
            guard case .file(let url) = payload.body else { throw UploadPreparationError.unavailableRepresentation }
            #expect(try Data(contentsOf: url) == Data([UInt8(sent)]))
            sent += 1
            await Task.yield()
            return "uploaded-\(sent)"
        }
        #expect(peak == 1)
        #expect(sent == 40)
        #expect(report.keys.count == 40)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.folder.path).isEmpty)
    }

    @Test func cancellationRetainsKnownSuccessAndDoesNotLoadPendingAttachments() async {
        let fixture = ShareFileFixture(); defer { fixture.cleanup() }
        var loads = 0
        let sources = (0..<10).map { index in
            ShareAttachmentSource(name: "image-\(index)") { loads += 1; return try fixture.payload(index) }
        }
        let task = Task {
            await ShareAttachmentPipeline.process(sources) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return "confirmed-first"
            }
        }
        let report = await task.value
        #expect(loads == 1)
        #expect(report.keys == ["confirmed-first"])
        #expect(report.cancelled == 9)
        #expect(report.outcomes.count == 10)
        #expect(report.summary.contains("in-flight upload may already have completed"))
    }

    @Test func cancellationAfterRepresentationLoadingCleansBeforeRemoteMutation() async throws {
        let fixture = ShareFileFixture(); defer { fixture.cleanup() }
        var sends = 0
        let task = Task {
            await ShareAttachmentPipeline.process([.init(name: "image") {
                let payload = try fixture.payload(1)
                withUnsafeCurrentTask { $0?.cancel() }
                return payload
            }]) { _ in sends += 1; return "unexpected" }
        }
        let report = await task.value
        #expect(sends == 0)
        #expect(report.cancelled == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.folder.path).isEmpty)
    }

    @Test func fileSigningHashesActualChunksAndKeepsHTTPBodyFileBacked() async throws {
        let fixture = ShareFileFixture(); defer { fixture.cleanup() }
        let payload = try fixture.payload(1)
        guard case .file(let file) = payload.body else { return }
        let bytes = Data(repeating: 42, count: 196_609)
        try bytes.write(to: file)
        let signed = try await S3FileUploadSigning.shared.request(file: file, bucket: "dummy", region: "us-east-1",
            key: "dump//a?#+%é.png", accessKey: "dummy", secretKey: "dummy", contentType: "image/png",
            now: Date(timeIntervalSince1970: 0))
        #expect(signed.bytes == Int64(bytes.count))
        #expect(signed.request.httpBody == nil)
        #expect(signed.request.httpBodyStream == nil)
        #expect(signed.request.value(forHTTPHeaderField: "Content-Length") == String(bytes.count))
        #expect(signed.request.value(forHTTPHeaderField: "x-amz-content-sha256") ==
            SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        #expect(signed.request.url?.absoluteString == "https://dummy.s3.amazonaws.com/dump//a%3F%23%2B%25%C3%A9.png")
        #expect(signed.request.value(forHTTPHeaderField: "Authorization")?.contains("Signature=") == true)
    }
}

@MainActor
struct F31FilePromiseTests {
    @Test func differentFileFromDuplicateCallbackIsDisposedWithoutRemovingAdoptedFile() async throws {
        let fixture = ShareFileFixture(); defer { fixture.cleanup() }
        guard case .file(let adopted) = try fixture.payload(1).body,
              case .file(let rejected) = try fixture.payload(2).body else { return }
        let promise = CancellableFilePromise<URL>(dispose: { try? FileManager.default.removeItem(at: $0) })
        let received = try await promise.value { finish in
            finish(.success(adopted)); finish(.success(rejected))
            return Progress(totalUnitCount: 1)
        }
        #expect(received == adopted)
        #expect(FileManager.default.fileExists(atPath: adopted.path))
        #expect(!FileManager.default.fileExists(atPath: rejected.path))
    }
    @Test func cancelledProviderProgressResolvesAndLateFileIsDisposed() async throws {
        let fixture = ShareFileFixture(); defer { fixture.cleanup() }
        let progress = Progress(totalUnitCount: 1)
        let promise = CancellableFilePromise<URL>(dispose: { try? FileManager.default.removeItem(at: $0) })
        var callback: (@Sendable (Result<URL, any Error>) -> Void)?
        let task = Task { try await promise.value { callback = $0; return progress } }
        while callback == nil { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(progress.isCancelled)
        guard case .file(let late) = try fixture.payload(1).body else { return }
        callback?(.success(late))
        #expect(!FileManager.default.fileExists(atPath: late.path))
    }

    @Test func duplicateCallbackDoesNotResumeTwiceOrDeleteAdoptedFile() async throws {
        let fixture = ShareFileFixture(); defer { fixture.cleanup() }
        guard case .file(let file) = try fixture.payload(1).body else { return }
        let promise = CancellableFilePromise<URL>(dispose: { try? FileManager.default.removeItem(at: $0) })
        let received = try await promise.value { finish in
            finish(.success(file)); finish(.success(file))
            return Progress(totalUnitCount: 1)
        }
        #expect(received == file)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func cancelledBeforeStartNeverRequestsRepresentation() async {
        let promise = CancellableFilePromise<URL>(dispose: { _ in })
        var starts = 0
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await promise.value { _ in starts += 1; return Progress(totalUnitCount: 1) }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(starts == 0)
    }
}

@MainActor
struct N35ShareOutcomeTests {
    @Test func providerAndUnsupportedFailuresRemainInOriginalAttemptedCount() async throws {
        let fixture = ShareFileFixture(); defer { fixture.cleanup() }
        let sources: [ShareAttachmentSource] = [
            .init(name: "first.png") { try fixture.payload(0) },
            .init(name: "unreadable.png") { throw CocoaError(.fileReadNoPermission) },
            .init(name: "unsupported.txt") { throw UploadPreparationError.unavailableRepresentation },
            .init(name: "last.png") { try fixture.payload(3) }
        ]
        let report = await ShareAttachmentPipeline.process(sources) { $0.filename }
        #expect(report.attempted == 4)
        #expect(report.keys.count == 2)
        #expect(report.failed == 2)
        #expect(report.summary.contains("Uploaded 2 of 4"))
        #expect(report.summary.contains("unreadable.png"))
        #expect(report.summary.contains("unsupported.txt"))
        #expect(report.outcomes.map(\.index) == [0, 1, 2, 3])
    }

    @Test func middleUploadFailureDoesNotDropOtherAttachmentOutcomes() async throws {
        let fixture = ShareFileFixture(); defer { fixture.cleanup() }
        let sources = (0..<3).map { index in ShareAttachmentSource(name: "image-\(index)") { try fixture.payload(index) } }
        var sends = 0
        let report = await ShareAttachmentPipeline.process(sources) { _ in
            sends += 1
            if sends == 2 { throw CocoaError(.fileWriteNoPermission) }
            return "key-\(sends)"
        }
        #expect(report.keys == ["key-1", "key-3"])
        #expect(report.failed == 1)
        #expect(report.attempted == 3)
        #expect(report.summary.contains("image-1"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.folder.path).isEmpty)
    }

    @Test func totalProviderFailureCannotReportSuccessfulSmallerBatch() async {
        let sources = (0..<2).map { index in ShareAttachmentSource(name: "image-\(index)") { throw CocoaError(.fileReadUnknown) } }
        let report = await ShareAttachmentPipeline.process(sources) { _ in Issue.record("Failed provider uploaded"); return "bad" }
        #expect(report.keys.isEmpty)
        #expect(report.failed == 2)
        #expect(report.summary.contains("Uploaded 0 of 2"))
    }
}

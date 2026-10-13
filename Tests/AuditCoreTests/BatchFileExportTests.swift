import Foundation
import Testing
@testable import AuditCore

private func exportItem(_ key: String) -> BatchExportItem {
    .init(identity: .init(account: "A", bucket: "captured-bucket", key: key, etag: "revision", version: nil), bytes: 3)
}

private struct ExportFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var store: MediaExportStore { MediaExportStore(directory: root.appendingPathComponent("exports")) }
    func original(_ item: BatchExportItem) throws -> OriginalFileLease {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent(UUID().uuidString)
        try Data([1, 2, 3]).write(to: url)
        return .init(id: UUID(), identity: item.identity, url: url, bytes: 3)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@MainActor @Suite(.timeLimit(.minutes(1)))
struct N06BoundedBatchExportTests {
    @Test func largeSelectionUsesFourFileBackedWorkersAndCollisionSafePaths() async throws {
        let fixture = ExportFixture(); defer { fixture.cleanup() }
        let store = fixture.store
        var active = 0, peak = 0, released = 0
        let owner = BatchFileExport(store: store, limit: 100, load: { item in
            active += 1; peak = max(peak, active)
            defer { active -= 1 }
            for _ in 0..<20 { await Task.yield() }
            return try fixture.original(item)
        }, releaseOriginal: { _ in await MainActor.run { released += 1 } })
        let items = (0..<24).map { exportItem("folder-\($0)/same #?+.png") }
        try await owner.prepare(items)
        #expect(peak == 4)
        #expect(active == 0)
        #expect(released == 24)
        #expect(owner.urls.count == 24)
        #expect(Set(owner.urls).count == 24)
        for url in owner.urls { #expect(try Data(contentsOf: url) == Data([1, 2, 3])) }
        await owner.close()
        #expect(await store.activeLeaseCount == 0)
    }

    @Test func cancellingOwnedOperationStopsWorkersAndCleansPreparedFiles() async throws {
        let fixture = ExportFixture(); defer { fixture.cleanup() }
        let store = fixture.store
        var calls = 0, active = 0
        let owner = BatchFileExport(store: store, load: { item in
            calls += 1; active += 1
            defer { active -= 1 }
            if item.identity.key != "first" {
                while !Task.isCancelled { await Task.yield() }
                try Task.checkCancellation()
            }
            return try fixture.original(item)
        }, releaseOriginal: { _ in })
        let task = Task { try await owner.prepare([exportItem("first")] + (0..<30).map { exportItem("later-\($0)") }) }
        while await store.activeLeaseCount == 0 { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(active == 0)
        #expect(calls <= 5)
        #expect(owner.urls.isEmpty)
        #expect(await store.activeLeaseCount == 0)
    }

    @Test func loaderReceivesCapturedAccountBucketKeyAndRevision() async throws {
        let fixture = ExportFixture(); defer { fixture.cleanup() }
        let original = exportItem("folder//same?+.png")
        let owner = BatchFileExport(store: fixture.store, load: { item in
            await Task.yield()
            #expect(item.identity == original.identity)
            #expect(item.identity.bucket == "captured-bucket")
            return try fixture.original(item)
        }, releaseOriginal: { _ in })
        try await owner.prepare([original])
        #expect(owner.successes.count == 1)
        await owner.close()
    }
}

@MainActor @Suite(.timeLimit(.minutes(1)))
struct N36PartialBatchExportTests {
    @Test func missingFilesAreVisibleAndRetryDoesNotRedownloadSuccesses() async throws {
        let fixture = ExportFixture(); defer { fixture.cleanup() }
        var calls: [String: Int] = [:]
        let owner = BatchFileExport(store: fixture.store, load: { item in
            let key = item.identity.key
            calls[key, default: 0] += 1
            if key == "missing.txt", calls[key] == 1 { throw CocoaError(.fileReadNoPermission) }
            return try fixture.original(item)
        }, releaseOriginal: { _ in })
        try await owner.prepare([exportItem("ok.txt"), exportItem("missing.txt"), exportItem("also-ok.txt")])
        #expect(owner.urls.count == 2)
        #expect(owner.failures.count == 1)
        #expect(owner.summary.contains("Downloaded 2 of 3"))
        #expect(owner.summary.contains("missing.txt"))
        #expect(owner.summary.contains("Retry Failed"))
        let firstFiles = Set(owner.urls)
        try await owner.retryFailures()
        #expect(owner.urls.count == 3)
        #expect(firstFiles.isSubset(of: Set(owner.urls)))
        #expect(calls == ["ok.txt": 1, "missing.txt": 2, "also-ok.txt": 1])
        #expect(owner.failures.isEmpty)
        await owner.close()
    }

    @Test func completeFailureHasTerminalErrorSummaryAndNoShareFiles() async throws {
        let fixture = ExportFixture(); defer { fixture.cleanup() }
        let owner = BatchFileExport(store: fixture.store, load: { _ in throw CocoaError(.fileReadUnknown) }, releaseOriginal: { _ in })
        try await owner.prepare([exportItem("a.txt"), exportItem("b.txt")])
        #expect(!owner.isPreparing)
        #expect(owner.urls.isEmpty)
        #expect(owner.failures.count == 2)
        #expect(owner.summary.contains("Downloaded 0 of 2"))
        #expect(owner.summary.contains("a.txt"))
        #expect(owner.summary.contains("b.txt"))
    }
}

@MainActor
struct N44BatchExportCleanupTests {
    @Test func activityCompletionAndCancelledShareBothReleaseAllFiles() async throws {
        let fixture = ExportFixture(); defer { fixture.cleanup() }
        let store = fixture.store
        let owner = BatchFileExport(store: store, load: { try fixture.original($0) }, releaseOriginal: { _ in })
        for _ in 0..<2 {
            try await owner.prepare([exportItem("a.txt"), exportItem("b.txt")])
            let urls = owner.urls
            #expect(await store.activeLeaseCount == 2)
            await owner.close()
            await owner.close()
            #expect(await store.activeLeaseCount == 0)
            for url in urls { #expect(!FileManager.default.fileExists(atPath: url.path)) }
        }
    }

    @Test func failedStagingReleasesOriginalAndLeavesNoExportLease() async throws {
        let fixture = ExportFixture(); defer { fixture.cleanup() }
        let store = fixture.store
        var releases = 0
        let owner = BatchFileExport(store: store, load: { item in
            .init(id: UUID(), identity: item.identity, url: fixture.root.appendingPathComponent("missing"), bytes: 3)
        }, releaseOriginal: { _ in await MainActor.run { releases += 1 } })
        try await owner.prepare([exportItem("bad.txt")])
        #expect(releases == 1)
        #expect(owner.urls.isEmpty)
        #expect(owner.failures.count == 1)
        #expect(await store.activeLeaseCount == 0)
    }
}

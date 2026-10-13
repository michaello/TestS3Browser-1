import Foundation
import Testing
@testable import AuditCore

@MainActor
struct F30ListPresentationTests {
    @Test("Initial failure and a successful empty snapshot remain distinct from loading")
    func initialAndEmptyStates() {
        #expect(ListPresentation.resolve(hasSnapshot: false, rowCount: 0, isLoading: true, error: nil) == .initialLoading)
        #expect(ListPresentation.resolve(hasSnapshot: false, rowCount: 0, isLoading: false, error: "Denied") == .initialFailure("Denied"))
        #expect(ListPresentation.resolve(hasSnapshot: true, rowCount: 0, isLoading: false, error: nil) == .empty(refreshing: false, error: nil))
        #expect(ListPresentation.resolve(hasSnapshot: true, rowCount: 0, isLoading: false, error: "Offline") == .empty(refreshing: false, error: "Offline"))
    }

    @Test("Cached content remains content during a suspended and failed refresh, and explicit retry recovers")
    func cachedRefreshStates() async throws {
        let loader = ResourceLoader<String, [Int]>(), started = AsyncStream<Void>.makeStream()
        loader.seed([1, 2, 3], for: "rows", refreshedAt: nil)
        var continuation: CheckedContinuation<[Int], Error>?
        let pending = Task {
            try await loader.load("rows") {
                try await withCheckedThrowingContinuation { value in continuation = value;started.continuation.yield(()) }
            }
        }
        var iterator = started.stream.makeAsyncIterator();_ = await iterator.next()
        #expect(ListPresentation.resolve(hasSnapshot: true, rowCount: loader.value(for: "rows")!.count, isLoading: loader.isLoading("rows"), error: loader.error(for: "rows")) == .content(refreshing: true, error: nil))
        continuation?.resume(throwing: ResourceLoadError.failed("Offline"))
        await #expect(throws: ResourceLoadError.self) { try await pending.value }
        #expect(ListPresentation.resolve(hasSnapshot: true, rowCount: loader.value(for: "rows")!.count, isLoading: false, error: loader.error(for: "rows")) == .content(refreshing: false, error: "Offline"))
        #expect(try await loader.load("rows", policy: .force) { [4] } == [4])
        #expect(loader.error(for: "rows") == nil)
    }
}

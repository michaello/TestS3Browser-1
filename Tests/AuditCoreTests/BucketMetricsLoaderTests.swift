import Foundation
import Testing
@testable import AuditCore

@MainActor
struct AuditN28 {
    enum Failure: Error { case denied }

    @Test func configuredPagesProduceEntriesAndOpaqueTokensAdvance() async throws {
        var tokens: [String?] = []
        let first = BucketMetricsConfiguration(id: "request-all", scope: "All objects")
        let second = BucketMetricsConfiguration(id: "logs", scope: "Prefix: logs/")
        let result = try await BucketMetricsLoader.load { token in
            tokens.append(token)
            if token == nil {
                return BucketMetricsPage(configurations: [first], isTruncated: true, nextToken: "opaque+/= token")
            }
            return BucketMetricsPage(configurations: [second], isTruncated: false)
        }
        #expect(tokens.count == 2)
        #expect(tokens[0] == nil)
        #expect(tokens[1] == "opaque+/= token")
        #expect(result == [first, second])
    }

    @Test func emptyConfigurationIsOnlyASuccessfulEmptyResponse() async throws {
        let empty = try await BucketMetricsLoader.load { _ in BucketMetricsPage(configurations: [], isTruncated: false) }
        #expect(empty.isEmpty)
        await #expect(throws: Failure.denied) {
            try await BucketMetricsLoader.load { _ in throw Failure.denied }
        }
    }

    @Test func laterPageFailureDoesNotReturnPartialAsComplete() async {
        var requests = 0
        await #expect(throws: Failure.denied) {
            try await BucketMetricsLoader.load { _ in
                requests += 1
                if requests == 1 {
                    return BucketMetricsPage(configurations: [BucketMetricsConfiguration(id: "known", scope: "All objects")], isTruncated: true, nextToken: "next")
                }
                throw Failure.denied
            }
        }
        #expect(requests == 2)
    }

    @Test func truncatedMissingOrRepeatedTokenFails() async {
        await #expect(throws: BucketMetricsError.invalidPagination) {
            try await BucketMetricsLoader.load { _ in BucketMetricsPage(configurations: [], isTruncated: true) }
        }
        var requests = 0
        await #expect(throws: BucketMetricsError.invalidPagination) {
            try await BucketMetricsLoader.load { _ in
                requests += 1
                return BucketMetricsPage(configurations: [], isTruncated: true, nextToken: "same")
            }
        }
        #expect(requests == 2)
    }

    @Test func invalidConfigurationDoesNotMasqueradeAsUnconfigured() async {
        await #expect(throws: BucketMetricsError.invalidConfiguration) {
            try await BucketMetricsLoader.load { _ in
                BucketMetricsPage(configurations: [BucketMetricsConfiguration(id: "", scope: "All objects")], isTruncated: false)
            }
        }
    }

    @Test func duplicateConfigurationKeepsStableDisplayIdentity() async throws {
        let configuration = BucketMetricsConfiguration(id: "existing", scope: "All objects")
        let result = try await BucketMetricsLoader.load { token in
            BucketMetricsPage(configurations: [configuration], isTruncated: token == nil, nextToken: "second")
        }
        #expect(result == [configuration])
    }

    @Test func cancelledRequestCannotPublishConfiguration() async {
        var release: CheckedContinuation<BucketMetricsPage, Never>?
        let task = Task {
            try await BucketMetricsLoader.load { _ in await withCheckedContinuation { release = $0 } }
        }
        while release == nil { await Task.yield() }
        task.cancel()
        release?.resume(returning: BucketMetricsPage(configurations: [BucketMetricsConfiguration(id: "late", scope: "All objects")], isTruncated: false))
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

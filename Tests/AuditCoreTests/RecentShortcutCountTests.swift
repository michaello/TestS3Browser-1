import Testing
@testable import AuditCore

@Suite("N15 Shortcuts count validation before scanning")
@MainActor
struct N15ShortcutCountTests {
    @Test("Negative counts fail before service or collection work", arguments: [Int.min, -1])
    func invalidCounts(value: Int) async {
        var didFetch = false
        await #expect(throws: RecentShortcutCountError.outOfRange) {
            let request = try RecentShortcutCount(value)
            let _: [Int] = try await request.load { _ in
                didFetch = true
                return [1]
            }
        }
        #expect(didFetch == false)
    }

    @Test("Zero produces an empty result without constructing or scanning a service")
    func zeroDoesNotFetch() async throws {
        var didFetch = false
        let output: [Int] = try await RecentShortcutCount(0).load { _ in
            didFetch = true
            return [1, 2, 3]
        }
        #expect(output.isEmpty)
        #expect(didFetch == false)
    }

    @Test("Supported positive boundaries forward their exact limit and bound results", arguments: [1, 10, 1_000, Int.max])
    func positiveBoundaries(value: Int) async throws {
        var requests: [Int] = []
        let fixtures = Array(0..<1_001)
        let output = try await RecentShortcutCount(value).load { limit in
            requests.append(limit)
            return fixtures
        }
        #expect(requests == [value])
        #expect(output == Array(fixtures.prefix(min(value, fixtures.count))))
    }

    @Test("A short valid result and transport failure retain their meaning")
    func shortResultAndFailure() async throws {
        let output = try await RecentShortcutCount(10).load { _ in [1, 2] }
        #expect(output == [1, 2])
        await #expect(throws: FixtureError.failed) {
            let _: [Int] = try await RecentShortcutCount(1).load { _ in throw FixtureError.failed }
        }
    }

    @Test("Cancellation after fetching prevents a successful stale result")
    func cancelledFetch() async throws {
        let task = Task { @MainActor in
            try await RecentShortcutCount(1).load { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return [1]
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    private enum FixtureError: Error { case failed }
}

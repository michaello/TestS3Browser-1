import Foundation
import Testing
@testable import AuditCore

@MainActor
struct N33ObjectVersionHistoryTests {
    func entry(_ index: Int, key: String = "object") -> ObjectVersionHistoryPage.Entry {
        .init(key: key, record: .init(versionId: "v/\(index)+?%", lastModified: Date(timeIntervalSince1970: Double(index)),
            size: index, isLatest: index == 1000))
    }

    @Test func bothMarkersReachOlderRestorePointsBeyondOneThousandVersions() async throws {
        var received: [ObjectVersionCursor] = []
        let marker = ObjectVersionCursor(key: "object", version: "v/+%?=&")
        let records = try await ObjectVersionHistory.load(key: "object") { cursor in
            received.append(cursor)
            if cursor.key == nil {
                return .init(entries: (1...1000).map { entry($0) }, isTruncated: true, next: marker)
            }
            #expect(cursor == marker)
            return .init(entries: [entry(0)], isTruncated: false, next: .init(key: nil, version: nil))
        }
        #expect(records.count == 1001)
        #expect(records.first?.versionId == "v/1000+?%")
        #expect(records.last?.versionId == "v/0+?%")
        #expect(received == [.init(key: nil, version: nil), marker])
    }

    @Test func keyFilterIsExactAndDuplicatePageEntriesAreCollapsed() async throws {
        let record = S3VersionEntry(versionId: "é", lastModified: .distantPast, size: 1, isLatest: false)
        let distinct = S3VersionEntry(versionId: "e\u{301}", lastModified: .distantPast, size: 1, isLatest: false)
        let records = try await ObjectVersionHistory.load(key: "é") { _ in
            .init(entries: [.init(key: "é", record: record), .init(key: "é", record: record),
                            .init(key: "é", record: distinct), .init(key: "e\u{301}", record: entry(2).record),
                            .init(key: "é/longer", record: entry(3).record)],
                  isTruncated: false, next: .init(key: nil, version: nil))
        }
        #expect(records.count == 2)
        #expect(Set(records.map(\.id)).count == 2)
    }

    @Test func missingOrRepeatedMarkersFailRatherThanHidingHistory() async {
        for missing in [false, true] {
            var calls = 0
            await #expect(throws: ObjectVersionHistoryError.self) {
                try await ObjectVersionHistory.load(key: "object") { _ in
                    calls += 1
                    return .init(entries: [entry(1)], isTruncated: true,
                        next: .init(key: missing ? nil : "object", version: "same"))
                }
            }
            #expect(calls == (missing ? 1 : 2))
        }
    }

    @Test func laterFailureAndChangedGenerationNeverReturnPartialSuccess() async {
        for changed in [false, true] {
            var current = true, calls = 0
            await #expect(throws: (any Error).self) {
                try await ObjectVersionHistory.load(key: "object", isCurrent: { current }) { _ in
                    calls += 1
                    if calls == 2 { throw CocoaError(.fileReadNoPermission) }
                    current = !changed
                    return .init(entries: [entry(1)], isTruncated: true, next: .init(key: "object", version: "v1"))
                }
            }
            #expect(calls == (changed ? 1 : 2))
        }
    }

    @Test func cancellationStopsBeforeFetchingAnotherPage() async {
        var calls = 0
        let task = Task {
            try await ObjectVersionHistory.load(key: "object") { _ in
                calls += 1
                withUnsafeCurrentTask { $0?.cancel() }
                return .init(entries: [entry(1)], isTruncated: true, next: .init(key: "object", version: "v1"))
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(calls == 1)
    }
}

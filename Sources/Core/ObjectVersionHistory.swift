import Foundation

struct S3VersionEntry: Identifiable, Sendable {
    let versionId: String
    let lastModified: Date
    let size: Int
    let isLatest: Bool
    var id: String { Data(versionId.utf8).base64EncodedString() }

    var formattedSize: String {
        let kb = Double(size) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f GB", mb / 1024)
    }
}

struct ObjectVersionCursor: Hashable, Sendable {
    let key: String?
    let version: String?
    private var fields: [Data?] { [key.map { Data($0.utf8) }, version.map { Data($0.utf8) }] }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.fields == rhs.fields }
    func hash(into hasher: inout Hasher) { hasher.combine(fields) }
}

struct ObjectVersionHistoryPage: Sendable {
    struct Entry: Sendable { let key: String; let record: S3VersionEntry }
    let entries: [Entry]
    let isTruncated: Bool
    let next: ObjectVersionCursor
}

enum ObjectVersionHistoryError: LocalizedError {
    case invalidPagination
    var errorDescription: String? { "S3 returned incomplete or repeated version pagination markers. Retry loading history." }
}

enum ObjectVersionHistory {
    @MainActor
    static func load(key: String, isCurrent: () -> Bool = { true },
                     fetch: (ObjectVersionCursor) async throws -> ObjectVersionHistoryPage) async throws -> [S3VersionEntry] {
        var cursor = ObjectVersionCursor(key: nil, version: nil)
        var seen: Set<ObjectVersionCursor> = [cursor]
        var records: [String: S3VersionEntry] = [:]
        while true {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            let page = try await fetch(cursor)
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            for entry in page.entries where entry.key.utf8.elementsEqual(key.utf8) {
                records[entry.record.id] = entry.record
            }
            guard page.isTruncated else { break }
            guard page.next.key != nil, seen.insert(page.next).inserted else {
                throw ObjectVersionHistoryError.invalidPagination
            }
            cursor = page.next
        }
        return records.values.sorted {
            if $0.lastModified == $1.lastModified { return $0.id < $1.id }
            return $0.lastModified > $1.lastModified
        }
    }
}

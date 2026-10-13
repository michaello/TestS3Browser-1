import Foundation

/// Validates Shortcuts input before constructing a service or starting a listing scan.
/// Positive values retain existing behavior, including values larger than the result set.
struct RecentShortcutCount: Sendable {
    let value: Int

    init(_ value: Int) throws {
        guard value >= 0 else { throw RecentShortcutCountError.outOfRange }
        self.value = value
    }

    @MainActor
    func load<Element>(fetch: (Int) async throws -> [Element]) async throws -> [Element] {
        try Task.checkCancellation()
        guard value > 0 else { return [] }
        let elements = try await fetch(value)
        try Task.checkCancellation()
        return Array(elements.prefix(value))
    }
}

enum RecentShortcutCountError: LocalizedError, Equatable {
    case outOfRange

    var errorDescription: String? {
        "Count must be zero or greater."
    }
}

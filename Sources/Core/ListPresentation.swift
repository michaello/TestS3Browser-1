import Foundation

enum ListPresentation: Equatable {
    case initialLoading
    case initialFailure(String)
    case empty(refreshing: Bool, error: String?)
    case content(refreshing: Bool, error: String?)

    static func resolve(hasSnapshot: Bool, rowCount: Int, isLoading: Bool, error: String?) -> Self {
        if rowCount > 0 { return .content(refreshing: isLoading, error: error) }
        if !hasSnapshot {
            if let error { return .initialFailure(error) }
            return .initialLoading
        }
        return .empty(refreshing: isLoading, error: error)
    }
}

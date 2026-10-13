import Foundation
import Observation

@Observable @MainActor
final class DetailMetadataLoadState<Value: Sendable> {
    enum Phase: Equatable { case idle, loading, loaded, empty, failed(String) }
    private(set) var value: Value?
    private(set) var phase = Phase.idle
    private var request = UUID()
    var isLoading: Bool { phase == .loading }
    var error: String? { if case .failed(let message) = phase { message } else { nil } }

    func receive(_ value: Value?) {
        request = UUID()
        self.value = value
        phase = value == nil ? .empty : .loaded
    }

    func load(operation: () async throws -> Value?) async {
        let owned = UUID(); request = owned; phase = .loading
        defer {
            if request == owned, isLoading { phase = value == nil ? .idle : .loaded }
        }
        do {
            let result = try await operation()
            try Task.checkCancellation()
            guard request == owned else { return }
            value = result; phase = result == nil ? .empty : .loaded
        } catch {
            guard request == owned else { return }
            if !(error is CancellationError) { phase = .failed(error.localizedDescription) }
        }
    }
}

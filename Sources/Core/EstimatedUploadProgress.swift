import Foundation

/// Owns the estimated timer until the operation terminates, including errors and cancellation.
@MainActor
enum EstimatedUploadProgress {
    static func perform<Value>(
        byteCount: Int,
        progress: (@MainActor (Double) -> Void)?,
        tick: @escaping @MainActor () async throws -> Void = { try await Task.sleep(for: .milliseconds(100)) },
        operation: () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        guard let progress else { return try await operation() }
        let seconds = max(1.0, Double(byteCount) / 512_000.0)
        let timer = Task { @MainActor in
            var elapsed = 0.0
            do {
                while true {
                    try await tick()
                    // Even a timer boundary that ignores cancellation cannot deliver a late tick.
                    try Task.checkCancellation()
                    elapsed += 0.1
                    progress(min(0.9 * (1 - exp(-3 * elapsed / seconds)), 0.9))
                }
            } catch {
                // Timer termination is owned here; operation errors are returned separately.
            }
        }
        let result: Result<Value, any Error>
        do { result = .success(try await operation()) }
        catch { result = .failure(error) }
        timer.cancel()
        await timer.value
        let value = try result.get()
        progress(1)
        return value
    }
}

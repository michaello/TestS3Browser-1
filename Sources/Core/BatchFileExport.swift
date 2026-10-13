import Foundation
import Observation

struct BatchExportItem: Sendable {
    let identity: MediaObjectIdentity
    let bytes: Int64
    var filename: String { S3TransferKeys.fileName(of: identity.key) }
}

struct BatchExportFailure: Sendable {
    let item: BatchExportItem
    let message: String
}

private enum BatchExportOutcome: Sendable {
    case success(BatchExportItem, ExportFileLease)
    case failure(BatchExportFailure)
}

/// Owns the prepared share files until activity completion or explicit dismissal.
@MainActor @Observable
final class BatchFileExport {
    typealias Loader = @MainActor @Sendable (BatchExportItem) async throws -> OriginalFileLease
    typealias Releaser = @Sendable (OriginalFileLease) async -> Void
    private(set) var successes: [(BatchExportItem, ExportFileLease)] = []
    private(set) var failures: [BatchExportFailure] = []
    private(set) var completed = 0
    private(set) var total = 0
    private(set) var isPreparing = false
    @ObservationIgnored private let store: MediaExportStore
    @ObservationIgnored private let load: Loader
    @ObservationIgnored private let releaseOriginal: Releaser
    @ObservationIgnored private let limit: Int

    init(store: MediaExportStore = .shared, limit: Int = 4, load: @escaping Loader,
         releaseOriginal: @escaping Releaser = { await MediaOriginalStore.shared.release($0) }) {
        self.store = store
        self.limit = max(1, min(4, limit))
        self.load = load
        self.releaseOriginal = releaseOriginal
    }

    var urls: [URL] { successes.map { $0.1.url } }
    var summary: String {
        let count = successes.count + failures.count
        var message = "Downloaded \(successes.count) of \(count) files."
        if !failures.isEmpty {
            message += " Failed: " + failures.map { $0.item.filename + ": " + $0.message }.joined(separator: "; ")
            message += " Retry Failed retries only these files."
        }
        return message
    }

    func prepare(_ items: [BatchExportItem], keepingSuccesses: Bool = false) async throws {
        guard !isPreparing else { return }
        if !keepingSuccesses { await close() }
        failures = []
        completed = 0
        total = items.count
        isPreparing = true
        defer { isPreparing = false }
        let store = store, load = load, releaseOriginal = releaseOriginal
        var prepared: [(BatchExportItem, ExportFileLease)] = []
        var errors: [BatchExportFailure] = []
        await withTaskGroup(of: BatchExportOutcome.self) { group in
            var remaining = items.makeIterator()
            func enqueue(_ item: BatchExportItem) {
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        let original = try await load(item)
                        let staged: ExportFileLease
                        do { staged = try await store.stage(original) }
                        catch { await releaseOriginal(original); throw error }
                        await releaseOriginal(original)
                        if Task.isCancelled { await store.release(staged); throw CancellationError() }
                        return .success(item, staged)
                    } catch { return .failure(.init(item: item, message: error.localizedDescription)) }
                }
            }
            for _ in 0..<min(limit, items.count) { if let item = remaining.next() { enqueue(item) } }
            while let outcome = await group.next() {
                completed += 1
                switch outcome {
                case .success(let item, let lease): prepared.append((item, lease))
                case .failure(let failure): errors.append(failure)
                }
                if Task.isCancelled { group.cancelAll() }
                else if let item = remaining.next() { enqueue(item) }
            }
        }
        if Task.isCancelled {
            for (_, lease) in prepared { await store.release(lease) }
            throw CancellationError()
        }
        successes += prepared
        failures = errors
    }

    func retryFailures() async throws {
        try await prepare(failures.map(\.item), keepingSuccesses: true)
    }

    func close() async {
        let leases = successes.map { $0.1 }
        successes = []
        failures = []
        for lease in leases { await store.release(lease) }
    }

    isolated deinit {
        let leases = successes.map { $0.1 }, store = store
        Task { for lease in leases { await store.release(lease) } }
    }
}

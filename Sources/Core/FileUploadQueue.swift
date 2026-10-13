import Foundation
import Observation

enum UploadItemState {
    case pending
    case uploading(progress: Double)
    case done
    case failed(String)
    case cancelled
}

@MainActor @Observable
final class FileUploadJob: Identifiable {
    let id: UUID
    let filename: String
    let key: String
    let bucket: String
    let account: String
    let contentType: String
    let fileURL: URL
    let byteCount: Int64
    var state: UploadItemState = .pending
    var retryCount = 0
    var cancellationRequested = false
    var cleanupError: String?

    init(id: UUID, filename: String, key: String, bucket: String, account: String,
         contentType: String, fileURL: URL, byteCount: Int64) {
        self.id = id
        self.filename = filename
        self.key = key
        self.bucket = bucket
        self.account = account
        self.contentType = contentType
        self.fileURL = fileURL
        self.byteCount = byteCount
    }

    var isActive: Bool { if case .uploading = state { return true }; return false }
    var isPending: Bool { if case .pending = state { return true }; return false }
    var isDone: Bool { if case .done = state { return true }; return false }
    var isFailed: Bool { if case .failed = state { return true }; return false }
}

/// Queue payloads are owned files. Display names never become local filesystem paths.
actor UploadPayloadStore {
    let directory: URL
    init(directory: URL) { self.directory = directory }

    func stage(data: Data, id: UUID) throws -> (URL, Int64) {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(id.uuidString + ".upload")
        do {
            try data.write(to: url, options: .atomic)
            try Task.checkCancellation()
            return (url, Int64(data.count))
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func stage(file: URL, id: UUID) throws -> (URL, Int64) {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(id.uuidString + ".upload")
        do {
            try FileManager.default.copyItem(at: file, to: url)
            try Task.checkCancellation()
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            return (url, Int64(size))
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func remove(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

enum FileUploadQueueError: LocalizedError {
    case missingJob, failed(String)
    var errorDescription: String? {
        switch self {
        case .missingJob: "This upload is no longer in the queue."
        case .failed(let message): message
        }
    }
}

/// Serial work bounds uploads and remains owned after a producer view is dismissed.
@MainActor @Observable
final class FileUploadQueue {
    typealias Sender = @MainActor (FileUploadJob, @escaping @MainActor (Double) -> Void) async throws -> Void
    private(set) var items: [FileUploadJob] = []
    @ObservationIgnored private let store: UploadPayloadStore
    @ObservationIgnored private let send: Sender
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var active: (UUID, Task<Void, any Error>)?
    @ObservationIgnored private var waiters: [UUID: [CheckedContinuation<String, any Error>]] = [:]

    init(store: UploadPayloadStore, send: @escaping Sender) {
        self.store = store
        self.send = send
    }

    func enqueue(id: UUID = UUID(), filename: String, key: String, bucket: String,
                 account: String, contentType: String, data: Data) async throws -> FileUploadJob {
        let staged = try await store.stage(data: data, id: id)
        return try await append(id: id, filename: filename, key: key, bucket: bucket,
                                account: account, contentType: contentType, staged: staged)
    }

    func enqueue(id: UUID = UUID(), filename: String, key: String, bucket: String,
                 account: String, contentType: String, file: URL) async throws -> FileUploadJob {
        let staged = try await store.stage(file: file, id: id)
        return try await append(id: id, filename: filename, key: key, bucket: bucket,
                                account: account, contentType: contentType, staged: staged)
    }

    private func append(id: UUID, filename: String, key: String, bucket: String,
                        account: String, contentType: String, staged: (URL, Int64)) async throws -> FileUploadJob {
        do { try Task.checkCancellation() }
        catch { try await store.remove(staged.0); throw error }
        let job = FileUploadJob(id: id, filename: filename, key: key, bucket: bucket,
            account: account, contentType: contentType, fileURL: staged.0, byteCount: staged.1)
        items.append(job)
        start()
        return job
    }

    func waitForCompletion(id: UUID) async throws -> String {
        guard let item = items.first(where: { $0.id == id }) else { throw FileUploadQueueError.missingJob }
        switch item.state {
        case .done: return item.key
        case .failed(let error): throw FileUploadQueueError.failed(error)
        case .cancelled: throw CancellationError()
        case .pending, .uploading:
            return try await withCheckedThrowingContinuation { waiters[id, default: []].append($0) }
        }
    }

    func retry(id: UUID) {
        guard let item = items.first(where: { $0.id == id }), item.isFailed else { return }
        item.retryCount += 1
        item.cancellationRequested = false
        item.state = .pending
        start()
    }

    func cancel(id: UUID) async {
        guard let item = items.first(where: { $0.id == id }) else { return }
        if item.isActive {
            item.cancellationRequested = true
            active?.1.cancel()
        } else if item.isPending || item.isFailed {
            item.state = .cancelled
            await clean(item)
            finish(item, result: .failure(CancellationError()))
        }
    }

    func removeCompleted() async {
        for item in items where item.isDone { await clean(item) }
        items.removeAll { $0.isDone && $0.cleanupError == nil }
    }

    private func start() {
        guard worker == nil else { return }
        worker = Task { await drain() }
    }

    private func drain() async {
        while let item = items.first(where: \.isPending) {
            item.state = .uploading(progress: 0)
            let operation = Task { @MainActor in
                try Task.checkCancellation()
                try await send(item) { fraction in
                    guard item.isActive else { return }
                    item.state = .uploading(progress: fraction)
                }
            }
            active = (item.id, operation)
            do {
                try await operation.value
                // A successful remote response remains success even after a late cancel request.
                item.state = .done
                await clean(item)
                finish(item, result: .success(item.key))
            } catch is CancellationError {
                item.state = .cancelled
                await clean(item)
                finish(item, result: .failure(CancellationError()))
            } catch {
                item.state = .failed(error.localizedDescription)
                finish(item, result: .failure(error))
            }
            active = nil
        }
        worker = nil
    }

    private func clean(_ item: FileUploadJob) async {
        do { try await store.remove(item.fileURL); item.cleanupError = nil }
        catch { item.cleanupError = error.localizedDescription }
    }

    private func finish(_ item: FileUploadJob, result: Result<String, any Error>) {
        for waiter in waiters.removeValue(forKey: item.id) ?? [] { waiter.resume(with: result) }
    }
}

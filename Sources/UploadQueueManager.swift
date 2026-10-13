import SwiftUI
import os.log

typealias UploadItem = FileUploadJob

/// App adapter keeps credentials in memory and sends only file-backed, captured jobs.
@MainActor @Observable
final class UploadQueueManager {
    static let shared = UploadQueueManager()
    @ObservationIgnored private var services: [UUID: S3Service] = [:]
    @ObservationIgnored private var configurations: [UUID: UploadContext] = [:]
    @ObservationIgnored private var callbacks: [UUID: @MainActor (Double) -> Void] = [:]
    @ObservationIgnored private lazy var queue = FileUploadQueue(
        store: UploadPayloadStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("s3-upload-queue"))
    ) { [weak self] job, progress in
        guard let self, let service = self.services[job.id], let configuration = self.configurations[job.id] else {
            throw FileUploadQueueError.failed("The upload's captured configuration is unavailable.")
        }
        try await service.uploadFileObject(file: job.fileURL, key: job.key, contentType: job.contentType,
            bucket: job.bucket, expectedConfig: configuration.configuration, expectedGeneration: configuration.generation, onProgress: { fraction in
                progress(fraction)
                self.callbacks[job.id]?(fraction)
            })
        self.forget(job.id)
    }

    var items: [UploadItem] { queue.items }
    var pendingCount: Int { items.filter(\.isPending).count }
    var activeCount: Int { items.filter(\.isActive).count }
    var failedCount: Int { items.filter(\.isFailed).count }
    var busyCount: Int { pendingCount + activeCount }

    @discardableResult
    func upload(_ payload: PreparedUploadPayload, key: String, context: UploadContext,
                using service: S3Service, onProgress: (@MainActor (Double) -> Void)? = nil) async throws -> String {
        switch payload.body {
        case .data(let data):
            try await upload(data: data, filename: payload.filename, key: key, contentType: payload.contentType,
                context: context, using: service, onProgress: onProgress)
        case .file(let file):
            try await upload(file: file, filename: payload.filename, key: key, contentType: payload.contentType,
                context: context, using: service, onProgress: onProgress)
        }
    }

    @discardableResult
    func upload(data: Data, filename: String, key: String, contentType: String,
                context: UploadContext, using service: S3Service,
                onProgress: (@MainActor (Double) -> Void)? = nil) async throws -> String {
        try await enqueueAndWait(context: context, using: service, onProgress: onProgress) { id in
            try await queue.enqueue(id: id, filename: filename, key: key, bucket: context.destination.bucket,
                account: context.destination.account, contentType: contentType, data: data)
        }
    }

    @discardableResult
    func upload(file: URL, filename: String, key: String, contentType: String,
                context: UploadContext, using service: S3Service,
                onProgress: (@MainActor (Double) -> Void)? = nil) async throws -> String {
        try await enqueueAndWait(context: context, using: service, onProgress: onProgress) { id in
            try await queue.enqueue(id: id, filename: filename, key: key, bucket: context.destination.bucket,
                account: context.destination.account, contentType: contentType, file: file)
        }
    }

    private func enqueueAndWait(context: UploadContext, using service: S3Service,
        onProgress: (@MainActor (Double) -> Void)?,
        stage: (UUID) async throws -> FileUploadJob) async throws -> String {
        try Task.checkCancellation()
        guard context.matches(service) else { throw UploadPreparationError.accountChanged }
        let id = UUID()
        services[id] = service
        configurations[id] = context
        callbacks[id] = onProgress
        do {
            let job = try await stage(id)
            let key = try await queue.waitForCompletion(id: job.id)
            forget(id)
            return key
        } catch {
            callbacks.removeValue(forKey: id)
            if !items.contains(where: { $0.id == id && $0.isFailed }) { forget(id) }
            throw error
        }
    }

    func retry(id: UUID) { queue.retry(id: id) }

    func cancel(id: UUID) async {
        await queue.cancel(id: id)
        forget(id)
    }

    func removeCompleted() async { await queue.removeCompleted() }

    private func forget(_ id: UUID) {
        callbacks.removeValue(forKey: id)
        services.removeValue(forKey: id)
        configurations.removeValue(forKey: id)
    }
}

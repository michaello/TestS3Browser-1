import SwiftUI
import os.log

enum UploadItemState {
    case pending
    case uploading(progress: Double)
    case done
    case failed(String)
}

@Observable
final class UploadItem: Identifiable {
    let id: UUID
    let filename: String
    let key: String
    let bucket: String
    let contentType: String
    let data: Data
    var state: UploadItemState
    var retryCount: Int

    init(filename: String, key: String, bucket: String, contentType: String, data: Data) {
        self.id = UUID()
        self.filename = filename
        self.key = key
        self.bucket = bucket
        self.contentType = contentType
        self.data = data
        self.state = .pending
        self.retryCount = 0
    }

    var isActive: Bool {
        if case .uploading = state { return true }
        return false
    }

    var isPending: Bool {
        if case .pending = state { return true }
        return false
    }

    var isDone: Bool {
        if case .done = state { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }
}

@Observable
final class UploadQueueManager {
    static let shared = UploadQueueManager()

    private let logger = Logger(subsystem: "com.s3browser", category: "UploadQueueManager")

    var items: [UploadItem] = []
    private var s3Service: S3Service?
    private var isProcessing = false

    var pendingCount: Int { items.filter(\.isPending).count }
    var activeCount: Int { items.filter(\.isActive).count }
    var failedCount: Int { items.filter(\.isFailed).count }
    var busyCount: Int { pendingCount + activeCount }

    func configure(s3Service: S3Service) {
        self.s3Service = s3Service
    }

    func enqueue(filename: String, key: String, bucket: String, contentType: String, data: Data) {
        let item = UploadItem(filename: filename, key: key, bucket: bucket, contentType: contentType, data: data)
        items.append(item)
        logger.info("Enqueued \(filename) -> \(bucket)/\(key)")
        Task { await processNext() }
    }

    func retry(id: UUID) {
        guard let item = items.first(where: { $0.id == id }), item.isFailed else { return }
        item.state = .pending
        item.retryCount += 1
        logger.info("Retrying \(item.filename) (attempt \(item.retryCount + 1))")
        Task { await processNext() }
    }

    func removeCompleted() {
        items.removeAll(where: \.isDone)
    }

    @MainActor
    private func processNext() async {
        guard !isProcessing, let service = s3Service else { return }
        guard let item = items.first(where: \.isPending) else { return }

        isProcessing = true
        item.state = .uploading(progress: 0)

        do {
            try await service.uploadObject(
                data: item.data,
                key: item.key,
                contentType: item.contentType,
                onProgress: { [weak item] fraction in
                    item?.state = .uploading(progress: fraction)
                }
            )
            item.state = .done
            logger.info("Queue item done: \(item.filename)")
        } catch {
            item.state = .failed(error.localizedDescription)
            logger.error("Queue item failed: \(item.filename): \(error.localizedDescription)")
        }

        isProcessing = false
        await processNext()
    }
}

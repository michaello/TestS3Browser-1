import AVFoundation
import CoreGraphics
import Foundation

/// AVURLAsset retains HTTP range support; poster generation never asks the original-file loader
/// to materialize a movie. The common permit bounds concurrent app-owned asset operations.
actor VideoPosterRenderer {
    static let shared = VideoPosterRenderer()
    private var generators: [UUID: AVAssetImageGenerator] = [:]
    private var continuations: [UUID: CheckedContinuation<CGImage, Error>] = [:]
    func image(at url: URL, maximumPixels: Int) async throws -> CGImage {
        let id = UUID()
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maximumPixels, height: maximumPixels)
        generators[id] = generator
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            // The async overlay sends its non-Sendable generator to another executor. Keep
            // generator configuration/cancellation on this actor and bridge the SDK callback.
            return try await withCheckedThrowingContinuation { continuation in
                continuations[id] = continuation
                generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: .zero)]) { _, image, _, _, error in
                    Task { await self.complete(id, image: image, error: error) }
                }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func complete(_ id: UUID, image: CGImage?, error: (any Error)?) {
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        generators.removeValue(forKey: id)
        if let error { continuation.resume(throwing: error) }
        else if let image { continuation.resume(returning: image) }
        else { continuation.resume(throwing: MediaTransferError.missingBody) }
    }
    private func cancel(_ id: UUID) {
        generators.removeValue(forKey: id)?.cancelAllCGImageGeneration()
        continuations.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

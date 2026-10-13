import UIKit
import Foundation
import AVFoundation

/// All variants share one byte-accounted LRU. Originals live in the reusable file store.
@globalActor
actor ImageCacheActor {
    static let shared = ImageCacheActor()
    private struct ImageKey: Hashable { let object: MediaObjectIdentity; let pixels: Int }
    private var decoded = ByteCostLRU<ImageKey, UIImage>(limit: MediaLimits().decodedBytes)
    private var epochs = MediaCacheEpoch()

    func getThumbnail(for identity: MediaObjectIdentity) -> UIImage? {
        decoded.value(for: ImageKey(object: identity, pixels: 360))
    }
    func getFullImage(for identity: MediaObjectIdentity) -> UIImage? {
        decoded.value(for: ImageKey(object: identity, pixels: 2_048))
    }
    func loadThumbnail(for object: S3Object, using service: S3Service) async -> UIImage? {
        await load(object, using: service, pixels: 360)
    }
    func loadDisplayImage(for object: S3Object, using service: S3Service) async -> UIImage? {
        await load(object, using: service, pixels: 2_048)
    }
    private func load(_ object: S3Object, using service: S3Service, pixels: Int) async -> UIImage? {
        let (identity, serviceGeneration) = await MainActor.run { (service.mediaIdentity(for: object), service.session.generation) }
        let ticket = epochs.begin(identity)
        defer { epochs.finish(ticket) }
        var cacheKey = ImageKey(object: identity, pixels: pixels)
        if identity.etag != nil, let cached = decoded.value(for: cacheKey) { return cached }
        do {
            let image: UIImage?
            if object.fileType == .video {
                // AVURLAsset issues range requests; rendering one poster never downloads the
                // entire movie through downloadObject. Hold the common body permit while it works.
                guard let url = await MainActor.run(body: { service.generatePresignedURL(for: object.key, bucket: identity.bucket).flatMap(URL.init(string:)) }) else { return nil }
                image = try await BodyTransferLimiter.shared.withPermit {
                    let cgImage = try await VideoPosterRenderer.shared.image(at: url, maximumPixels: pixels)
                    return UIImage(cgImage: cgImage)
                }
            } else {
                guard object.fileType == .image else { return nil }
                let lease = try await service.downloadOriginalFile(for: object)
                cacheKey = ImageKey(object: lease.identity, pixels: pixels)
                if let cached = decoded.value(for: cacheKey) {
                    await MediaOriginalStore.shared.release(lease)
                    guard epochs.isCurrent(ticket),
                          await MainActor.run(body: { service.session.isCurrent(serviceGeneration) }) else { return nil }
                    return cached
                }
                let cgImage = ImageDownsampling.image(at: lease.url, maximumPixelSize: pixels,
                    byteLimit: pixels == 360 ? 2 * 1024 * 1024 : MediaLimits().displayImageBytes)
                image = cgImage.map { UIImage(cgImage: $0) }
                await MediaOriginalStore.shared.release(lease)
            }
            try Task.checkCancellation()
            guard epochs.isCurrent(ticket),
                  await MainActor.run(body: { service.session.isCurrent(serviceGeneration) }) else { return nil }
            if let image, let cgImage = image.cgImage {
                _ = epochs.publish(ticket, into: &decoded, key: cacheKey, value: image, cost: cgImage.bytesPerRow * cgImage.height)
            }
            return image
        } catch { return nil }
    }
    func invalidate(account: String, bucket: String, key: String) {
        // Cancelled original transfers cannot repopulate a removed decoded generation.
        epochs.invalidate(account: account, bucket: bucket, key: key)
        for entry in decoded.keys where entry.object.matches(account: account, bucket: bucket, key: key) { decoded.remove(entry) }
    }
    func clearCache() async {
        epochs.reset()
        decoded.removeAll()
        try? await MediaOriginalStore.shared.clear()
    }
    func clearDiskCache() async { try? await MediaOriginalStore.shared.clear() }
    func diskCacheSize() async -> Int64 { await MediaOriginalStore.shared.cachedBytes }

}

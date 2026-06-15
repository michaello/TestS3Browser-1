import SwiftUI
import AVFoundation
import os.log

/// Grid-mode card for a recent file, with a thumbnail for image/video and metadata badges.
struct RecentFileGridItem: View {
    let object: S3Object
    let s3Service: S3Service
    let cardSize: Double
    var isNew: Bool = false
    @State private var thumbnail: UIImage?

    private let logger = Logger(subsystem: "com.s3browser", category: "RecentFileGridItem")

    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            ZStack {
                if let thumbnail = thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: cardSize)
                        .frame(height: cardSize)
                } else {
                    VStack {
                        Image(systemName: object.fileType.icon)
                            .font(.system(size: cardSize > 100 ? 24 : 16))
                            .foregroundStyle(iconColor)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(height: cardSize)
                }

                // Video play badge
                if object.fileType == .video {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: cardSize > 100 ? 28 : 20))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 3)
                }

                // Top-left badges (Recent, New)
                if object.lastModified.isRecent || isNew {
                    VStack {
                        HStack(spacing: 4) {
                            if object.lastModified.isRecent {
                                Text("Recent")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(.green, in: Capsule())
                            }
                            if isNew {
                                Text("New")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(.orange, in: Capsule())
                            }
                            Spacer()
                        }
                        .padding(4)
                        Spacer()
                    }
                }
            }
            .frame(height: cardSize)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(8)

            VStack(alignment: .center, spacing: 2) {
                Text(object.fileName)
                    .font(cardSize > 100 ? .caption : .system(size: 10))
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                Text("\(object.formattedSize) · \(object.lastModified.relativeFormattedCompact())")
                    .font(.system(size: cardSize > 100 ? 10 : 8))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .task {
            await loadThumbnail()
        }
    }

    private var iconColor: Color {
        switch object.fileType {
        case .log: return .blue
        case .image: return .purple
        case .video: return .orange
        case .text: return .green
        case .html: return .teal
        case .unknown: return .gray
        }
    }

    private func loadThumbnail() async {
        guard object.fileType == .image || object.fileType == .video else { return }

        // Check cache first
        if let cached = await ImageCacheActor.shared.getThumbnail(for: object.key) {
            await MainActor.run { self.thumbnail = cached }
            return
        }

        do {
            if object.fileType == .image {
                let data = try await s3Service.downloadObject(key: object.key, bucket: object.bucket)
                let image = await ImageCacheActor.shared.cacheImage(from: data, for: object.key)
                if let image = image {
                    await MainActor.run { self.thumbnail = image }
                }
            } else {
                // Video: download to temp file, extract first frame. Use a unique temp name so
                // two cards (or list and grid both alive during a mode switch) that share a
                // fileName cannot write or delete the same path and corrupt each other's data.
                let data = try await s3Service.downloadObject(key: object.key, bucket: object.bucket)
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + "-" + object.fileName)
                try data.write(to: tempURL)
                if let frame = await extractVideoThumbnail(from: tempURL) {
                    await ImageCacheActor.shared.cacheThumbnail(frame, for: object.key)
                    await MainActor.run { self.thumbnail = frame }
                }
                try? FileManager.default.removeItem(at: tempURL)
            }
        } catch {
            logger.error("Failed to load thumbnail for \(object.key): \(error.localizedDescription)")
        }
    }

    private func extractVideoThumbnail(from url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 120, height: 120)
        do {
            let (cgImage, _) = try await generator.image(at: .zero)
            return UIImage(cgImage: cgImage)
        } catch {
            logger.error("Failed to extract video thumbnail: \(error.localizedDescription)")
            return nil
        }
    }
}

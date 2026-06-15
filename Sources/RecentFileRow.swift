import SwiftUI
import AVFoundation
import os.log

/// List-mode row for a recent file, with a thumbnail for image/video and metadata badges.
struct RecentFileRow: View {
    let object: S3Object
    let s3Service: S3Service
    var isNew: Bool = false
    @State private var thumbnail: UIImage?

    private let logger = Logger(subsystem: "com.s3browser", category: "RecentFileRow")

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                ZStack {
                    if let thumbnail = thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 40, height: 40)
                            .background(Color.gray.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        Image(systemName: object.fileType.icon)
                            .font(.title3)
                            .foregroundStyle(iconColor)
                            .frame(width: 40, height: 40)
                    }

                    // Video play badge
                    if object.fileType == .video {
                        Image(systemName: "play.circle.fill")
                            .font(.body)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.5), radius: 2)
                    }
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(object.fileName)
                            .font(.headline)
                            .lineLimit(1)

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

                        if object.key.hasPrefix("dump/") {
                            Text("Uploaded")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.blue, in: Capsule())
                        }
                    }

                    HStack(spacing: 8) {
                        Text(object.formattedSize)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text(object.lastModified.relativeFormattedCompact())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }

            // Show bucket and full path
            Text(object.bucket.map { "\($0)/\(object.key)" } ?? object.key)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .padding(.vertical, 4)
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
                // two rows (or list and grid both alive during a mode switch) that share a
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

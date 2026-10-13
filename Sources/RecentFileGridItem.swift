import SwiftUI
import AVFoundation
import os.log

/// Grid-mode card for a recent file, with a thumbnail for image/video and metadata badges.
struct RecentFileGridItem: View {
    let object: S3Object
    let s3Service: S3Service
    let cardSize: Double
    var isNew: Bool = false
    var tag: String? = nil
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

                if let tag {
                    TagChip(tag: tag)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .task(id: s3Service.mediaIdentity(for: object).digest) {
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
        thumbnail = nil
        let generation = s3Service.session.generation
        let image = await ImageCacheActor.shared.loadThumbnail(for: object, using: s3Service)
        guard !Task.isCancelled, s3Service.session.isCurrent(generation) else { return }
        thumbnail = image
    }
}

import SwiftUI
import AVFoundation
import os.log

/// List-mode row for a recent file, with a thumbnail for image/video and metadata badges.
struct RecentFileRow: View {
    let object: S3Object
    let s3Service: S3Service
    var isNew: Bool = false
    var tag: String? = nil
    @State private var thumbnail: UIImage?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
                    (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 6))) {
                        Text(object.fileName)
                            .font(.headline)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                            .fixedSize(horizontal: false, vertical: true)

                        if object.lastModified.isRecent {
                            Text("Recent")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.green, in: Capsule())
                        }

                        if isNew {
                            Text("New")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.orange, in: Capsule())
                        }

                        if object.key.hasPrefix("dump/") {
                            Text("Uploaded")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.blue, in: Capsule())
                        }

                        if let tag {
                            TagChip(tag: tag)
                        }
                    }

                    (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 8))) {
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
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
                .truncationMode(.middle)
        }
        .padding(.vertical, 4)
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

import SwiftUI
import os.log

/// Displays the most recent files from the current bucket
struct RecentFilesView: View {
    private let logger = Logger(subsystem: "com.s3browser", category: "RecentFilesView")
    @Environment(\.scenePhase) private var scenePhase
    let config: S3Config
    let s3Service: S3Service

    var body: some View {
        NavigationStack {
            Group {
                if !isConfigured {
                    ContentUnavailableView(
                        "Configuration Required",
                        systemImage: "gear",
                        description: Text("Go to Settings to configure your S3 bucket and credentials")
                    )
                } else if s3Service.recentFiles.isEmpty && !s3Service.isLoading {
                    ContentUnavailableView(
                        "No Files",
                        systemImage: "doc",
                        description: Text("No files found in bucket")
                    )
                } else {
                    List {
                        ForEach(s3Service.recentFiles) { file in
                            NavigationLink(destination: FileDetailView(object: file, service: s3Service)) {
                                RecentFileRow(object: file, s3Service: s3Service)
                            }
                        }
                    }
                    .refreshable {
                        await refreshRecentFiles()
                    }
                }
            }
            .navigationTitle("Recent Files")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if s3Service.isLoading {
                        ProgressView()
                    }
                }
            }
        }
        .task {
            if isConfigured {
                await refreshRecentFiles()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active, isConfigured else { return }
            Task {
                await refreshRecentFiles()
            }
        }
        .onChange(of: s3Service.currentBucket) { _, _ in
            Task {
                await refreshRecentFiles()
            }
        }
    }

    private var isConfigured: Bool {
        !config.bucketName.isEmpty && !config.accessKey.isEmpty && !config.secretKey.isEmpty
    }

    private func refreshRecentFiles() async {
        do {
            try await s3Service.fetchRecentFiles(limit: 10)
        } catch {
            logger.error("Failed to fetch recent files: \(error.localizedDescription)")
        }
    }
}

struct RecentFileRow: View {
    let object: S3Object
    let s3Service: S3Service
    @State private var thumbnail: UIImage?

    private let logger = Logger(subsystem: "com.s3browser", category: "RecentFileRow")

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                if let thumbnail = thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: object.fileType.icon)
                        .font(.title3)
                        .foregroundStyle(iconColor)
                        .frame(width: 40, height: 40)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(object.fileName)
                        .font(.headline)
                        .lineLimit(1)

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

            // Show the full path
            Text(object.key)
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
        case .text: return .green
        case .unknown: return .gray
        }
    }

    private func loadThumbnail() async {
        guard object.fileType == .image else { return }

        // Check cache first
        if let cached = await ImageCacheActor.shared.getThumbnail(for: object.key) {
            await MainActor.run {
                self.thumbnail = cached
            }
            return
        }

        // If not cached, download the image and cache it
        do {
            let data = try await s3Service.downloadObject(key: object.key)
            let image = await ImageCacheActor.shared.cacheImage(from: data, for: object.key)
            if let image = image {
                await MainActor.run {
                    self.thumbnail = image
                }
            }
        } catch {
            logger.error("Failed to load thumbnail for \(object.key): \(error.localizedDescription)")
        }
    }
}

#Preview {
    RecentFilesView(config: S3Config.default, s3Service: S3Service(config: S3Config.default))
}

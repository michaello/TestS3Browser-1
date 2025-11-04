import SwiftUI

enum SortOption: String, CaseIterable {
    case dateNewest = "Date (Newest)"
    case dateOldest = "Date (Oldest)"
    case nameAZ = "Name (A-Z)"
    case nameZA = "Name (Z-A)"
    case sizeDescending = "Size (Largest)"
    case sizeAscending = "Size (Smallest)"
}

enum ViewStyle {
    case standard
    case compact
}

struct BucketBrowserView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var s3Service: S3Service
    @Binding var config: S3Config
    @State private var sortOption: SortOption = .dateNewest
    @State private var viewStyle: ViewStyle = .standard
    @State private var showingSortMenu = false

    init(config: Binding<S3Config>) {
        self._config = config
        self._s3Service = State(initialValue: S3Service(config: config.wrappedValue))
    }

    var body: some View {
        NavigationStack {
            Group {
                if !isConfigured {
                    ContentUnavailableView(
                        "Configuration Required",
                        systemImage: "gear",
                        description: Text("Go to Settings to configure your S3 bucket and credentials")
                    )
                } else if s3Service.objects.isEmpty && !s3Service.isLoading {
                    ContentUnavailableView(
                        "No Files",
                        systemImage: "doc",
                        description: Text("No files found in bucket. Pull to refresh.")
                    )
                } else {
                    List {
                        ForEach(sortedObjects) { object in
                            NavigationLink(destination: FileDetailView(object: object, service: s3Service)) {
                                if viewStyle == .standard {
                                    FileRow(object: object)
                                } else {
                                    CompactFileRow(object: object)
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    Task {
                                        await deleteObject(object)
                                    }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                if object.fileType == .image || object.fileType == .text || object.fileType == .log {
                                    Button {
                                        Task {
                                            await copyToClipboard(object)
                                        }
                                    } label: {
                                        Label("Copy Content", systemImage: "doc.on.doc")
                                    }
                                }

                                Button(role: .destructive) {
                                    Task {
                                        await deleteObject(object)
                                    }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .refreshable {
                        await refreshFiles()
                    }
                }
            }
            .navigationTitle("S3 Browser")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if s3Service.isLoading {
                        ProgressView()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Section("Sort By") {
                            Picker("Sort", selection: $sortOption) {
                                ForEach(SortOption.allCases, id: \.self) { option in
                                    Text(option.rawValue).tag(option)
                                }
                            }
                        }

                        Section("View Style") {
                            Button {
                                viewStyle = .standard
                            } label: {
                                Label("Standard", systemImage: viewStyle == .standard ? "checkmark" : "")
                            }

                            Button {
                                viewStyle = .compact
                            } label: {
                                Label("Compact", systemImage: viewStyle == .compact ? "checkmark" : "")
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .task {
                if isConfigured {
                    await refreshFiles()
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active, isConfigured else { return }
                Task {
                    await refreshFiles()
                }
            }
            .onChange(of: config) { _, newConfig in
                Task {
                    try? await s3Service.updateConfig(newConfig)
                    await refreshFiles()
                }
            }
        }
    }

    private var sortedObjects: [S3Object] {
        switch sortOption {
        case .dateNewest:
            return s3Service.objects.sorted { $0.lastModified > $1.lastModified }
        case .dateOldest:
            return s3Service.objects.sorted { $0.lastModified < $1.lastModified }
        case .nameAZ:
            return s3Service.objects.sorted { $0.fileName.localizedCaseInsensitiveCompare($1.fileName) == .orderedAscending }
        case .nameZA:
            return s3Service.objects.sorted { $0.fileName.localizedCaseInsensitiveCompare($1.fileName) == .orderedDescending }
        case .sizeDescending:
            return s3Service.objects.sorted { $0.size > $1.size }
        case .sizeAscending:
            return s3Service.objects.sorted { $0.size < $1.size }
        }
    }

    private var isConfigured: Bool {
        !config.bucketName.isEmpty && !config.accessKey.isEmpty && !config.secretKey.isEmpty
    }

    private func refreshFiles() async {
        guard !s3Service.isLoading else { return }
        do {
            try await s3Service.listObjects()
        } catch {
            print("[BucketBrowserView:143] Failed to list objects: \(error)")
        }
    }

    private func deleteObject(_ object: S3Object) async {
        do {
            try await s3Service.deleteObject(key: object.key)
            await refreshFiles()
        } catch {
            print("[BucketBrowserView:152] Failed to delete object: \(error)")
        }
    }

    private func copyToClipboard(_ object: S3Object) async {
        do {
            switch object.fileType {
            case .text, .log:
                let data = try await s3Service.downloadObject(key: object.key)
                if let text = String(data: data, encoding: .utf8) {
                    await MainActor.run {
                        UIPasteboard.general.string = text
                    }
                }
            case .image:
                // Try cache first
                var image = await ImageCacheActor.shared.getFullImage(for: object.key)

                // If not in cache, download it
                if image == nil {
                    let data = try await s3Service.downloadObject(key: object.key)
                    image = await ImageCacheActor.shared.cacheImage(from: data, for: object.key)
                }

                if let image = image {
                    await MainActor.run {
                        // Set both image and PNG data for better compatibility
                        UIPasteboard.general.image = image
                        if let pngData = image.pngData() {
                            UIPasteboard.general.setData(pngData, forPasteboardType: "public.png")
                        }
                    }
                }
            case .unknown:
                let data = try await s3Service.downloadObject(key: object.key)
                if let text = String(data: data, encoding: .utf8) {
                    await MainActor.run {
                        UIPasteboard.general.string = text
                    }
                }
            }
        } catch {
            print("[BucketBrowserView:175] Failed to copy content: \(error)")
        }
    }
}

struct FileRow: View {
    let object: S3Object
    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            if let thumbnail = thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 50, height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 0.5)
                    )
            } else {
                Image(systemName: object.fileType.icon)
                    .font(.title3)
                    .foregroundStyle(iconColor)
                    .frame(width: 50, height: 50)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(object.fileName)
                    .font(.headline)
                    .lineLimit(2)

                HStack(spacing: 12) {
                    Text(object.formattedSize)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(object.lastModified.relativeFormattedCompact())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
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
        // Only load thumbnails for images
        guard object.fileType == .image else { return }

        // Check cache first
        if let cached = await ImageCacheActor.shared.getThumbnail(for: object.key) {
            await MainActor.run {
                self.thumbnail = cached
            }
        }
    }
}

struct CompactFileRow: View {
    let object: S3Object

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: object.fileType.icon)
                .font(.caption)
                .foregroundStyle(iconColor)
                .frame(width: 20)

            Text(object.fileName)
                .font(.subheadline)
                .lineLimit(1)

            Spacer()

            Text(object.formattedSize)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var iconColor: Color {
        switch object.fileType {
        case .log: return .blue
        case .image: return .purple
        case .text: return .green
        case .unknown: return .gray
        }
    }
}

#Preview {
    BucketBrowserView(config: .constant(S3Config.default))
}

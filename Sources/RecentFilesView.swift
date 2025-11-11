import SwiftUI
import os.log

/// Displays the most recent files from the current bucket
struct RecentFilesView: View {
    private let logger = Logger(subsystem: "com.s3browser", category: "RecentFilesView")
    @Environment(\.scenePhase) private var scenePhase
    let config: S3Config
    let s3Service: S3Service
    @AppStorage("s3CurrentBucket") private var savedBucket: String = ""
    @AppStorage("s3RecentViewMode") private var viewModeRaw: String = "list"
    @AppStorage("s3RecentGridCardSize") private var gridCardSize: Double = 100
    @AppStorage("s3RecentFileTypeFilter") private var fileTypeFilterRaw: Int = FileTypeFilter.all.rawValue

    enum ViewMode {
        case list
        case grid
    }

    private var viewMode: ViewMode {
        get { viewModeRaw == "grid" ? .grid : .list }
        set { viewModeRaw = newValue == .grid ? "grid" : "list" }
    }

    private var fileTypeFilter: FileTypeFilter {
        get { FileTypeFilter(rawValue: fileTypeFilterRaw) }
        set { fileTypeFilterRaw = newValue.rawValue }
    }

    private var filteredRecentFiles: [S3Object] {
        guard fileTypeFilter != .all else { return s3Service.recentFiles }
        return s3Service.recentFiles.filter { fileTypeFilter.matches($0.fileType) }
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
                } else if s3Service.recentFiles.isEmpty && !s3Service.isLoading {
                    ContentUnavailableView(
                        "No Files",
                        systemImage: "doc",
                        description: Text("No files found in bucket")
                    )
                } else if filteredRecentFiles.isEmpty && !s3Service.isLoading {
                    ContentUnavailableView(
                        "No Matching Files",
                        systemImage: "doc",
                        description: Text("No files match the selected filter")
                    )
                } else {
                    if viewMode == .list {
                        List {
                            ForEach(filteredRecentFiles) { file in
                                NavigationLink(destination: FileDetailView(object: file, service: s3Service)) {
                                    RecentFileRow(object: file, s3Service: s3Service)
                                }
                            }
                        }
                        .refreshable {
                            await refreshRecentFiles()
                        }
                    } else {
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: gridCardSize), spacing: 12)], spacing: 12) {
                                ForEach(filteredRecentFiles) { file in
                                    NavigationLink(destination: FileDetailView(object: file, service: s3Service)) {
                                        RecentFileGridItem(object: file, s3Service: s3Service, cardSize: gridCardSize)
                                    }
                                }
                            }
                            .padding()
                        }
                        .refreshable {
                            await refreshRecentFiles()
                        }
                    }
                }
            }
            .navigationTitle("Recent Files")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    BucketPickerView(
                        currentBucket: s3Service.currentBucket,
                        availableBuckets: s3Service.availableBuckets,
                        isLoading: s3Service.isLoading,
                        onSelectBucket: { bucket in
                            Task {
                                do {
                                    try await s3Service.switchBucket(bucket)
                                    savedBucket = bucket
                                } catch {
                                    logger.error("Failed to switch bucket: \(error.localizedDescription)")
                                }
                            }
                        }
                    )
                }

                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 8) {
                        if viewMode == .grid {
                            Slider(value: $gridCardSize, in: 60...160, step: 10)
                                .frame(width: 100)
                        }

                        Menu {
                            Section("Filter by Type") {
                                Toggle("Images", isOn: Binding(
                                    get: { fileTypeFilter.contains(.image) },
                                    set: { isOn in
                                        var updated = fileTypeFilter
                                        if isOn { updated.insert(.image) } else { updated.remove(.image) }
                                        fileTypeFilterRaw = updated.rawValue
                                    }
                                ))

                                Toggle("Text", isOn: Binding(
                                    get: { fileTypeFilter.contains(.text) },
                                    set: { isOn in
                                        var updated = fileTypeFilter
                                        if isOn { updated.insert(.text) } else { updated.remove(.text) }
                                        fileTypeFilterRaw = updated.rawValue
                                    }
                                ))

                                Toggle("Logs", isOn: Binding(
                                    get: { fileTypeFilter.contains(.log) },
                                    set: { isOn in
                                        var updated = fileTypeFilter
                                        if isOn { updated.insert(.log) } else { updated.remove(.log) }
                                        fileTypeFilterRaw = updated.rawValue
                                    }
                                ))

                                Toggle("Other", isOn: Binding(
                                    get: { fileTypeFilter.contains(.unknown) },
                                    set: { isOn in
                                        var updated = fileTypeFilter
                                        if isOn { updated.insert(.unknown) } else { updated.remove(.unknown) }
                                        fileTypeFilterRaw = updated.rawValue
                                    }
                                ))

                                Divider()

                                Button {
                                    fileTypeFilterRaw = FileTypeFilter.all.rawValue
                                } label: {
                                    Label("Show All", systemImage: "")
                                }
                            }
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                        }

                        Picker("View Mode", selection: $viewModeRaw) {
                            Image(systemName: "list.bullet").tag("list")
                            Image(systemName: "square.grid.2x2").tag("grid")
                        }
                        .pickerStyle(.segmented)

                        if s3Service.isLoading {
                            ProgressView()
                        }
                    }
                }
            }
        }
        .task {
            if isConfigured {
                // Fetch available buckets
                do {
                    try await s3Service.fetchAvailableBuckets()
                } catch {
                    logger.error("Failed to fetch buckets: \(error.localizedDescription)")
                }

                // Restore saved bucket if available
                if !savedBucket.isEmpty {
                    do {
                        try await s3Service.switchBucket(savedBucket)
                    } catch {
                        logger.error("Failed to switch to saved bucket: \(error.localizedDescription)")
                    }
                } else {
                    s3Service.currentBucket = config.bucketName
                }

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
        .onChange(of: config) { _, newConfig in
            Task {
                try? await s3Service.updateConfig(newConfig)
                savedBucket = ""
                s3Service.currentBucket = newConfig.bucketName

                // Fetch buckets again with new credentials
                do {
                    try await s3Service.fetchAvailableBuckets()
                } catch {
                    logger.error("Failed to fetch buckets: \(error.localizedDescription)")
                }

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

/// Grid item component for grid view display
struct RecentFileGridItem: View {
    let object: S3Object
    let s3Service: S3Service
    let cardSize: Double
    @State private var thumbnail: UIImage?

    private let logger = Logger(subsystem: "com.s3browser", category: "RecentFileGridItem")

    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                if let thumbnail = thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(height: cardSize)
                        .clipped()
                        .background(Color.gray.opacity(0.1))
                } else {
                    VStack {
                        Image(systemName: object.fileType.icon)
                            .font(.system(size: cardSize > 100 ? 24 : 16))
                            .foregroundStyle(iconColor)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.gray.opacity(0.1))
                    .frame(height: cardSize)
                }

                // File size badge
                Text(object.formattedSize)
                    .font(.caption2)
                    .padding(3)
                    .background(Color.black.opacity(0.7))
                    .foregroundStyle(.white)
                    .cornerRadius(3)
                    .padding(3)
            }
            .frame(height: cardSize)
            .cornerRadius(6)

            VStack(alignment: .center, spacing: 2) {
                Text(object.fileName)
                    .font(cardSize > 100 ? .caption : .system(size: 10))
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                Text(object.lastModified.relativeFormattedCompact())
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

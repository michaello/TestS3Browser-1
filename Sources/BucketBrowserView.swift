import SwiftUI
import os.log

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
    let s3Service: S3Service
    @Binding var config: S3Config
    @AppStorage("s3BrowserCurrentPrefix") private var savedPrefix: String = ""
    @AppStorage("s3CurrentBucket") private var savedBucket: String = ""
    @AppStorage("s3BrowserSortOption") private var sortOption: String = SortOption.dateNewest.rawValue
    @AppStorage("s3BrowserViewStyle") private var viewStyleRaw: String = "standard"
    @AppStorage("s3BrowserFileTypeFilter") private var fileTypeFilterRaw: Int = FileTypeFilter.all.rawValue
    @State private var showingSortMenu = false

    private let logger = Logger(subsystem: "com.s3browser", category: "BucketBrowserView")

    private var viewStyle: ViewStyle {
        get { viewStyleRaw == "compact" ? .compact : .standard }
        set { viewStyleRaw = newValue == .compact ? "compact" : "standard" }
    }

    private var fileTypeFilter: FileTypeFilter {
        get { FileTypeFilter(rawValue: fileTypeFilterRaw) }
        set { fileTypeFilterRaw = newValue.rawValue }
    }

    private var filterMenuContent: some View {
        Section("Filter by Type") {
            Toggle("Images", isOn: Binding(
                get: { fileTypeFilter.contains(.image) },
                set: { isOn in
                    var updated = fileTypeFilter
                    if isOn {
                        updated.insert(.image)
                    } else {
                        updated.remove(.image)
                    }
                    fileTypeFilterRaw = updated.rawValue
                }
            ))

            Toggle("Text", isOn: Binding(
                get: { fileTypeFilter.contains(.text) },
                set: { isOn in
                    var updated = fileTypeFilter
                    if isOn {
                        updated.insert(.text)
                    } else {
                        updated.remove(.text)
                    }
                    fileTypeFilterRaw = updated.rawValue
                }
            ))

            Toggle("Logs", isOn: Binding(
                get: { fileTypeFilter.contains(.log) },
                set: { isOn in
                    var updated = fileTypeFilter
                    if isOn {
                        updated.insert(.log)
                    } else {
                        updated.remove(.log)
                    }
                    fileTypeFilterRaw = updated.rawValue
                }
            ))

            Toggle("Videos", isOn: Binding(
                get: { fileTypeFilter.contains(.video) },
                set: { isOn in
                    var updated = fileTypeFilter
                    if isOn {
                        updated.insert(.video)
                    } else {
                        updated.remove(.video)
                    }
                    fileTypeFilterRaw = updated.rawValue
                }
            ))

            Toggle("Other", isOn: Binding(
                get: { fileTypeFilter.contains(.unknown) },
                set: { isOn in
                    var updated = fileTypeFilter
                    if isOn {
                        updated.insert(.unknown)
                    } else {
                        updated.remove(.unknown)
                    }
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
    }

    private var sortMenuContent: some View {
        Section("Sort By") {
            Picker("Sort", selection: $sortOption) {
                ForEach(SortOption.allCases, id: \.self) { option in
                    Text(option.rawValue).tag(option.rawValue)
                }
            }
        }
    }

    private var viewStyleMenuContent: some View {
        Section("View Style") {
            Button {
                viewStyleRaw = "standard"
            } label: {
                Label("Standard", systemImage: viewStyle == .standard ? "checkmark" : "")
            }

            Button {
                viewStyleRaw = "compact"
            } label: {
                Label("Compact", systemImage: viewStyle == .compact ? "checkmark" : "")
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Breadcrumb navigation
                if isConfigured && !s3Service.currentPrefix.isEmpty {
                    BreadcrumbView(
                        pathComponents: s3Service.getPathComponents(),
                        onTapIndex: { index in
                            Task {
                                try? await s3Service.navigateToBreadcrumb(index)
                            }
                        },
                        onTapRoot: {
                            Task {
                                s3Service.currentPrefix = ""
                                try? await s3Service.listObjects()
                            }
                        }
                    )
                }

                Group {
                    if !isConfigured {
                        ContentUnavailableView(
                            "Configuration Required",
                            systemImage: "gear",
                            description: Text("Go to Settings to configure your S3 bucket and credentials")
                        )
                    } else if s3Service.isLoading {
                        VStack(spacing: 8) {
                            ProgressView()
                            Text(s3Service.loadingStatus.isEmpty ? "Loading..." : s3Service.loadingStatus)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if s3Service.items.isEmpty {
                        ScrollView {
                            ContentUnavailableView(
                                "No Files",
                                systemImage: "doc",
                                description: Text("No files found in \(s3Service.currentBucket). Pull to refresh.")
                            )
                            .frame(maxWidth: .infinity, minHeight: 300)
                        }
                        .refreshable {
                            await refreshFiles()
                        }
                    } else {
                        List {
                            ForEach(sortedItems) { item in
                                switch item {
                                case .folder(let folder):
                                    Button(action: {
                                        Task {
                                            try? await s3Service.navigateToFolder(folder.prefix)
                                            savedPrefix = s3Service.currentPrefix
                                        }
                                    }) {
                                        FolderRow(folder: folder)
                                    }
                                case .file(let object):
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

                                        if object.fileType == .video, let url = s3Service.getPublicURL(for: object.key) {
                                            ShareLink(item: url) {
                                                Label("Share Link", systemImage: "square.and.arrow.up")
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
                        }
                        .refreshable {
                            await refreshFiles()
                        }
                    }
                }
                .navigationTitle("S3 Browser")
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
                                        savedPrefix = ""
                                    } catch {
                                        logger.error("Failed to switch bucket: \(error.localizedDescription)")
                                    }
                                }
                            }
                        )
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            filterMenuContent
                                .menuActionDismissBehavior(.disabled)
                            sortMenuContent
                            viewStyleMenuContent
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                        }
                    }
                }
            }
            .task {
                if isConfigured {
                    logger.info("Task started - bucket: \(config.bucketName)")

                    // Fetch available buckets
                    do {
                        logger.debug("Fetching available buckets...")
                        try await s3Service.fetchAvailableBuckets()
                        logger.info("Successfully fetched \(s3Service.availableBuckets.count) buckets")
                    } catch {
                        logger.error("Failed to fetch buckets: \(error.localizedDescription)")
                    }

                    // Restore previous bucket if available, otherwise use configured bucket
                    if !savedBucket.isEmpty {
                        logger.debug("Switching to saved bucket: \(savedBucket)")
                        do {
                            try await s3Service.switchBucket(savedBucket)
                            logger.debug("Successfully switched to saved bucket")
                        } catch {
                            logger.error("Failed to switch to saved bucket: \(error.localizedDescription)")
                        }
                    } else {
                        logger.debug("Using configured bucket: \(config.bucketName)")
                        s3Service.currentBucket = config.bucketName
                    }

                    // Restore previous location (prefix)
                    s3Service.currentPrefix = savedPrefix
                    logger.debug("Refreshing files...")
                    await refreshFiles()
                    logger.info("Task completed - found \(s3Service.items.count) items")
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
                    savedPrefix = ""
                    savedBucket = ""
                    s3Service.currentPrefix = ""
                    s3Service.currentBucket = newConfig.bucketName

                    // Fetch buckets again with new credentials
                    do {
                        try await s3Service.fetchAvailableBuckets()
                    } catch {
                        logger.error("Failed to fetch buckets: \(error.localizedDescription)")
                    }

                    await refreshFiles()
                }
            }
        }
    }

    private var sortedItems: [S3Item] {
        let filtered = s3Service.items.filter { item in
            switch item {
            case .folder:
                return true // Always show folders
            case .file(let object):
                return fileTypeFilter.matches(object.fileType)
            }
        }

        guard let option = SortOption(rawValue: sortOption) else { return filtered }

        switch option {
        case .dateNewest:
            return filtered.sorted { $0.sortDate > $1.sortDate }
        case .dateOldest:
            return filtered.sorted { $0.sortDate < $1.sortDate }
        case .nameAZ:
            return filtered.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        case .nameZA:
            return filtered.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedDescending }
        case .sizeDescending:
            return filtered.sorted { $0.sortSize > $1.sortSize }
        case .sizeAscending:
            return filtered.sorted { $0.sortSize < $1.sortSize }
        }
    }

    private var isConfigured: Bool {
        !config.bucketName.isEmpty && !config.accessKey.isEmpty && !config.secretKey.isEmpty
    }

    private func refreshFiles() async {
        guard !s3Service.isLoading else {
            logger.debug("Already loading, skipping refresh")
            return
        }
        do {
            logger.debug("Listing objects for bucket: \(s3Service.currentBucket), prefix: \(s3Service.currentPrefix.isEmpty ? "(root)" : s3Service.currentPrefix)")
            try await s3Service.listObjects()
            logger.info("Successfully listed \(s3Service.items.count) items")
        } catch {
            logger.error("Failed to list objects: \(error.localizedDescription)")
        }
    }

    private func deleteObject(_ object: S3Object) async {
        do {
            try await s3Service.deleteObject(key: object.key)
            await refreshFiles()
        } catch {
            logger.error("Failed to delete object: \(error.localizedDescription)")
        }
    }

    private func copyToClipboard(_ object: S3Object) async {
        do {
            switch object.fileType {
            case .text, .log, .html:
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
            case .video:
                // Copy public URL for videos
                if let url = s3Service.getPublicURL(for: object.key) {
                    await MainActor.run {
                        UIPasteboard.general.string = url.absoluteString
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
            logger.error("Failed to copy content: \(error.localizedDescription)")
        }
    }
}

struct FileRow: View {
    let object: S3Object
    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
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

                // Video play badge
                if object.fileType == .video {
                    Image(systemName: "play.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 2)
                }
            }
            .frame(width: 50, height: 50)

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
        case .video: return .orange
        case .text: return .green
        case .html: return .teal
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
        case .video: return .orange
        case .text: return .green
        case .html: return .teal
        case .unknown: return .gray
        }
    }
}

struct FolderRow: View {
    let folder: S3Folder

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 4) {
                Text(folder.folderName)
                    .font(.headline)
                    .lineLimit(2)

                Text("Folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

#Preview {
    BucketBrowserView(
        s3Service: S3Service(config: S3Config.default),
        config: .constant(S3Config.default)
    )
}

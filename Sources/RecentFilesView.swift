import SwiftUI
import AVFoundation
import os.log

/// Displays the most recent files from the current bucket
struct RecentFilesView: View {
    private let logger = Logger(subsystem: "com.s3browser", category: "RecentFilesView")
    @Environment(\.scenePhase) private var scenePhase
    let config: S3Config
    let s3Service: S3Service
    @AppStorage("s3RecentViewMode") private var viewModeRaw: String = "list"
    @AppStorage("s3RecentGridCardSize") private var gridCardSize: Double = 100
    @AppStorage("s3RecentFileTypeFilter") private var fileTypeFilterRaw: Int = FileTypeFilter.all.rawValue
    @AppStorage("autoPreviewNewPhotos") private var autoPreviewNewPhotos = false
    @State private var hasLoadedOnce = false
    @State private var autoPreviewPhoto: S3Object?
    @State private var navigationPath = NavigationPath()
    @State private var copyToast: String?
    /// Drives the delete-failure alert. Set when deleteFile catches a thrown error.
    @State private var showDeleteError = false
    @State private var deleteErrorMessage = ""
    /// Drives the Clear All confirmation prompt before emptying the recent files list.
    @State private var showClearAllConfirm = false
    /// Keys of files that are new since the last time the screen was visited
    @State private var newFileKeys: Set<String> = []

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

    /// Returns only image files from the filtered list for gallery navigation
    private var imageFiles: [S3Object] {
        filteredRecentFiles.filter { $0.fileType == .image }
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                contentView

                // Copy confirmation toast
                if let toast = copyToast {
                    VStack {
                        Spacer()
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(toast)
                                .font(.subheadline)
                                .fontWeight(.medium)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial)
                        .cornerRadius(10)
                        .padding(.bottom, 16)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: copyToast)
            .navigationTitle("Recent Files")
            .navigationDestination(for: S3Object.self) { file in
                destinationView(for: file)
            }
            .fullScreenCover(item: $autoPreviewPhoto) { photo in
                autoPreviewCover(for: photo)
            }
            .toolbar { toolbarContent }
        }
        .task { await initialLoad() }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active, isConfigured else { return }
            Task { await refreshRecentFilesAndCheckForNew() }
        }
        .onChange(of: config) { _, newConfig in
            Task { await handleConfigChange(newConfig) }
        }
        .alert(isPresented: $showDeleteError) {
            Alert(
                title: Text("Delete Failed"),
                message: Text(deleteErrorMessage),
                dismissButton: .default(Text("OK"))
            )
        }
        .confirmationDialog(
            "Clear all recent files?",
            isPresented: $showClearAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                Task {
                    await MainActor.run { s3Service.clearRecentFiles() }
                    await refreshRecentFiles()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var contentView: some View {
        if !isConfigured {
            ContentUnavailableView(
                "Configuration Required",
                systemImage: "gear",
                description: Text("Go to Settings to configure your S3 bucket and credentials")
            )
        } else if !hasLoadedOnce || (s3Service.isLoading && s3Service.recentFiles.isEmpty) {
            VStack(spacing: 8) {
                ProgressView()
                Text(s3Service.loadingStatus.isEmpty ? "Loading..." : s3Service.loadingStatus)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if s3Service.recentFiles.isEmpty {
            ScrollView {
                ContentUnavailableView(
                    "No Files",
                    systemImage: "doc",
                    description: Text("No files found in bucket")
                )
                .frame(maxWidth: .infinity, minHeight: 300)
            }
            .refreshable { await refreshRecentFiles() }
        } else if filteredRecentFiles.isEmpty {
            ContentUnavailableView(
                "No Matching Files",
                systemImage: "doc",
                description: Text("No files match the selected filter")
            )
        } else {
            filesView
        }
    }

    @ViewBuilder
    private var filesView: some View {
        if viewMode == .list {
            listView
        } else {
            gridView
        }
    }

    private var listView: some View {
        List {
            ForEach(filteredRecentFiles) { file in
                NavigationLink(destination: destinationView(for: file)) {
                    RecentFileRow(object: file, s3Service: s3Service, isNew: newFileKeys.contains(file.key))
                }
                .contextMenu { deleteContextMenu(for: file) }
            }
        }
        .refreshable { await refreshRecentFiles() }
    }

    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: gridCardSize), spacing: 12)], spacing: 12) {
                ForEach(filteredRecentFiles) { file in
                    NavigationLink(destination: destinationView(for: file)) {
                        RecentFileGridItem(object: file, s3Service: s3Service, cardSize: gridCardSize, isNew: newFileKeys.contains(file.key))
                    }
                    .contextMenu { deleteContextMenu(for: file) }
                }
            }
            .padding()
        }
        .refreshable { await refreshRecentFiles() }
    }

    @ViewBuilder
    private func deleteContextMenu(for file: S3Object) -> some View {
        Button {
            let url = s3Service.generatePresignedURL(for: file.key, bucket: file.bucket, expiresIn: 86400)
            if let url = url {
                UIPasteboard.general.string = url
                showCopyToast("Link copied")
            }
        } label: {
            Label("Copy Link (1 day)", systemImage: "link")
        }

        Button {
            UIPasteboard.general.string = file.key
            showCopyToast("Path copied")
        } label: {
            Label("Copy Path", systemImage: "doc.on.doc")
        }

        Divider()

        Button(role: .destructive) {
            Task { await deleteFile(file) }
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func autoPreviewCover(for photo: S3Object) -> some View {
        let index = imageFiles.firstIndex(where: { $0.id == photo.id }) ?? 0
        return NavigationStack {
            ImageGalleryView(images: imageFiles, initialIndex: index, s3Service: s3Service)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") { autoPreviewPhoto = nil }
                    }
                }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            trailingToolbarContent
        }
    }

    private var trailingToolbarContent: some View {
        HStack(spacing: 12) {
            if viewMode == .grid {
                Slider(value: $gridCardSize, in: 60...160, step: 10)
                    .frame(width: 80)
            }

            filterMenu

            Button {
                showClearAllConfirm = true
            } label: {
                Image(systemName: "trash")
            }

            Button {
                viewModeRaw = viewMode == .list ? "grid" : "list"
            } label: {
                Image(systemName: viewMode == .list ? "square.grid.2x2" : "list.bullet")
            }
        }
    }

    private var filterMenu: some View {
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

                Toggle("Videos", isOn: Binding(
                    get: { fileTypeFilter.contains(.video) },
                    set: { isOn in
                        var updated = fileTypeFilter
                        if isOn { updated.insert(.video) } else { updated.remove(.video) }
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
                    Label("Show All", systemImage: "checkmark.circle")
                }
            }
            .menuActionDismissBehavior(.disabled)
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
    }

    private var isConfigured: Bool {
        !config.bucketName.isEmpty && !config.accessKey.isEmpty && !config.secretKey.isEmpty
    }

    private func initialLoad() async {
        guard isConfigured else { return }

        // Migrate a stored "show all" value from an earlier app version up to the
        // current full set. 15 was "all" before .video was added, 31 was "all"
        // before .html was added. Only bump these exact old "all" values, so a user
        // who intentionally unchecked some types is left alone.
        let oldAllValues: Set<Int> = [15, 31]
        if oldAllValues.contains(fileTypeFilterRaw) {
            fileTypeFilterRaw = FileTypeFilter.all.rawValue
        }

        // Set default bucket so the client initializes
        if s3Service.currentBucket.isEmpty {
            s3Service.currentBucket = config.bucketName
        }

        await refreshRecentFiles()
    }

    private func handleConfigChange(_ newConfig: S3Config) async {
        try? await s3Service.updateConfig(newConfig)
        s3Service.currentBucket = newConfig.bucketName
        hasLoadedOnce = false
        await refreshRecentFiles()
    }

    private func refreshRecentFiles() async {
        do {
            try await s3Service.fetchRecentFilesFromAllBuckets(limit: 50)

            // Compute new file keys before marking seen, grouped by bucket
            var discoveredNewKeys: Set<String> = []
            let filesByBucket = Dictionary(grouping: s3Service.recentFiles, by: { $0.bucket ?? s3Service.currentBucket })
            for (bucket, files) in filesByBucket {
                let keys = files.map { $0.key }
                // Only report new items when we have a prior seen record (not first visit)
                if await SeenPhotosTracker.shared.hasSeenPhotos(for: bucket) {
                    let newKeys = await SeenPhotosTracker.shared.findNewPhotos(currentPhotos: keys, bucket: bucket)
                    discoveredNewKeys.formUnion(newKeys)
                }
                if !keys.isEmpty {
                    await SeenPhotosTracker.shared.markAsSeen(photoKeys: keys, bucket: bucket)
                }
            }

            await MainActor.run {
                newFileKeys = discoveredNewKeys
            }
        } catch {
            logger.error("Failed to fetch recent files: \(error.localizedDescription)")
        }
        if !hasLoadedOnce {
            await MainActor.run {
                hasLoadedOnce = true
            }
        }

        // Prefetch all visible files in the background so detail views load instantly
        s3Service.prefetchObjects(s3Service.recentFiles)
    }

    /// Refreshes files and checks for new photos to auto-preview
    private func refreshRecentFilesAndCheckForNew() async {
        guard autoPreviewNewPhotos else {
            await refreshRecentFiles()
            return
        }

        do {
            try await s3Service.fetchRecentFilesFromAllBuckets(limit: 50)

            // Compute new keys across all buckets (all file types), grouped by bucket
            var discoveredNewKeys: Set<String> = []
            var allNewPhotoKeys: [String] = []
            let filesByBucket = Dictionary(grouping: s3Service.recentFiles, by: { $0.bucket ?? s3Service.currentBucket })
            for (bucket, files) in filesByBucket {
                let keys = files.map { $0.key }
                if await SeenPhotosTracker.shared.hasSeenPhotos(for: bucket) {
                    let newKeys = await SeenPhotosTracker.shared.findNewPhotos(currentPhotos: keys, bucket: bucket)
                    discoveredNewKeys.formUnion(newKeys)
                    // Collect new image keys for auto-preview
                    let newImageKeys = newKeys.filter { key in
                        files.first(where: { $0.key == key })?.fileType == .image
                    }
                    allNewPhotoKeys.append(contentsOf: newImageKeys)
                }
                if !keys.isEmpty {
                    await SeenPhotosTracker.shared.markAsSeen(photoKeys: keys, bucket: bucket)
                }
            }

            await MainActor.run {
                newFileKeys = discoveredNewKeys
            }

            // Auto-preview the newest new photo
            if let newestNewKey = allNewPhotoKeys.first,
               let newestPhoto = imageFiles.first(where: { $0.key == newestNewKey }) {
                logger.info("Auto-previewing new photo: \(newestNewKey)")
                await MainActor.run {
                    autoPreviewPhoto = newestPhoto
                }
            }
        } catch {
            logger.error("Failed to fetch recent files: \(error.localizedDescription)")
        }

        if !hasLoadedOnce {
            await MainActor.run {
                hasLoadedOnce = true
            }
        }
    }

    private func showCopyToast(_ message: String) {
        copyToast = message
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { copyToast = nil }
        }
    }

    private func deleteFile(_ file: S3Object) async {
        do {
            try await s3Service.deleteObject(key: file.key, bucket: file.bucket)
            logger.info("Deleted file: \(file.key)")
            await refreshRecentFiles()
        } catch {
            logger.error("Failed to delete file \(file.key): \(error.localizedDescription)")
            deleteErrorMessage = "Could not delete \(file.fileName): \(error.localizedDescription)"
            showDeleteError = true
        }
    }

    /// Returns the appropriate destination view for a file
    /// - Images open in the gallery with swipe navigation
    /// - Other files open in the standard detail view
    @ViewBuilder
    private func destinationView(for file: S3Object) -> some View {
        if file.fileType == .image {
            let index = imageFiles.firstIndex(where: { $0.id == file.id }) ?? 0
            ImageGalleryView(images: imageFiles, initialIndex: index, s3Service: s3Service)
        } else {
            // Video and other file types use FileDetailView
            FileDetailView(object: file, service: s3Service)
        }
    }
}

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
            Text(object.bucket != nil ? "\(object.bucket!)/\(object.key)" : object.key)
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
                // Video: download to temp file, extract first frame
                let data = try await s3Service.downloadObject(key: object.key, bucket: object.bucket)
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(object.fileName)
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

/// Grid item component for grid view display
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
                let data = try await s3Service.downloadObject(key: object.key, bucket: object.bucket)
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(object.fileName)
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

#Preview {
    RecentFilesView(config: S3Config.default, s3Service: S3Service(config: S3Config.default))
}

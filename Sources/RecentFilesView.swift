import SwiftUI
import AVFoundation
import os.log

/// Sentinel value pushed onto the NavigationStack path to trigger the folder browser.
private struct BrowseRoot: Hashable {}

/// Displays the most recent files from the current bucket
struct RecentFilesView: View {
    private let logger = Logger(subsystem: "com.s3browser", category: "RecentFilesView")
    @Environment(\.scenePhase) private var scenePhase
    @State private var tagStore = TagStore.shared
    @State private var starStore = StarStore.shared
    @State private var showOnlyStarred = false
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
    @State private var searchText = ""
    /// The file whose presigned-URL share sheet is open.
    @State private var shareTarget: S3Object? = nil
    /// The file currently being renamed; drives the rename alert.
    @State private var renameTarget: S3Object?
    @State private var renameText = ""
    @State private var showRenameError = false
    @State private var renameErrorMessage = ""
    /// Bulk-selection state.
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var showBulkDeleteConfirm = false
    @State private var showBulkDeleteError = false
    @State private var bulkDeleteErrorMessage = ""
    /// Tag filter. nil means "show all". A non-nil string shows only files with that tag.
    @State private var tagFilter: String? = nil
    /// Drives the "Set Tag" alert for a single file.
    @State private var tagTarget: S3Object? = nil
    @State private var tagText = ""
    @State private var sortOrder: SortOrder = .newestFirst

    enum SortOrder: String, CaseIterable {
        case newestFirst = "Newest first"
        case oldestFirst = "Oldest first"
        case nameAZ      = "Name A-Z"
        case nameZA      = "Name Z-A"
        case bucket      = "Bucket"
    }

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
        let typeFiltered = fileTypeFilter == .all
            ? s3Service.recentFiles
            : s3Service.recentFiles.filter { fileTypeFilter.matches($0.fileType) }
        let tagFiltered: [S3Object]
        if let tagFilter {
            tagFiltered = typeFiltered.filter { tagStore.tag(forKey: $0.key) == tagFilter }
        } else {
            tagFiltered = typeFiltered
        }
        let starFiltered: [S3Object] = showOnlyStarred
            ? tagFiltered.filter { starStore.isStarred($0.key) }
            : tagFiltered
        let searchFiltered: [S3Object]
        if searchText.isEmpty {
            searchFiltered = starFiltered
        } else {
            let lower = searchText.lowercased()
            searchFiltered = starFiltered.filter { $0.key.lowercased().contains(lower) }
        }
        switch sortOrder {
        case .newestFirst: return searchFiltered.sorted { ($0.lastModified ?? .distantPast) > ($1.lastModified ?? .distantPast) }
        case .oldestFirst: return searchFiltered.sorted { ($0.lastModified ?? .distantPast) < ($1.lastModified ?? .distantPast) }
        case .nameAZ:      return searchFiltered.sorted { $0.fileName.localizedCompare($1.fileName) == .orderedAscending }
        case .nameZA:      return searchFiltered.sorted { $0.fileName.localizedCompare($1.fileName) == .orderedDescending }
        case .bucket:      return searchFiltered.sorted { ($0.bucket ?? "") < ($1.bucket ?? "") }
        }
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
            .navigationDestination(for: BrowseRoot.self) { _ in
                PrefixBrowserView(
                    s3Service: s3Service,
                    prefix: "",
                    bucket: s3Service.currentBucket,
                    title: s3Service.currentBucket
                )
            }
            .fullScreenCover(item: $autoPreviewPhoto) { photo in
                autoPreviewCover(for: photo)
            }
            .toolbar { toolbarContent }
            .searchable(text: $searchText, prompt: "Search files")
            .safeAreaInset(edge: .top) {
                tagFilterBar
            }
        }
        .task { await initialLoad() }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active, isConfigured else { return }
            Task { await refreshRecentFilesAndCheckForNew() }
        }
        .onChange(of: config) { _, newConfig in
            Task { await handleConfigChange(newConfig) }
        }
        .sheet(item: $shareTarget) { file in
            SharePresignedURLSheet(object: file, s3Service: s3Service)
        }
        .deleteErrorAlert(isPresented: $showDeleteError, message: deleteErrorMessage)
        .alert("Rename File", isPresented: .init(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("New filename", text: $renameText)
                .autocorrectionDisabled()
            Button("Rename") {
                guard let file = renameTarget else { return }
                let newName = renameText.trimmingCharacters(in: .whitespaces)
                guard !newName.isEmpty else { renameTarget = nil; return }
                let dir = (file.key as NSString).deletingLastPathComponent
                let newKey = dir.isEmpty ? newName : "\(dir)/\(newName)"
                Task { await renameFile(file, to: newKey) }
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        } message: {
            if let file = renameTarget {
                Text(file.fileName)
            }
        }
        .alert("Rename Failed", isPresented: $showRenameError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(renameErrorMessage)
        }
        .alert("Set Tag", isPresented: .init(
            get: { tagTarget != nil },
            set: { if !$0 { tagTarget = nil } }
        )) {
            TextField("Tag (leave blank to remove)", text: $tagText)
                .autocorrectionDisabled()
                .autocapitalization(.none)
            Button("Save") {
                guard let file = tagTarget else { return }
                tagStore.setTag(tagText.trimmingCharacters(in: .whitespaces).isEmpty ? nil : tagText.trimmingCharacters(in: .whitespaces), forKey: file.key)
                tagTarget = nil
            }
            Button("Remove Tag", role: .destructive) {
                guard let file = tagTarget else { return }
                tagStore.setTag(nil, forKey: file.key)
                tagTarget = nil
            }
            Button("Cancel", role: .cancel) { tagTarget = nil }
        } message: {
            if let file = tagTarget {
                Text(file.fileName)
            }
        }
        .confirmationDialog(
            "Delete \(selectedIDs.count) file\(selectedIDs.count == 1 ? "" : "s")?",
            isPresented: $showBulkDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await bulkDeleteSelected() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Some Deletes Failed", isPresented: $showBulkDeleteError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(bulkDeleteErrorMessage)
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
            if !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                ContentUnavailableView(
                    "No Matching Files",
                    systemImage: "doc",
                    description: Text("No files match the selected filter")
                )
            }
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
                if isSelecting {
                    Button {
                        toggleSelection(file)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selectedIDs.contains(file.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedIDs.contains(file.id) ? .blue : .secondary)
                                .font(.title3)
                            RecentFileRow(object: file, s3Service: s3Service, isNew: newFileKeys.contains(file.key), tag: tagStore.tag(forKey: file.key))
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    NavigationLink(destination: destinationView(for: file)) {
                        RecentFileRow(object: file, s3Service: s3Service, isNew: newFileKeys.contains(file.key), tag: tagStore.tag(forKey: file.key))
                    }
                    .contextMenu { deleteContextMenu(for: file) }
                    .swipeActions(edge: .leading) {
                        Button {
                            shareTarget = file
                        } label: {
                            Label("Share Link", systemImage: "square.and.arrow.up")
                        }
                        .tint(.blue)
                    }
                }
            }
        }
        .refreshable { await refreshRecentFiles() }
    }

    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: gridCardSize), spacing: 12)], spacing: 12) {
                ForEach(filteredRecentFiles) { file in
                    if isSelecting {
                        Button {
                            toggleSelection(file)
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                RecentFileGridItem(object: file, s3Service: s3Service, cardSize: gridCardSize, isNew: newFileKeys.contains(file.key), tag: tagStore.tag(forKey: file.key))
                                    .opacity(selectedIDs.contains(file.id) ? 0.75 : 1.0)
                                Image(systemName: selectedIDs.contains(file.id) ? "checkmark.circle.fill" : "circle.fill")
                                    .foregroundStyle(selectedIDs.contains(file.id) ? .blue : Color(.systemBackground).opacity(0.8))
                                    .font(.title3)
                                    .padding(6)
                            }
                        }
                        .buttonStyle(.plain)
                    } else {
                        NavigationLink(destination: destinationView(for: file)) {
                            RecentFileGridItem(object: file, s3Service: s3Service, cardSize: gridCardSize, isNew: newFileKeys.contains(file.key), tag: tagStore.tag(forKey: file.key))
                        }
                        .contextMenu { deleteContextMenu(for: file) }
                    }
                }
            }
            .padding()
        }
        .refreshable { await refreshRecentFiles() }
    }

    private func toggleSelection(_ file: S3Object) {
        if selectedIDs.contains(file.id) {
            selectedIDs.remove(file.id)
        } else {
            selectedIDs.insert(file.id)
        }
    }

    private func bulkDeleteSelected() async {
        let toDelete = filteredRecentFiles.filter { selectedIDs.contains($0.id) }
        var failures: [String] = []

        await withTaskGroup(of: String?.self) { group in
            for file in toDelete {
                group.addTask {
                    do {
                        try await self.s3Service.deleteObject(key: file.key, bucket: file.bucket)
                        return nil
                    } catch {
                        return error.localizedDescription
                    }
                }
            }
            for await errorMessage in group {
                if let msg = errorMessage { failures.append(msg) }
            }
        }

        await MainActor.run {
            selectedIDs.removeAll()
            isSelecting = false
        }
        await refreshRecentFiles()

        if !failures.isEmpty {
            await MainActor.run {
                bulkDeleteErrorMessage = failures.joined(separator: "\n")
                showBulkDeleteError = true
            }
        }
    }

    /// Copies a 1-day presigned URL for the file to the pasteboard, showing a toast for
    /// either outcome. Shared by the leading swipe action and the context-menu Copy Link
    /// item so both behave the same, including the nil-URL failure case.
    private func copyURL(for file: S3Object) {
        if let url = s3Service.generatePresignedURL(for: file.key, bucket: file.bucket, expiresIn: 86400) {
            UIPasteboard.general.string = url
            showCopyToast("Link copied")
        } else {
            showCopyToast("Could not copy link")
        }
    }

    @ViewBuilder
    private func deleteContextMenu(for file: S3Object) -> some View {
        Button {
            shareTarget = file
        } label: {
            Label("Share Link…", systemImage: "square.and.arrow.up")
        }

        Button {
            UIPasteboard.general.string = file.key
            showCopyToast("Path copied")
        } label: {
            Label("Copy Path", systemImage: "doc.on.doc")
        }

        Button {
            renameText = file.fileName
            renameTarget = file
        } label: {
            Label("Rename", systemImage: "pencil")
        }

        Button {
            tagText = tagStore.tag(forKey: file.key) ?? ""
            tagTarget = file
        } label: {
            Label(tagStore.tag(forKey: file.key) != nil ? "Edit Tag" : "Set Tag", systemImage: "tag")
        }

        Button {
            starStore.toggle(file.key)
        } label: {
            Label(starStore.isStarred(file.key) ? "Unstar" : "Star", systemImage: starStore.isStarred(file.key) ? "star.slash" : "star")
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
        ToolbarItem(placement: .topBarLeading) {
            Button(isSelecting ? "Done" : "Edit") {
                isSelecting.toggle()
                if !isSelecting { selectedIDs.removeAll() }
            }
            .disabled(s3Service.recentFiles.isEmpty)
        }
        ToolbarItem(placement: .topBarTrailing) {
            trailingToolbarContent
        }
    }

    private var trailingToolbarContent: some View {
        HStack(spacing: 12) {
            if isSelecting {
                Button {
                    showBulkDeleteConfirm = true
                } label: {
                    Text("Delete (\(selectedIDs.count))")
                        .foregroundStyle(selectedIDs.isEmpty ? Color.secondary : Color.red)
                }
                .disabled(selectedIDs.isEmpty)
            } else {
                if viewMode == .grid {
                    Slider(value: $gridCardSize, in: 60...160, step: 10)
                        .frame(width: 80)
                }

                Button {
                    navigationPath.append(BrowseRoot())
                } label: {
                    Image(systemName: "folder")
                }

                sortMenu

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
    }

    /// Tag filter bar: a Picker for tag selection plus a Starred toggle.
    /// Hidden when there are no tags and no starred files.
    @ViewBuilder
    private var tagFilterBar: some View {
        let tags = tagStore.allTags
        let hasStarred = !starStore.starredKeys.isEmpty
        if !tags.isEmpty || hasStarred {
            HStack(spacing: 12) {
                if !tags.isEmpty {
                    Picker("Tag", selection: $tagFilter) {
                        Text("All tags").tag(String?.none)
                        ForEach(tags, id: \.self) { tag in
                            HStack {
                                TagChip(tag: tag)
                                Text(tag)
                            }
                            .tag(Optional(tag))
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: tagFilter) { _, _ in
                        if tagFilter != nil { showOnlyStarred = false }
                    }
                }

                if hasStarred {
                    Button {
                        showOnlyStarred.toggle()
                        if showOnlyStarred { tagFilter = nil }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: showOnlyStarred ? "star.fill" : "star")
                                .font(.caption)
                            Text("Starred")
                                .font(.subheadline)
                                .fontWeight(showOnlyStarred ? .semibold : .regular)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(showOnlyStarred ? Color.yellow.opacity(0.85) : Color(.secondarySystemFill), in: Capsule())
                        .foregroundStyle(showOnlyStarred ? Color.black : Color.primary)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private var sortMenu: some View {
        Menu {
            Section("Sort by") {
                ForEach(SortOrder.allCases, id: \.self) { order in
                    Button {
                        sortOrder = order
                    } label: {
                        if sortOrder == order {
                            Label(order.rawValue, systemImage: "checkmark")
                        } else {
                            Text(order.rawValue)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
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

    private func renameFile(_ file: S3Object, to newKey: String) async {
        renameTarget = nil
        do {
            try await s3Service.renameObject(key: file.key, to: newKey, bucket: file.bucket)
            logger.info("Renamed \(file.key) -> \(newKey)")
        } catch {
            logger.error("Rename failed for \(file.key): \(error.localizedDescription)")
            await MainActor.run {
                renameErrorMessage = "Could not rename \(file.fileName): \(error.localizedDescription)"
                showRenameError = true
            }
        }
    }

    private func deleteFile(_ file: S3Object) async {
        do {
            try await s3Service.deleteObject(key: file.key, bucket: file.bucket)
            logger.info("Deleted file: \(file.key)")
            await refreshRecentFiles()
        } catch {
            logger.error("Failed to delete file \(file.key): \(error.localizedDescription)")
            await MainActor.run {
                deleteErrorMessage = "Could not delete \(file.fileName): \(error.localizedDescription)"
                showDeleteError = true
            }
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


#Preview {
    RecentFilesView(config: S3Config.default, s3Service: S3Service(config: S3Config.default))
}

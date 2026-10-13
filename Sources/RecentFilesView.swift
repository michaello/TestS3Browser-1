import SwiftUI
import AVFoundation
import os.log

/// Sentinel value pushed onto the NavigationStack path to trigger the folder browser.
private struct BrowseRoot: Hashable {}

/// Displays the most recent files from the current bucket
struct RecentFilesView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var rowProjection = DerivedRowsCache<[S3Object]>()
    @State private var galleryProjection = DerivedRowsCache<[S3Object]>()
    private let logger = Logger(subsystem: "com.s3browser", category: "RecentFilesView")
    @Environment(\.scenePhase) private var scenePhase
    @State private var tagStore = TagStore.shared
    @State private var starStore = StarStore.shared
    @State private var annotationFilter = RecentAnnotationFilter()
    let config: S3Config
    let s3Service: S3Service
    @AppStorage("s3RecentViewMode") private var viewModeRaw: String = "list"
    @AppStorage("s3RecentGridCardSize") private var gridCardSize: Double = 100
    @AppStorage("s3RecentFileTypeFilter") private var fileTypeFilterRaw: Int = FileTypeFilter.all.rawValue
    @AppStorage("autoPreviewNewPhotos") private var autoPreviewNewPhotos = false
    @State private var hasLoadedOnce = false
    @State private var refreshRequestID: UUID?
    @State private var transferConflict: ObjectTransferConflict?
    @State private var copyEncryptionPrompt: CopyEncryptionPrompt?
    @State private var transferEncryptionDecision: CopyEncryptionDecision = .automatic
    @State private var autoPreviewPhoto: S3Object?
    @State private var navigationPath = NavigationPath()
    @State private var copyToast: String?
    /// Drives the delete-failure alert. Set when deleteFile catches a thrown error.
    @State private var showDeleteError = false
    @State private var deleteErrorMessage = ""
    /// Drives the Clear All confirmation prompt before emptying the recent files list.
    @State private var showClearAllConfirm = false
    /// Keys of files that are new since the last time the screen was visited
    @State private var newFileKeys: Set<LocalObjectIdentity> = []
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
    @State private var bulkDeletion = BulkObjectDeletion()
    @State private var showBulkDeleteConfirm = false
    @State private var showBulkDeleteError = false
    @State private var bulkDeleteErrorMessage = ""
    /// Tag filter. nil means "show all". A non-nil string shows only files with that tag.

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
        rowProjection.value(for: projectionKey) { deriveFilteredRecentFiles() }
    }

    private var projectionKey: DerivedRowsKey {
        DerivedRowsKey(revision: s3Service.recentRevision,
            fields: [s3Service.session.configuration.account, String(fileTypeFilterRaw), String(annotationFilter.tag != nil), annotationFilter.tag ?? "",
                String(annotationFilter.starredOnly), String(starStore.revision), String(tagStore.revision), searchText, sortOrder.rawValue])
    }

    private func deriveFilteredRecentFiles() -> [S3Object] {
        let typeFiltered = fileTypeFilter == .all
            ? s3Service.recentFiles
            : s3Service.recentFiles.filter { fileTypeFilter.matches($0.fileType) }
        let tagFiltered: [S3Object]
        if let selectedTag = annotationFilter.tag {
            tagFiltered = typeFiltered.filter { tagStore.tag(for: identity($0)) == selectedTag }
        } else {
            tagFiltered = typeFiltered
        }
        let starFiltered: [S3Object] = annotationFilter.starredOnly
            ? tagFiltered.filter { starStore.isStarred(identity($0)) }
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
        galleryProjection.value(for: projectionKey) { filteredRecentFiles.filter { $0.fileType == .image } }
    }

    var body: some View {
        AuditTelemetry.shared.measureViewConstruction(.recent) { measuredContent }
    }

    private var measuredContent: some View {
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
                VStack(spacing: 6) {
                    tagFilterBar
                    if s3Service.isRecentLoading || s3Service.lastRecentRefreshAt != nil {
                        HStack(spacing: 6) {
                            if s3Service.isRecentLoading { ProgressView().controlSize(.small) }
                            if let date = s3Service.lastRecentRefreshAt {
                                Text("Updated \(date, style: .relative) ago")
                            } else {
                                Text("Refreshing saved files...")
                            }
                            Spacer()
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                    }
                    if let message = s3Service.recentRefreshError {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                        Button("Retry Refresh") { Task { await refreshRecentFiles(force: true) } }
                            .disabled(s3Service.isRecentLoading)
                    }
                }
            }
        }
        .task { await initialLoad() }
        .onChange(of: fileTypeFilterRaw) { _, _ in
            s3Service.selectRecentFiles(limit: 50, typeFilter: fileTypeFilter)
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active, isConfigured else { return }
            Task { await refreshRecentFilesAndCheckForNew() }
        }
        .onChange(of: s3Service.session.generation) { _, _ in
            hasLoadedOnce = !s3Service.recentFiles.isEmpty
            annotationFilter.clear()
            newFileKeys.removeAll()
            bulkDeletion.cancel(clearSelection: true)
            showBulkDeleteConfirm = false
            Task { await refreshRecentFiles() }
        }
        .onChange(of: starStore.starredKeys) { _, _ in reconcileAnnotationFilter() }
        .onChange(of: tagStore.tags) { _, _ in reconcileAnnotationFilter() }
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
                let newKey = S3TransferKeys.parentPrefix(of: file.key) + newName
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
        .objectTransferConfirmation(conflict: $transferConflict) { request, approval in
            await performTransfer(request, approval: approval, encryptionDecision: transferEncryptionDecision)
        }
        .copyEncryptionConfirmation(prompt: $copyEncryptionPrompt)
        .alert("Set Tag", isPresented: .init(
            get: { tagTarget != nil },
            set: { if !$0 { tagTarget = nil } }
        )) {
            TextField("Tag (leave blank to remove)", text: $tagText)
                .autocorrectionDisabled()
                .autocapitalization(.none)
            Button("Save") {
                guard let file = tagTarget else { return }
                tagStore.setTag(tagText.trimmingCharacters(in: .whitespaces).isEmpty ? nil : tagText.trimmingCharacters(in: .whitespaces), for: identity(file))
                tagTarget = nil
            }
            Button("Remove Tag", role: .destructive) {
                guard let file = tagTarget else { return }
                tagStore.setTag(nil, for: identity(file))
                tagTarget = nil
            }
            Button("Cancel", role: .cancel) { tagTarget = nil }
        } message: {
            if let file = tagTarget {
                Text(file.fileName)
            }
        }
        .confirmationDialog(
            "Delete \(bulkDeletion.confirmationCount) file\(bulkDeletion.confirmationCount == 1 ? "" : "s")?",
            isPresented: $showBulkDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                bulkDeleteSelected()
            }
            Button("Cancel", role: .cancel) { bulkDeletion.dismissConfirmation() }
        }
        .alert("Some Deletes Failed", isPresented: $showBulkDeleteError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(bulkDeleteErrorMessage)
        }
        .confirmationDialog(
            "Reset Recent Cache?",
            isPresented: $showClearAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset Recent Cache") {
                Task {
                    await MainActor.run { s3Service.clearRecentFiles() }
                    await refreshRecentFiles(force: true)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Rebuilds the local Recent cache after a successful refresh. Existing S3 files are kept.")
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
        } else if case .initialFailure(let message) = listPresentation {
            ContentUnavailableView {
                Label("Couldn't load files", systemImage: "exclamationmark.triangle")
            } description: { Text(message) } actions: {
                Button("Retry") { Task { await refreshRecentFiles(force: true) } }
            }
        } else if listPresentation == .initialLoading {
            VStack(spacing: 8) {
                ProgressView()
                Text(s3Service.recentLoadingStatus)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if s3Service.recentFiles.isEmpty, fileTypeFilter != .all,
                  s3Service.session.catalogs.value(for: s3Service.session.configuration.account)?.records.isEmpty == false {
            ContentUnavailableView {
                Label("No Matching Files", systemImage: "doc")
            } description: { Text("No files match the selected types.") } actions: {
                Button("Clear Filters") { clearFilters() }
            }
        } else if s3Service.recentFiles.isEmpty {
            ScrollView {
                ContentUnavailableView(
                    "No Files",
                    systemImage: "doc",
                    description: Text("No files found in bucket")
                )
                .frame(maxWidth: .infinity, minHeight: 300)
            }
            .refreshable { await refreshRecentFiles(force: true) }
        } else if filteredRecentFiles.isEmpty {
            ContentUnavailableView {
                Label("No Matching Files", systemImage: "doc")
            } description: {
                Text("No files match the selected filters or search.")
            } actions: {
                Button("Clear Filters") { clearFilters() }
            }
        } else {
            filesView
        }
    }

    private var listPresentation: ListPresentation {
        .resolve(hasSnapshot: s3Service.session.catalogs.value(for: s3Service.session.configuration.account) != nil,
            rowCount: s3Service.recentFiles.count, isLoading: s3Service.isRecentLoading, error: s3Service.recentRefreshError)
    }

    @ViewBuilder
    private var filesView: some View {
        if viewMode == .list || FileCardPresentation.prefersList(requestedGrid: viewMode == .grid, isAccessibilitySize: dynamicTypeSize.isAccessibilitySize) {
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
                            Image(systemName: bulkDeletion.selected.contains(identity(file)) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(bulkDeletion.selected.contains(identity(file)) ? .blue : .secondary)
                                .font(.title3)
                            RecentFileRow(object: file, s3Service: s3Service, isNew: newFileKeys.contains(identity(file)), tag: tagStore.tag(for: identity(file)))
                                .accessibilityIdentifier(file.key)
                                .onAppear { AuditTelemetry.shared.firstContentVisible(fromCache: s3Service.recentRowsFromCache) }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(bulkDeletion.isDeleting)
                } else {
                    NavigationLink(destination: destinationView(for: file)) {
                        RecentFileRow(object: file, s3Service: s3Service, isNew: newFileKeys.contains(identity(file)), tag: tagStore.tag(for: identity(file)))
                            .accessibilityIdentifier(file.key)
                            .onAppear { AuditTelemetry.shared.firstContentVisible(fromCache: s3Service.recentRowsFromCache) }
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
        .refreshable { await refreshRecentFiles(force: true) }
        .onScrollPhaseChange { _, phase in AuditTelemetry.shared.setScrolling(phase != .idle) }
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
                                RecentFileGridItem(object: file, s3Service: s3Service, cardSize: gridCardSize, isNew: newFileKeys.contains(identity(file)), tag: tagStore.tag(for: identity(file)))
                                    .opacity(bulkDeletion.selected.contains(identity(file)) ? 0.75 : 1.0)
                                Image(systemName: bulkDeletion.selected.contains(identity(file)) ? "checkmark.circle.fill" : "circle.fill")
                                    .foregroundStyle(bulkDeletion.selected.contains(identity(file)) ? .blue : Color(.systemBackground).opacity(0.8))
                                    .font(.title3)
                                    .padding(6)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(bulkDeletion.isDeleting)
                    } else {
                        NavigationLink(destination: destinationView(for: file)) {
                            RecentFileGridItem(object: file, s3Service: s3Service, cardSize: gridCardSize, isNew: newFileKeys.contains(identity(file)), tag: tagStore.tag(for: identity(file)))
                        }
                        .contextMenu { deleteContextMenu(for: file) }
                    }
                }
            }
            .padding()
        }
        .refreshable { await refreshRecentFiles(force: true) }
    }

    private func toggleSelection(_ file: S3Object) {
        bulkDeletion.toggle(identity(file))
    }

    private func bulkDeleteSelected() {
        let generation = s3Service.session.generation
        bulkDeletion.start { target in
            guard s3Service.session.isCurrent(generation),
                  target.account.utf8.elementsEqual(s3Service.session.configuration.account.utf8) else { throw CancellationError() }
            try await s3Service.deleteObject(key: target.key, bucket: target.bucket)
        } completion: {
            isSelecting = !bulkDeletion.selected.isEmpty
            if let message = bulkDeletion.failureMessage {
                bulkDeleteErrorMessage = message
                showBulkDeleteError = true
            }
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
            tagText = tagStore.tag(for: identity(file)) ?? ""
            tagTarget = file
        } label: {
            Label(tagStore.tag(for: identity(file)) != nil ? "Edit Tag" : "Set Tag", systemImage: "tag")
        }

        Button {
            starStore.toggle(identity(file))
        } label: {
            Label(starStore.isStarred(identity(file)) ? "Unstar" : "Star", systemImage: starStore.isStarred(identity(file)) ? "star.slash" : "star")
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
                if !isSelecting { bulkDeletion.clearSelection() }
            }
            .disabled(s3Service.recentFiles.isEmpty || bulkDeletion.isDeleting)
        }
        ToolbarItem(placement: .topBarTrailing) {
            trailingToolbarContent
        }
    }

    private var trailingToolbarContent: some View {
        HStack(spacing: 12) {
            if isSelecting {
                Button {
                    bulkDeletion.captureConfirmation()
                    showBulkDeleteConfirm = true
                } label: {
                    Text("Delete (\(bulkDeletion.confirmationCount))")
                        .foregroundStyle(bulkDeletion.selected.isEmpty ? Color.secondary : Color.red)
                }
                .disabled(bulkDeletion.selected.isEmpty || bulkDeletion.isDeleting)
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
                    Label("Reset Recent Cache", systemImage: "arrow.clockwise.circle")
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
        let tags = tagStore.allTags(in: s3Service.session.configuration.account)
        let hasStarred = starStore.hasStars(in: s3Service.session.configuration.account)
        if !tags.isEmpty || hasStarred || annotationFilter.isActive {
            HStack(spacing: 12) {
                if !tags.isEmpty {
                    Picker("Tag", selection: $annotationFilter.tag) {
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
                    .onChange(of: annotationFilter.tag) { _, _ in
                        if annotationFilter.tag != nil { annotationFilter.starredOnly = false }
                    }
                }

                if hasStarred {
                    Button {
                        annotationFilter.starredOnly.toggle()
                        if annotationFilter.starredOnly { annotationFilter.tag = nil }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: annotationFilter.starredOnly ? "star.fill" : "star")
                                .font(.caption)
                            Text("Starred")
                                .font(.subheadline)
                                .fontWeight(annotationFilter.starredOnly ? .semibold : .regular)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(annotationFilter.starredOnly ? Color.yellow.opacity(0.85) : Color(.secondarySystemFill), in: Capsule())
                        .foregroundStyle(annotationFilter.starredOnly ? Color.black : Color.primary)
                    }
                    .buttonStyle(.plain)
                }

                if annotationFilter.isActive {
                    Button("Clear Filters") { clearFilters() }
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

    private func identity(_ file: S3Object) -> LocalObjectIdentity { s3Service.annotationIdentity(for: file) }

    private func reconcileAnnotationFilter() {
        let account = s3Service.session.configuration.account
        annotationFilter.reconcile(availableTags: tagStore.allTags(in: account), hasStars: starStore.hasStars(in: account))
    }

    private func clearFilters() {
        annotationFilter.clear()
        searchText = ""
        fileTypeFilterRaw = FileTypeFilter.all.rawValue
    }

    private func refreshRecentFiles(force: Bool = false) async {
        let generation = s3Service.session.generation
        let account = s3Service.session.configuration.account
        let requestID = UUID()
        refreshRequestID = requestID
        do {
            try await s3Service.fetchRecentFilesFromAllBuckets(limit: 50, typeFilter: fileTypeFilter, force: force)
            guard s3Service.session.isCurrent(generation), refreshRequestID == requestID else { return }

            // Compute new file keys before marking seen, grouped by bucket
            var discoveredNewKeys: Set<LocalObjectIdentity> = []
            let filesByBucket = Dictionary(grouping: s3Service.recentFiles, by: { $0.bucket ?? s3Service.currentBucket })
            for (bucket, files) in filesByBucket {
                guard s3Service.session.isCurrent(generation), refreshRequestID == requestID else { return }
                let keys = files.map { $0.key }
                // Only report new items when we have a prior seen record (not first visit)
                if await SeenPhotosTracker.shared.hasSeenPhotos(for: bucket, account: account) {
                    let newKeys = await SeenPhotosTracker.shared.findNewPhotos(currentPhotos: keys, bucket: bucket, account: account)
                    discoveredNewKeys.formUnion(newKeys.map { LocalObjectIdentity(account: account, bucket: bucket, key: $0) })
                }
                if !keys.isEmpty {
                    await SeenPhotosTracker.shared.markAsSeen(photoKeys: keys, bucket: bucket, account: account)
                }
            }

            await MainActor.run {
                if s3Service.session.isCurrent(generation), refreshRequestID == requestID { newFileKeys = discoveredNewKeys }
            }
        } catch is CancellationError {
            return
        } catch {
            logger.error("Failed to fetch recent files: \(error.localizedDescription)")
        }
        guard s3Service.session.isCurrent(generation), refreshRequestID == requestID else { return }
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
        let generation = s3Service.session.generation
        let account = s3Service.session.configuration.account
        let requestID = UUID()
        refreshRequestID = requestID

        do {
            try await s3Service.fetchRecentFilesFromAllBuckets(limit: 50, typeFilter: fileTypeFilter)
            guard s3Service.session.isCurrent(generation), refreshRequestID == requestID else { return }

            // Compute new keys across all buckets (all file types), grouped by bucket
            var discoveredNewKeys: Set<LocalObjectIdentity> = []
            var allNewPhotoKeys: [LocalObjectIdentity] = []
            let filesByBucket = Dictionary(grouping: s3Service.recentFiles, by: { $0.bucket ?? s3Service.currentBucket })
            for (bucket, files) in filesByBucket {
                guard s3Service.session.isCurrent(generation), refreshRequestID == requestID else { return }
                let keys = files.map { $0.key }
                if await SeenPhotosTracker.shared.hasSeenPhotos(for: bucket, account: account) {
                    let newKeys = await SeenPhotosTracker.shared.findNewPhotos(currentPhotos: keys, bucket: bucket, account: account)
                    discoveredNewKeys.formUnion(newKeys.map { LocalObjectIdentity(account: account, bucket: bucket, key: $0) })
                    // Collect new image keys for auto-preview
                    let newImageKeys = newKeys.filter { key in
                        files.first(where: { $0.key == key })?.fileType == .image
                    }
                    allNewPhotoKeys.append(contentsOf: newImageKeys.map { LocalObjectIdentity(account: account, bucket: bucket, key: $0) })
                }
                if !keys.isEmpty {
                    await SeenPhotosTracker.shared.markAsSeen(photoKeys: keys, bucket: bucket, account: account)
                }
            }

            await MainActor.run {
                if s3Service.session.isCurrent(generation), refreshRequestID == requestID { newFileKeys = discoveredNewKeys }
            }

            // Auto-preview the newest new photo
            if let newestNewKey = allNewPhotoKeys.first,
               let newestPhoto = imageFiles.first(where: { identity($0) == newestNewKey }) {
                logger.info("Auto-previewing new photo: \(newestNewKey.key)")
                await MainActor.run {
                    if s3Service.session.isCurrent(generation), refreshRequestID == requestID { autoPreviewPhoto = newestPhoto }
                }
            }
        } catch is CancellationError {
            return
        } catch {
            logger.error("Failed to fetch recent files: \(error.localizedDescription)")
        }

        guard s3Service.session.isCurrent(generation), refreshRequestID == requestID else { return }
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
        let request = s3Service.makeObjectTransferRequest(kind: .rename,
            key: file.key, to: newKey, sourceBucket: file.bucket)
        await performTransfer(request)
    }

    private func performTransfer(_ request: ObjectTransferRequest, approval: ObjectReplacementApproval? = nil,
                                 encryptionDecision: CopyEncryptionDecision = .automatic) async {
        do {
            try await s3Service.performObjectTransfer(request, approval: approval, encryptionDecision: encryptionDecision)
        } catch let requirement as CopyEncryptionRequirement {
            copyEncryptionPrompt = CopyEncryptionPrompt(requirement: requirement) { decision in
                Task { await performTransfer(request, approval: approval, encryptionDecision: decision) }
            }
        } catch ObjectTransferError.confirmationRequired(let conflict) {
            transferEncryptionDecision = encryptionDecision
            transferConflict = conflict
        } catch {
            logger.error("Rename failed: \(error.localizedDescription)")
            await MainActor.run {
                renameErrorMessage = error.localizedDescription
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

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import os.log

private let starStore = StarStore.shared

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
    case grid
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
    @AppStorage("s3BrowserGridCardSize") private var gridCardSize: Double = 100
    @State private var showingSortMenu = false
    @State private var searchText = ""
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false
    @State private var selectedPhoto: PhotosPickerItem? = nil
    @State private var isUploading = false
    @State private var uploadProgress: Double = 0
    @State private var uploadResult: UploadResult? = nil
    @State private var isDragTargeted = false
    @State private var renameTarget: S3Object? = nil
    @State private var renameText = ""
    @State private var showRenameError = false
    @State private var renameErrorMessage = ""
    @State private var moveCopyTarget: S3Object? = nil
    @State private var moveCopyMode: PrefixPickerSheet.Mode = .copy
    @State private var showMoveCopyError = false
    @State private var moveCopyErrorMessage = ""
    @State private var showDeleteError = false
    @State private var deleteErrorMessage = ""

    // New folder state
    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var showNewFolderError = false
    @State private var newFolderErrorMessage = ""

    // Selection state
    @State private var isSelecting = false
    @State private var selectedKeys: Set<String> = []
    @State private var showBulkDeleteConfirm = false
    @State private var isBulkDeleting = false

    enum UploadResult {
        case success(String)
        case failure(String)
    }

    private let logger = Logger(subsystem: "com.s3browser", category: "BucketBrowserView")

    private var viewStyle: ViewStyle {
        get {
            switch viewStyleRaw {
            case "compact": return .compact
            case "grid": return .grid
            default: return .standard
            }
        }
        set {
            switch newValue {
            case .compact: viewStyleRaw = "compact"
            case .grid: viewStyleRaw = "grid"
            case .standard: viewStyleRaw = "standard"
            }
        }
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

            Button {
                viewStyleRaw = "grid"
            } label: {
                Label("Grid", systemImage: viewStyle == .grid ? "checkmark" : "")
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
                    } else if !searchText.isEmpty && sortedItems.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                    } else if viewStyle == .grid {
                        gridContent
                    } else {
                        listContent
                    }
                }
                .onDrop(of: [.fileURL, .data], isTargeted: isConfigured ? $isDragTargeted : .constant(false)) { providers in
                    guard isConfigured else { return false }
                    Task { await handleDrop(providers: providers) }
                    return true
                }
                .overlay {
                    if isDragTargeted {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.accentColor, lineWidth: 3)
                            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                            .overlay {
                                VStack(spacing: 8) {
                                    Image(systemName: "arrow.down.doc")
                                        .font(.system(size: 36))
                                    Text("Drop to upload")
                                        .font(.headline)
                                }
                                .foregroundStyle(Color.accentColor)
                            }
                            .padding(8)
                            .allowsHitTesting(false)
                    }
                }
                .navigationTitle("S3 Browser")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        if isSelecting {
                            HStack(spacing: 12) {
                                Button("Cancel") {
                                    isSelecting = false
                                    selectedKeys.removeAll()
                                }
                                if selectedKeys.count == sortedItems.filter({ !$0.isFolder }).count {
                                    Button("Deselect All") { selectedKeys.removeAll() }
                                } else {
                                    Button("Select All") {
                                        selectedKeys = Set(sortedItems.compactMap { item -> String? in
                                            if case .file(let o) = item { return o.key }
                                            return nil
                                        })
                                    }
                                }
                            }
                        } else {
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
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        if isSelecting {
                            HStack(spacing: 12) {
                                if !selectedKeys.isEmpty {
                                    Button(role: .destructive) {
                                        showBulkDeleteConfirm = true
                                    } label: {
                                        Label("Delete (\(selectedKeys.count))", systemImage: "trash")
                                    }
                                    .disabled(isBulkDeleting)
                                }
                            }
                        } else {
                            HStack(spacing: 12) {
                                if isConfigured && !s3Service.items.isEmpty {
                                    Button("Select") { isSelecting = true }
                                }
                                if viewStyle == .grid {
                                    Slider(value: $gridCardSize, in: 60...160, step: 10)
                                        .frame(width: 80)
                                }
                                Menu {
                                    filterMenuContent
                                        .menuActionDismissBehavior(.disabled)
                                    sortMenuContent
                                    viewStyleMenuContent
                                } label: {
                                    Image(systemName: "line.3.horizontal.decrease.circle")
                                }
                                Menu {
                                    Button {
                                        showPhotoPicker = true
                                    } label: {
                                        Label("Photo or Video", systemImage: "photo")
                                    }
                                    Button {
                                        showFilePicker = true
                                    } label: {
                                        Label("File", systemImage: "doc")
                                    }
                                    Divider()
                                    Button {
                                        newFolderName = ""
                                        showNewFolderAlert = true
                                    } label: {
                                        Label("New Folder", systemImage: "folder.badge.plus")
                                    }
                                } label: {
                                    Image(systemName: "plus")
                                }
                                .disabled(!isConfigured || isUploading)
                            }
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
            .onChange(of: s3Service.currentPrefix) { _, _ in
                isSelecting = false
                selectedKeys.removeAll()
            }
            .onChange(of: s3Service.currentBucket) { _, _ in
                isSelecting = false
                selectedKeys.removeAll()
            }
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
                if let file = renameTarget { Text(file.fileName) }
            }
            .alert("Rename Failed", isPresented: $showRenameError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(renameErrorMessage)
            }
            .sheet(item: $moveCopyTarget) { object in
                PrefixPickerSheet(
                    s3Service: s3Service,
                    sourceBucket: s3Service.currentBucket,
                    sourceObject: object,
                    mode: moveCopyMode
                ) { destPrefix in
                    await performMoveCopy(object: object, destPrefix: destPrefix)
                }
            }
            .alert("Operation Failed", isPresented: $showMoveCopyError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(moveCopyErrorMessage)
            }
            .deleteErrorAlert(isPresented: $showDeleteError, message: deleteErrorMessage)
            .confirmationDialog(bulkDeleteTitle, isPresented: $showBulkDeleteConfirm, titleVisibility: .visible) {
                Button(bulkDeleteButtonLabel, role: .destructive) {
                    Task { await bulkDelete() }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("New Folder", isPresented: $showNewFolderAlert) {
                TextField("Folder name", text: $newFolderName)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Create") {
                    let name = newFolderName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty, !name.contains("/") else { return }
                    Task {
                        do {
                            try await s3Service.createFolder(named: name, prefix: s3Service.currentPrefix)
                            await refreshFiles()
                        } catch {
                            newFolderErrorMessage = error.localizedDescription
                            showNewFolderError = true
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enter a name for the new folder.")
            }
            .alert("Create Failed", isPresented: $showNewFolderError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(newFolderErrorMessage)
            }
            .searchable(text: $searchText, prompt: searchPrompt)
            .safeAreaInset(edge: .bottom) {
                if isUploading || uploadResult != nil {
                    uploadStatusBar
                }
            }
            .photosPicker(
                isPresented: $showPhotoPicker,
                selection: $selectedPhoto,
                matching: .any(of: [.images, .videos]),
                photoLibrary: .shared()
            )
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false
            ) { result in
                Task { await handleFileImport(result) }
            }
            .onChange(of: selectedPhoto) { _, item in
                guard let item else { return }
                Task { await handlePhotoPickerItem(item) }
            }
        }
    }

    // MARK: - Upload status bar

    private var uploadStatusBar: some View {
        VStack(spacing: 0) {
            Divider()
            Group {
                if isUploading {
                    VStack(spacing: 6) {
                        ProgressView(value: uploadProgress)
                            .progressViewStyle(.linear)
                        Text(uploadProgress < 1 ? "Uploading \(Int(uploadProgress * 100))%..." : "Finishing...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                } else if let result = uploadResult {
                    HStack(spacing: 10) {
                        switch result {
                        case .success(let key):
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text(URL(string: key)?.lastPathComponent ?? key)
                                .font(.subheadline)
                                .lineLimit(1)
                        case .failure(let msg):
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                            Text(msg)
                                .font(.subheadline)
                                .lineLimit(2)
                        }
                        Spacer()
                        Button { uploadResult = nil } label: {
                            Image(systemName: "xmark")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                }
            }
            .background(Color(.secondarySystemBackground))
        }
    }

    // MARK: - Upload handlers

    private func handlePhotoPickerItem(_ item: PhotosPickerItem) async {
        defer { Task { @MainActor in selectedPhoto = nil } }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            let base = (item.itemIdentifier ?? "photo")
                .components(separatedBy: "/").last ?? "photo"
            let filename = base.hasSuffix(".jpg") || base.hasSuffix(".png") ? base : base + ".jpg"
            let contentType = filename.hasSuffix(".png") ? "image/png" : "image/jpeg"
            await upload(data: data, filename: filename, contentType: contentType)
        } catch {
            logger.error("Photo picker load failed: \(error.localizedDescription)")
            await MainActor.run { uploadResult = .failure(error.localizedDescription) }
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) async {
        switch result {
        case .failure(let error):
            logger.error("File import failed: \(error.localizedDescription)")
            await MainActor.run { uploadResult = .failure(error.localizedDescription) }
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                let filename = url.lastPathComponent
                let contentType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                    ?? "application/octet-stream"
                await upload(data: data, filename: filename, contentType: contentType)
            } catch {
                logger.error("File read failed: \(error.localizedDescription)")
                await MainActor.run { uploadResult = .failure(error.localizedDescription) }
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) async {
        await withTaskGroup(of: Void.self) { group in
            for provider in providers {
                group.addTask {
                    // Prefer a file URL so we can read large files without loading all bytes at once.
                    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                        await withCheckedContinuation { continuation in
                            provider.loadFileRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { url, error in
                                guard let url, error == nil else { continuation.resume(); return }
                                let accessing = url.startAccessingSecurityScopedResource()
                                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                                guard let data = try? Data(contentsOf: url) else { continuation.resume(); return }
                                let filename = url.lastPathComponent
                                let contentType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                                    ?? "application/octet-stream"
                                Task { await self.upload(data: data, filename: filename, contentType: contentType) }
                                continuation.resume()
                            }
                        }
                    } else {
                        // Fallback: load raw data.
                        let types = provider.registeredTypeIdentifiers
                        guard let typeID = types.first else { return }
                        await withCheckedContinuation { continuation in
                            provider.loadDataRepresentation(forTypeIdentifier: typeID) { data, error in
                                guard let data, error == nil else { continuation.resume(); return }
                                let filename = provider.suggestedName ?? "dropped-file"
                                let contentType = UTType(typeID)?.preferredMIMEType ?? "application/octet-stream"
                                Task { await self.upload(data: data, filename: filename, contentType: contentType) }
                                continuation.resume()
                            }
                        }
                    }
                }
            }
        }
    }

    private func upload(data: Data, filename: String, contentType: String) async {
        let prefix = s3Service.currentPrefix
        let key = prefix.isEmpty ? filename : "\(prefix)\(filename)"
        await MainActor.run {
            isUploading = true
            uploadProgress = 0
            uploadResult = nil
        }
        do {
            try await s3Service.uploadObject(
                data: data,
                key: key,
                contentType: contentType,
                onProgress: { fraction in
                    self.uploadProgress = fraction
                }
            )
            logger.info("Uploaded \(key) to \(s3Service.currentBucket)")
            await MainActor.run {
                isUploading = false
                uploadResult = .success(key)
            }
            await refreshFiles()
        } catch {
            logger.error("Upload failed for \(key): \(error.localizedDescription)")
            await MainActor.run {
                isUploading = false
                uploadResult = .failure(error.localizedDescription)
            }
        }
    }

    private func fileContextMenuItems(for object: S3Object) -> some View {
        Group {
            if object.fileType == .image || object.fileType == .text || object.fileType == .log {
                Button {
                    Task { await copyToClipboard(object) }
                } label: {
                    Label("Copy Content", systemImage: "doc.on.doc")
                }
            }

            if object.fileType == .video, let url = s3Service.getPublicURL(for: object.key) {
                ShareLink(item: url) {
                    Label("Share Link", systemImage: "square.and.arrow.up")
                }
            }

            Button {
                starStore.toggle(object.key)
            } label: {
                Label(starStore.isStarred(object.key) ? "Unstar" : "Star", systemImage: starStore.isStarred(object.key) ? "star.slash" : "star")
            }

            Button {
                moveCopyMode = .move
                moveCopyTarget = object
            } label: {
                Label("Move to…", systemImage: "arrow.forward.circle")
            }

            Button {
                moveCopyMode = .copy
                moveCopyTarget = object
            } label: {
                Label("Copy to…", systemImage: "doc.on.doc")
            }

            Button {
                renameText = object.fileName
                renameTarget = object
            } label: {
                Label("Rename…", systemImage: "pencil")
            }

            Button(role: .destructive) {
                Task { await deleteObject(object) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var listContent: some View {
        List {
            ForEach(sortedItems) { item in
                switch item {
                case .folder(let folder):
                    Button(action: {
                        guard !isSelecting else { return }
                        Task {
                            searchText = ""
                            try? await s3Service.navigateToFolder(folder.prefix)
                            savedPrefix = s3Service.currentPrefix
                        }
                    }) {
                        FolderRow(folder: folder)
                    }
                case .file(let object):
                    if isSelecting {
                        Button {
                            if selectedKeys.contains(object.key) {
                                selectedKeys.remove(object.key)
                            } else {
                                selectedKeys.insert(object.key)
                            }
                        } label: {
                            HStack {
                                Image(systemName: selectedKeys.contains(object.key)
                                      ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedKeys.contains(object.key) ? .blue : .secondary)
                                if viewStyle == .standard {
                                    FileRow(object: object)
                                } else {
                                    CompactFileRow(object: object)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    } else {
                        NavigationLink(destination: FileDetailView(object: object, service: s3Service)) {
                            if viewStyle == .standard {
                                FileRow(object: object)
                            } else {
                                CompactFileRow(object: object)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                Task { await deleteObject(object) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .contextMenu { fileContextMenuItems(for: object) }
                    }
                }
            }
        }
        .refreshable { await refreshFiles() }
    }

    private var gridContent: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: gridCardSize), spacing: 10)], spacing: 10) {
                ForEach(sortedItems) { item in
                    switch item {
                    case .folder(let folder):
                        Button {
                            guard !isSelecting else { return }
                            Task {
                                searchText = ""
                                try? await s3Service.navigateToFolder(folder.prefix)
                                savedPrefix = s3Service.currentPrefix
                            }
                        } label: {
                            BrowserGridItem(item: .folder(folder), cardSize: gridCardSize)
                        }
                        .buttonStyle(.plain)
                    case .file(let object):
                        if isSelecting {
                            Button {
                                if selectedKeys.contains(object.key) {
                                    selectedKeys.remove(object.key)
                                } else {
                                    selectedKeys.insert(object.key)
                                }
                            } label: {
                                ZStack(alignment: .topLeading) {
                                    BrowserGridItem(item: .file(object), cardSize: gridCardSize)
                                    Image(systemName: selectedKeys.contains(object.key)
                                          ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 20, weight: .semibold))
                                        .foregroundStyle(selectedKeys.contains(object.key) ? .blue : .white)
                                        .shadow(color: .black.opacity(0.4), radius: 2)
                                        .padding(4)
                                }
                            }
                            .buttonStyle(.plain)
                        } else {
                            NavigationLink(destination: FileDetailView(object: object, service: s3Service)) {
                                BrowserGridItem(item: .file(object), cardSize: gridCardSize)
                            }
                            .contextMenu { fileContextMenuItems(for: object) }
                        }
                    }
                }
            }
            .padding(10)
        }
        .refreshable { await refreshFiles() }
    }

    private var sortedItems: [S3Item] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let filtered = s3Service.items.filter { item in
            switch item {
            case .folder(let folder):
                if query.isEmpty { return true }
                return folder.folderName.localizedCaseInsensitiveContains(query)
            case .file(let object):
                if !fileTypeFilter.matches(object.fileType) { return false }
                if query.isEmpty { return true }
                return object.fileName.localizedCaseInsensitiveContains(query)
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

    private var bulkDeleteTitle: String {
        let n = selectedKeys.count
        return "Delete \(n) file\(n == 1 ? "" : "s")?"
    }

    private var bulkDeleteButtonLabel: String {
        let n = selectedKeys.count
        return "Delete \(n) File\(n == 1 ? "" : "s")"
    }

    private var searchPrompt: String {
        if s3Service.currentPrefix.isEmpty {
            return "Search in \(s3Service.currentBucket)"
        }
        let last = s3Service.currentPrefix.split(separator: "/").last.map(String.init)
        return "Search in \(last ?? s3Service.currentPrefix)"
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
            await MainActor.run {
                deleteErrorMessage = "Could not delete \(object.fileName): \(error.localizedDescription)"
                showDeleteError = true
            }
        }
    }

    private func bulkDelete() async {
        let keys = selectedKeys
        let bucket = s3Service.currentBucket
        isBulkDeleting = true
        var failedKeys: [String] = []
        await withTaskGroup(of: (String, Error?).self) { group in
            for key in keys {
                group.addTask {
                    do {
                        try await self.s3Service.deleteObject(key: key, bucket: bucket)
                        return (key, nil)
                    } catch {
                        return (key, error)
                    }
                }
            }
            for await (key, error) in group {
                if let error {
                    logger.error("Bulk delete failed for \(key): \(error.localizedDescription)")
                    failedKeys.append(key)
                }
            }
        }
        await MainActor.run {
            isBulkDeleting = false
            isSelecting = false
            selectedKeys.removeAll()
            if !failedKeys.isEmpty {
                deleteErrorMessage = "Could not delete \(failedKeys.count) file\(failedKeys.count == 1 ? "" : "s")."
                showDeleteError = true
            }
        }
        await refreshFiles()
    }

    private func performMoveCopy(object: S3Object, destPrefix: String) async {
        let filename = object.fileName
        let destKey = destPrefix.isEmpty ? filename : "\(destPrefix)\(filename)"
        let bucket = s3Service.currentBucket
        do {
            try await s3Service.copyObject(
                key: object.key,
                to: destKey,
                sourceBucket: bucket,
                destBucket: bucket
            )
            if moveCopyMode == .move {
                try await s3Service.deleteObject(key: object.key, bucket: bucket)
            }
            logger.info("\(moveCopyMode == .move ? "Moved" : "Copied") \(object.key) -> \(destKey)")
            await refreshFiles()
        } catch {
            logger.error("Move/copy failed for \(object.key): \(error.localizedDescription)")
            await MainActor.run {
                moveCopyErrorMessage = error.localizedDescription
                showMoveCopyError = true
            }
        }
    }

    private func renameFile(_ file: S3Object, to newKey: String) async {
        renameTarget = nil
        do {
            try await s3Service.renameObject(key: file.key, to: newKey, bucket: file.bucket)
            logger.info("Renamed \(file.key) -> \(newKey)")
            await refreshFiles()
        } catch {
            logger.error("Rename failed for \(file.key): \(error.localizedDescription)")
            await MainActor.run {
                renameErrorMessage = "Could not rename \(file.fileName): \(error.localizedDescription)"
                showRenameError = true
            }
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
            ZStack(alignment: .bottomTrailing) {
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

                if starStore.isStarred(object.key) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.yellow)
                        .padding(2)
                        .background(Color.black.opacity(0.35), in: Circle())
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

struct BrowserGridItem: View {
    let item: S3Item
    let cardSize: Double
    @State private var thumbnail: UIImage?

    private var iconColor: Color {
        guard case .file(let obj) = item else { return .blue }
        switch obj.fileType {
        case .log: return .blue
        case .image: return .purple
        case .video: return .orange
        case .text: return .green
        case .html: return .teal
        case .unknown: return .gray
        }
    }

    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                ZStack {
                    switch item {
                    case .folder(let folder):
                        Image(systemName: "folder.fill")
                            .font(.system(size: cardSize > 100 ? 32 : 22))
                            .foregroundStyle(.blue)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .file(let object):
                        if let thumbnail = thumbnail {
                            Image(uiImage: thumbnail)
                                .resizable()
                                .scaledToFill()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .clipped()
                        } else {
                            Image(systemName: object.fileType.icon)
                                .font(.system(size: cardSize > 100 ? 28 : 18))
                                .foregroundStyle(iconColor)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }

                        if case .file(let obj) = item, obj.fileType == .video {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: cardSize > 100 ? 28 : 18))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.5), radius: 3)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(height: cardSize)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(8)

                if case .file(let obj) = item, starStore.isStarred(obj.key) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.yellow)
                        .padding(2)
                        .background(Color.black.opacity(0.35), in: Circle())
                        .padding(4)
                }
            }

            VStack(alignment: .center, spacing: 2) {
                Text(item.displayName)
                    .font(cardSize > 100 ? .caption : .system(size: 9))
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                if case .file(let object) = item {
                    Text(object.formattedSize)
                        .font(.system(size: cardSize > 100 ? 10 : 8))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .task {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        guard case .file(let object) = item,
              object.fileType == .image || object.fileType == .video else { return }

        if let cached = await ImageCacheActor.shared.getThumbnail(for: object.key) {
            await MainActor.run { self.thumbnail = cached }
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

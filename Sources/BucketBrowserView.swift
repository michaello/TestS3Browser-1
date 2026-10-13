import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import os.log

@MainActor private let starStore = StarStore.shared

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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var rowProjection = DerivedRowsCache<[S3Item]>()
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
    @State private var uploadInputTask: Task<Void, Never>?
    @State private var isUploading = false
    @State private var uploadProgress: Double = 0
    @State private var uploadResult: UploadResult? = nil
    @State private var isDragTargeted = false
    @State private var renameTarget: S3Object? = nil
    @State private var renameText = ""
    @State private var showRenameAlert = false
    @State private var showRenameError = false
    @State private var renameErrorMessage = ""
    @State private var moveCopyTarget: S3Object? = nil
    @State private var moveCopyMode: PrefixPickerSheet.Mode = .copy
    @State private var showMoveCopyError = false
    @State private var moveCopyErrorMessage = ""
    @State private var transferConflict: ObjectTransferConflict?
    @State private var copyEncryptionPrompt: CopyEncryptionPrompt?
    @State private var transferEncryptionDecision: CopyEncryptionDecision = .automatic
    @State private var pendingMoveCopyRequest: ObjectTransferRequest?
    @State private var showDeleteError = false
    @State private var deleteErrorMessage = ""

    // New folder state
    @State private var showNewFolderAlert = false

    // Selection state
    @State private var isSelecting = false
    @State private var selectedKeys: Set<String> = []
    @State private var showBulkDeleteConfirm = false
    @State private var isBulkDeleting = false

    // Batch download state
    @State private var isBatchDownloading = false
    @State private var batchDownloadProgress = 0
    @State private var batchDownloadTotal = 0
    @State private var batchDownloadURLs: [URL]? = nil
    @State private var showBatchDownloadShare = false
    @State private var batchDownloadError: String? = nil
    @State private var showBatchDownloadError = false
    @State private var batchExport: BatchFileExport?
    @State private var batchExportTask: Task<Void, Never>?

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
        AuditTelemetry.shared.measureViewConstruction(.browse) { measuredContent }
    }

    private var measuredContent: some View {
        NavigationStack {
            navigationContent
        }
        .alert("Rename File", isPresented: $showRenameAlert) {
            TextField("New filename", text: $renameText).autocorrectionDisabled()
            Button("Rename") {
                guard let file = renameTarget else { return }
                let newName = renameText.trimmingCharacters(in: .whitespaces)
                guard !newName.isEmpty else { renameTarget = nil; showRenameAlert = false; return }
                let newKey = S3TransferKeys.parentPrefix(of: file.key) + newName
                Task { await renameFile(file, to: newKey) }
            }
            Button("Cancel", role: .cancel) { renameTarget = nil; showRenameAlert = false }
        } message: {
            if let file = renameTarget { Text(file.fileName) }
        }
        .alert("Rename Failed", isPresented: $showRenameError) {
            Button("OK", role: .cancel) {}
        } message: { Text(renameErrorMessage) }
        .sheet(item: $moveCopyTarget, onDismiss: performPendingMoveCopy) { object in
            PrefixPickerSheet(
                s3Service: s3Service,
                sourceBucket: object.bucket ?? s3Service.currentBucket,
                sourceObject: object,
                mode: moveCopyMode
            ) { destPrefix in
                performMoveCopy(object: object, destPrefix: destPrefix)
            }
        }
        .alert("Operation Failed", isPresented: $showMoveCopyError) {
            Button("OK", role: .cancel) {}
        } message: { Text(moveCopyErrorMessage) }
        .objectTransferConfirmation(conflict: $transferConflict) { request, approval in
            await performTransfer(request, approval: approval, encryptionDecision: transferEncryptionDecision)
        }
        .copyEncryptionConfirmation(prompt: $copyEncryptionPrompt)
        .deleteErrorAlert(isPresented: $showDeleteError, message: deleteErrorMessage)
        .confirmationDialog(bulkDeleteTitle, isPresented: $showBulkDeleteConfirm, titleVisibility: .visible) {
            Button(bulkDeleteButtonLabel, role: .destructive) { Task { await bulkDelete() } }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showNewFolderAlert) {
            NewFolderSheet(service: s3Service, context: UploadContext(service: s3Service)) {
                await refreshFiles(force: true)
            }
        }
        .sheet(isPresented: $showBatchDownloadShare, onDismiss: onBatchDownloadShareDismiss) {
            batchDownloadShareContent
        }
        .alert("Download Failed", isPresented: $showBatchDownloadError) {
            Button("OK", role: .cancel) {}
        } message: { Text(batchDownloadError ?? "") }
    }

    private var navigationContent: some View {
        VStack(spacing: 0) {
            breadcrumbBar
            mainContent
                .onDrop(of: [.fileURL, .data], isTargeted: isConfigured ? $isDragTargeted : .constant(false)) { providers in
                    guard isConfigured else { return false }
                    let context = UploadContext(service: s3Service)
                    uploadInputTask?.cancel()
                    uploadInputTask = Task { await handleDrop(providers: providers, context: context) }
                    return true
                }
                .overlay { dragOverlay }
                .navigationTitle("S3 Browser")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { leadingToolbar }
                    ToolbarItem(placement: .topBarTrailing) { trailingToolbar }
                }
        }
        .task { await initialLoad() }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active, isConfigured else { return }
            Task { await refreshFiles() }
        }
        .onChange(of: s3Service.config) { _, _ in
            Task { await refreshFiles() }
        }
        .onChange(of: s3Service.session.confirmedRoute) { _, route in
            guard let route else { return }
            savedPrefix = route.prefix
            savedBucket = route.bucket
        }
        .onChange(of: s3Service.currentPrefix) { _, _ in
            isSelecting = false
            selectedKeys.removeAll()
        }
        .onChange(of: s3Service.currentBucket) { _, _ in
            isSelecting = false
            selectedKeys.removeAll()
        }
        .onDisappear {
            uploadInputTask?.cancel()
            let task = batchExportTask, owner = batchExport
            task?.cancel()
            if !showBatchDownloadShare {
                Task { await task?.value; await owner?.close() }
            }
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            let context = UploadContext(service: s3Service)
            uploadInputTask?.cancel()
            uploadInputTask = Task { await handlePhotoPickerItem(item, context: context) }
        }
        .searchable(text: $searchText, prompt: searchPrompt)
        .safeAreaInset(edge: .bottom) { bottomStatusBar }
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
            let context = UploadContext(service: s3Service)
            uploadInputTask?.cancel()
            uploadInputTask = Task { await handleFileImport(result, context: context) }
        }
    }

    @ViewBuilder
    private var breadcrumbBar: some View {
        if isConfigured && !s3Service.currentPrefix.isEmpty {
            BreadcrumbView(
                pathComponents: s3Service.getPathComponents(),
                onTapIndex: { index in Task { try? await s3Service.navigateToBreadcrumb(index) } },
                onTapRoot: {
                    Task {
                        s3Service.currentPrefix = ""
                        try? await s3Service.listObjects()
                    }
                }
            )
        }
    }

    @ViewBuilder
    private var dragOverlay: some View {
        if isDragTargeted {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor, lineWidth: 3)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.down.doc").font(.system(size: 36))
                        Text("Drop to upload").font(.headline)
                    }
                    .foregroundStyle(Color.accentColor)
                }
                .padding(8)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var leadingToolbar: some View {
        if isSelecting {
            HStack(spacing: 12) {
                Button("Cancel") {
                    isSelecting = false
                    selectedKeys.removeAll()
                }
                let fileCount = sortedItems.filter { !$0.isFolder }.count
                if selectedKeys.count == fileCount {
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
                        } catch {
                            logger.error("Failed to switch bucket: \(error.localizedDescription)")
                        }
                    }
                }
            )
        }
    }

    @ViewBuilder
    private var trailingToolbar: some View {
        if isSelecting {
            selectingTrailingToolbar
        } else {
            browsingTrailingToolbar
        }
    }

    @ViewBuilder
    private var selectingTrailingToolbar: some View {
        if !selectedKeys.isEmpty {
            HStack(spacing: 12) {
                Button {
                    startBatchDownload()
                } label: {
                    Label("Download (\(selectedKeys.count))", systemImage: "arrow.down.to.line")
                }
                .disabled(isBatchDownloading || isBulkDeleting)
                Button(role: .destructive) {
                    showBulkDeleteConfirm = true
                } label: {
                    Label("Delete (\(selectedKeys.count))", systemImage: "trash")
                }
                .disabled(isBulkDeleting || isBatchDownloading)
            }
        }
    }

    private var browsingTrailingToolbar: some View {
        HStack(spacing: 12) {
            if isConfigured && !s3Service.items.isEmpty {
                Button("Select") { isSelecting = true }
            }
            if viewStyle == .grid {
                Slider(value: $gridCardSize, in: 60...160, step: 10).frame(width: 80)
            }
            Menu {
                filterMenuContent.menuActionDismissBehavior(.disabled)
                sortMenuContent
                viewStyleMenuContent
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
            Menu {
                Button { showPhotoPicker = true } label: { Label("Photo or Video", systemImage: "photo") }
                Button { showFilePicker = true } label: { Label("File", systemImage: "doc") }
                Divider()
                Button {
                    showNewFolderAlert = true
                } label: { Label("New Folder", systemImage: "folder.badge.plus") }
            } label: {
                Image(systemName: "plus")
            }
            .disabled(!isConfigured || isUploading)
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
                            Text(S3TransferKeys.fileName(of: key))
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

    // MARK: - Bottom status bars

    @ViewBuilder
    private var bottomStatusBar: some View {
        if isBatchDownloading {
            batchDownloadStatusBar
        } else if let owner = batchExport, !owner.failures.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(owner.summary).font(.caption).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Retry Failed") { startBatchDownload(retry: true) }
                    if !owner.urls.isEmpty {
                        Button("Share \(owner.urls.count) Files") {
                            batchDownloadURLs = owner.urls
                            showBatchDownloadShare = true
                        }
                    }
                    Button("Dismiss") { Task { await owner.close() } }
                }
            }
            .padding()
        } else if isUploading || uploadResult != nil {
            uploadStatusBar
        }
    }

    @ViewBuilder
    private var batchDownloadShareContent: some View {
        if let urls = batchDownloadURLs {
            MultiFileActivityView(urls: urls, onDismiss: {
                let owner = batchExport
                showBatchDownloadShare = false
                Task { await owner?.close() }
            })
        }
    }

    private func onBatchDownloadShareDismiss() {
        let owner = batchExport
        Task { await owner?.close() }
        batchDownloadURLs = nil
        isSelecting = false
        selectedKeys.removeAll()
    }

    private var batchDownloadStatusBar: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(spacing: 6) {
                let completed = batchExport?.completed ?? 0
                let total = batchExport?.total ?? 0
                ProgressView(value: total > 0 ? Double(completed) / Double(total) : 0)
                    .progressViewStyle(.linear)
                Text("Downloading \(completed) / \(total)...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Cancel") { batchExportTask?.cancel() }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground))
        }
    }

    // MARK: - Batch download

    private func startBatchDownload(retry: Bool = false) {
        guard !isBatchDownloading else { return }
        let generation = s3Service.session.generation
        let bucket = s3Service.currentBucket
        let listedObjects = s3Service.items.compactMap { item -> S3Object? in
            if case .file(let object) = item { return object }
            return nil
        }
        let items = selectedKeys.map { key in
            let object = listedObjects.first { $0.key.utf8.elementsEqual(key.utf8) } ??
                S3Object(key: key, size: -1, lastModified: .distantPast, etag: nil, bucket: bucket)
            let identity = MediaObjectIdentity(account: s3Service.session.configuration.account,
                bucket: object.bucket ?? bucket, key: key, etag: object.etag, version: nil)
            return BatchExportItem(identity: identity, bytes: object.size)
        }
        let owner: BatchFileExport
        if retry, let existing = batchExport { owner = existing }
        else {
            owner = BatchFileExport { item in
                guard s3Service.session.isCurrent(generation) else { throw CancellationError() }
                let object = S3Object(key: item.identity.key, size: item.bytes, lastModified: .distantPast,
                    etag: item.identity.etag, bucket: item.identity.bucket)
                let lease = try await s3Service.downloadOriginalFile(for: object)
                guard s3Service.session.isCurrent(generation) else {
                    await MediaOriginalStore.shared.release(lease)
                    throw CancellationError()
                }
                return lease
            }
        }
        let previous = batchExport
        batchExport = owner
        isBatchDownloading = true
        batchExportTask = Task {
            if !retry { await previous?.close() }
            defer { isBatchDownloading = false }
            do {
                if retry { try await owner.retryFailures() }
                else { try await owner.prepare(items) }
                guard s3Service.session.isCurrent(generation) else { await owner.close(); return }
                if owner.failures.isEmpty, !owner.urls.isEmpty {
                    batchDownloadURLs = owner.urls
                    showBatchDownloadShare = true
                } else if owner.urls.isEmpty {
                    batchDownloadError = owner.summary
                    showBatchDownloadError = true
                }
            } catch is CancellationError { await owner.close() }
            catch {
                await owner.close()
                batchDownloadError = error.localizedDescription
                showBatchDownloadError = true
            }
        }
    }

    // MARK: - Upload handlers

    private func handlePhotoPickerItem(_ item: PhotosPickerItem, context: UploadContext) async {
        defer { selectedPhoto = nil }
        await prepareUpload(context: context) {
            try await item.loadTransferable(type: ImportedUploadFile.self)?.payload
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>, context: UploadContext) async {
        await prepareUpload(context: context) {
            let urls = try result.get()
            guard let url = urls.first else { return nil }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            return try await ImportedUploadFile.importFile(at: url).payload
        }
    }

    private func prepareUpload(context: UploadContext,
        load: () async throws -> PreparedUploadPayload?) async {
        do {
            try await UploadPreparation.perform(destination: context.destination, load: load,
                isCurrentAccount: { context.matches(s3Service) },
                send: { payload, _ in try await upload(payload, context: context) })
        } catch is CancellationError {
            // Input task ownership ended before a new upload could start.
        } catch {
            logger.error("Upload preparation failed: \(error.localizedDescription)")
            uploadResult = .failure(error.localizedDescription)
        }
    }

    private func upload(_ payload: PreparedUploadPayload, context: UploadContext) async throws {
        let key = context.destination.key(for: payload.filename)
        isUploading = true
        uploadProgress = 0
        uploadResult = nil
        defer { isUploading = false }
        try await UploadQueueManager.shared.upload(payload, key: key, context: context, using: s3Service,
            onProgress: { fraction in uploadProgress = fraction })
        logger.info("Uploaded \(key) to \(context.destination.bucket)")
        uploadResult = .success(key)
        if context.matches(s3Service) { await refreshFiles(force: true) }
    }

    private func handleDrop(providers: [NSItemProvider], context: UploadContext) async {
        // Each provider is awaited under the original captured destination and owned task.
        for provider in providers {
            if Task.isCancelled { return }
            await prepareUpload(context: context) {
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    return try await withCheckedThrowingContinuation { continuation in
                        provider.loadFileRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { url, error in
                            do {
                                if let error { throw error }
                                guard let url else { throw UploadPreparationError.unavailableRepresentation }
                                let accessing = url.startAccessingSecurityScopedResource()
                                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                                let descriptor = UploadFileDescriptor(filenameExtension: url.pathExtension,
                                    contentType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream")
                                let owned = try OwnedUploadInputs.copyWhileAvailable(url, descriptor: descriptor,
                                    filename: url.lastPathComponent)
                                continuation.resume(returning: owned.payload)
                            } catch { continuation.resume(throwing: error) }
                        }
                    }
                }
                guard let type = provider.registeredTypeIdentifiers.first else { return nil }
                return try await withCheckedThrowingContinuation { continuation in
                    provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                        if let error { continuation.resume(throwing: error); return }
                        guard let data else {
                            continuation.resume(throwing: UploadPreparationError.unavailableRepresentation)
                            return
                        }
                        continuation.resume(returning: PreparedUploadPayload(data: data,
                            filename: provider.suggestedName ?? "dropped-file",
                            contentType: UTType(type)?.preferredMIMEType ?? "application/octet-stream"))
                    }
                }
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

            if object.fileType == .video, let url = s3Service.getPublicURL(for: object.key, bucket: object.bucket) {
                ShareLink(item: url) {
                    Label("Share Link", systemImage: "square.and.arrow.up")
                }
            }

            Button {
                starStore.toggle(s3Service.annotationIdentity(for: object))
            } label: {
                Label(starStore.isStarred(s3Service.annotationIdentity(for: object)) ? "Unstar" : "Star", systemImage: starStore.isStarred(s3Service.annotationIdentity(for: object)) ? "star.slash" : "star")
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
                showRenameAlert = true
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

    @ViewBuilder
    private var mainContent: some View {
        if !isConfigured {
            ContentUnavailableView(
                "Configuration Required",
                systemImage: "gear",
                description: Text("Go to Settings to configure your S3 bucket and credentials")
            )
        } else if s3Service.isLoading && s3Service.items.isEmpty {
            VStack(spacing: 8) {
                ProgressView()
                Text(s3Service.loadingStatus.isEmpty ? "Loading..." : s3Service.loadingStatus)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = s3Service.error, s3Service.items.isEmpty {
            ContentUnavailableView {
                Label("Couldn't load files", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Retry") {
                    Task { await refreshFiles(force: true) }
                }
            }
        } else if s3Service.items.isEmpty {
            ScrollView {
                ContentUnavailableView(
                    "No Files",
                    systemImage: "doc",
                    description: Text("No files found in \(s3Service.currentBucket). Pull to refresh.")
                )
                .frame(maxWidth: .infinity, minHeight: 300)
            }
            .refreshable { await refreshFiles(force: true) }
        } else if !searchText.isEmpty && sortedItems.isEmpty {
            VStack {
                ContentUnavailableView.search(text: searchText)
                paginationControls
            }
        } else if viewStyle == .grid && !FileCardPresentation.prefersList(requestedGrid: true, isAccessibilitySize: dynamicTypeSize.isAccessibilitySize) {
            gridContent
        } else {
            listContent
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
                                    FileRow(object: object, s3Service: s3Service)
                                } else {
                                    CompactFileRow(object: object)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    } else {
                        NavigationLink(destination: FileDetailView(object: object, service: s3Service)) {
                            if viewStyle == .standard {
                                FileRow(object: object, s3Service: s3Service)
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
            paginationControls
        }
        .refreshable { await refreshFiles(force: true) }
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
                            }
                        } label: {
                            BrowserGridItem(item: .folder(folder), cardSize: gridCardSize, s3Service: s3Service)
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
                                    BrowserGridItem(item: .file(object), cardSize: gridCardSize, s3Service: s3Service)
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
                                BrowserGridItem(item: .file(object), cardSize: gridCardSize, s3Service: s3Service)
                            }
                            .contextMenu { fileContextMenuItems(for: object) }
                        }
                    }
                }
            }
            paginationControls
            .padding(10)
        }
        .refreshable { await refreshFiles(force: true) }
    }

    @ViewBuilder
    private var paginationControls: some View {
        if let notice = s3Service.session.browse.partialQueryNotice,
           s3Service.session.browse.query == s3Service.session.route {
            VStack(spacing: 8) {
                Text(notice).font(.caption).foregroundStyle(.secondary)
                if let error = s3Service.browsePaginationError { Text(error).font(.caption).foregroundStyle(.secondary) }
                Button("Load more") { Task { try? await s3Service.loadMoreObjects() } }
                    .disabled(s3Service.isLoading || s3Service.isLoadingMoreObjects)
                if s3Service.isLoadingMoreObjects { ProgressView() }
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
    }

    private var sortedItems: [S3Item] {
        let key = DerivedRowsKey(revision: s3Service.session.listings.revision(for: s3Service.session.route),
            fields: [s3Service.session.configuration.account, s3Service.currentBucket, s3Service.currentPrefix,
                searchText, String(fileTypeFilterRaw), sortOption])
        return rowProjection.value(for: key) { deriveSortedItems() }
    }

    private func deriveSortedItems() -> [S3Item] {
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

    private func initialLoad() async {
        guard isConfigured else { return }
        let route = s3Service.restoredBrowseLocation(legacyBucket: savedBucket, legacyPrefix: savedPrefix)
        await s3Service.session.restoreBrowse(bucket: route.bucket, prefix: route.prefix,
            listing: { await refreshFiles() },
            discovery: {
                do { try await s3Service.fetchAvailableBuckets() }
                catch is CancellationError {}
                catch { logger.error("Failed to fetch buckets: \(error.localizedDescription)") }
            })
    }

    private func refreshFiles(force: Bool = false) async {
        do {
            logger.debug("Listing objects for bucket: \(s3Service.currentBucket), prefix: \(s3Service.currentPrefix.isEmpty ? "(root)" : s3Service.currentPrefix)")
            try await s3Service.listObjects(force: force)
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

    private func performMoveCopy(object: S3Object, destPrefix: String) {
        let destination = destPrefix + S3TransferKeys.fileName(of: object.key)
        let bucket = object.bucket ?? s3Service.currentBucket
        let request = s3Service.makeObjectTransferRequest(kind: moveCopyMode == .move ? .move : .copy,
            key: object.key, to: destination, sourceBucket: bucket, destBucket: bucket)
        pendingMoveCopyRequest = request
    }

    @MainActor
    private func performPendingMoveCopy() {
        guard let request = pendingMoveCopyRequest else { return }
        pendingMoveCopyRequest = nil
        Task { await performTransfer(request) }
    }

    private func renameFile(_ file: S3Object, to newKey: String) async {
        renameTarget = nil
        let request = s3Service.makeObjectTransferRequest(kind: .rename,
            key: file.key, to: newKey, sourceBucket: file.bucket)
        await performTransfer(request)
    }

    @MainActor
    private func performTransfer(_ request: ObjectTransferRequest, approval: ObjectReplacementApproval? = nil,
                                 encryptionDecision: CopyEncryptionDecision = .automatic) async {
        do {
            try await s3Service.performObjectTransfer(request, approval: approval, encryptionDecision: encryptionDecision)
            await refreshFiles()
        } catch let requirement as CopyEncryptionRequirement {
            copyEncryptionPrompt = CopyEncryptionPrompt(requirement: requirement) { decision in
                Task { await performTransfer(request, approval: approval, encryptionDecision: decision) }
            }
        } catch ObjectTransferError.confirmationRequired(let conflict) {
            transferEncryptionDecision = encryptionDecision
            transferConflict = conflict
        } catch {
            logger.error("Object transfer failed: \(error.localizedDescription)")
            if request.kind == .rename {
                renameErrorMessage = error.localizedDescription
                showRenameError = true
            } else {
                moveCopyErrorMessage = error.localizedDescription
                showMoveCopyError = true
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
                if let image = await ImageCacheActor.shared.loadDisplayImage(for: object, using: s3Service) {
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
                if let url = s3Service.getPublicURL(for: object.key, bucket: object.bucket) {
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
    let s3Service: S3Service
    @State private var thumbnail: UIImage?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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

                if starStore.isStarred(s3Service.annotationIdentity(for: object)) {
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
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)

                (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 12))) {
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
        guard object.fileType == .image else { return }
        if let cached = await ImageCacheActor.shared.loadThumbnail(for: object, using: s3Service) {
            await MainActor.run {
                self.thumbnail = cached
            }
        }
    }
}

struct CompactFileRow: View {
    let object: S3Object

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))) {
            Image(systemName: object.fileType.icon)
                .font(.caption)
                .foregroundStyle(iconColor)
                .frame(width: 20)

            Text(object.fileName)
                .font(.subheadline)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .fixedSize(horizontal: false, vertical: true)

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
    let s3Service: S3Service
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

                if case .file(let obj) = item, starStore.isStarred(s3Service.annotationIdentity(for: obj)) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.yellow)
                        .padding(2)
                        .background(Color.black.opacity(0.35), in: Circle())
                        .padding(4)
                }
            }

            FileCardLabels(name: item.displayName, detail: {
                if case .file(let object) = item { object.formattedSize } else { nil }
            }())
        }
        .frame(maxWidth: .infinity)
        .task {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        guard case .file(let object) = item,
              object.fileType == .image || object.fileType == .video else { return }

        if let cached = await ImageCacheActor.shared.loadThumbnail(for: object, using: s3Service) {
            await MainActor.run { self.thumbnail = cached }
        }
    }
}

struct FolderRow: View {
    let folder: S3Folder

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 4) {
                Text(folder.folderName)
                    .font(.headline)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)

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

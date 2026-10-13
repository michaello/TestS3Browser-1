import SwiftUI
import AVKit
import WebKit
import AWSS3
import UniformTypeIdentifiers

struct FileDetailView: View {
    let object: S3Object
    let service: S3Service
    @Environment(\.dismiss) private var dismiss
    @State private var presentationAccount: String

    init(object: S3Object, service: S3Service) {
        self.object = object; self.service = service
        _presentationAccount = State(initialValue: service.session.configuration.account)
    }

    @State private var fileContent: FileContent?
    @State private var isLoading = false
    @State private var error: String?
    @State private var downloadedBytes: Int64 = 0
    @State private var showingDetails = false
    @State private var showingShareSheet = false
    @State private var metadataState = DetailMetadataLoadState<S3ObjectMetadata>()
    private var objectMetadata: S3ObjectMetadata? { metadataState.value }
    @State private var versionsExpanded = false
    @State private var tagsExpanded = false
    @State private var permissionsExpanded = false
    @State private var lifecycleExpanded = false
    @State private var exportURL: URL? = nil
    @State private var isExporting = false
    @State private var showExportError = false
    @State private var exportErrorMessage = ""
    @State private var isCopyingDataURL = false
    @State private var dataURLCopyDone = false
    @State private var isDownloadingToCache = false
    @State private var cachedFileURL: URL? = nil
    @State private var originalLease: OriginalFileLease?
    @State private var exportLease: ExportFileLease?
    @State private var openLease: ExportFileLease?
    @State private var fileLoadID = UUID()
    @State private var isChangingStorageClass = false
    @State private var storageClassError: String? = nil
    @State private var showStorageClassError = false
    @State private var copyEncryptionPrompt: CopyEncryptionPrompt?
    @State private var tagEditor = ObjectTagEditor()
    @State private var showTagsError = false
    @State private var objectACL: S3ObjectACL? = nil
    @State private var isLoadingACL = false
    @State private var aclError: String? = nil
    @State private var versions: [S3VersionEntry] = []
    @State private var isLoadingVersions = false
    @State private var versionsError: String? = nil
    @State private var versionRestore = VersionRestoreFlow()
    private var restoringVersionId: String? { versionRestore.activeVersion }
    @State private var showRestoreConfirm = false
    @State private var pendingRestoreVersionId: String? = nil
    @State private var lifecycleRules: [LifecycleRuleDisplay] = []
    @State private var lifecycleRequest = RequestOwnership()
    @State private var lifecycleError: String?
    private var isLoadingLifecycle: Bool { lifecycleRequest.isLoading }
    private var lifecyclePrediction: LifecyclePrediction {
        service.lifecyclePrediction(
            objectKey: object.key, objectCreated: object.lastModified, rules: lifecycleRules,
            objectSize: object.size,
            objectTags: tagEditor.loadState == .loaded ? tagEditor.tags : nil,
            currentStorageClass: objectMetadata.map { $0.storageClass ?? "STANDARD" },
            replicationStatus: objectMetadata?.replicationStatus
        )
    }

    private var nextTransition: LifecycleTransition? {
        if case .next(let transition) = lifecyclePrediction { return transition }
        return nil
    }

    enum FileContent {
        case text(String)
        case image(UIImage)
        case video(URL)
        case html(String)
    }

    private var isImageObject: Bool {
        let ext = (object.key as NSString).pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "gif", "webp"].contains(ext)
    }

    var body: some View {
        Group {
            if object.fileType == .html {
                htmlPrimaryView
            } else {
                standardDetailView
            }
        }
        .copyEncryptionConfirmation(prompt: Binding(
            get: { showingDetails ? nil : copyEncryptionPrompt },
            set: { copyEncryptionPrompt = $0 }
        ))
        .sheet(isPresented: $showingShareSheet) {
            SharePresignedURLSheet(object: object, s3Service: service)
        }
        .sheet(isPresented: Binding(get: { exportURL != nil }, set: { if !$0 { releaseExport() } })) {
            if let url = exportURL {
                ActivityView(url: url) {
                    releaseExport()
                }
            }
        }
        .sheet(isPresented: Binding(get: { cachedFileURL != nil }, set: { if !$0 { releaseOpenFile() } })) {
            if let url = cachedFileURL {
                ActivityView(url: url) {
                    releaseOpenFile()
                }
            }
        }
        .alert("Export Failed", isPresented: $showExportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportErrorMessage)
        }
        .alert("Storage Class Change Failed", isPresented: $showStorageClassError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(storageClassError ?? "Unknown error")
        }
        .alert("Tag Save Failed", isPresented: $showTagsError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(tagEditor.saveError ?? "Unknown error")
        }
        .alert("Restore Failed", isPresented: Binding(get: { versionRestore.errorMessage != nil }, set: { if !$0 { versionRestore.clearError() } })) {
            Button("OK", role: .cancel) { versionRestore.clearError() }
        } message: {
            Text(versionRestore.errorMessage ?? "Unknown error")
        }
        .onDisappear {
            fileLoadID = UUID()
            releaseExport(); releaseOpenFile()
            let original = originalLease
            originalLease = nil
            if let original { Task { await MediaOriginalStore.shared.release(original) } }
        }
        .onChange(of: service.session.configuration.account) { _, _ in
            fileLoadID = UUID(); fileContent = nil
            dismiss()
        }
    }

    /// For reports/.html the rendered page IS the screen - fill it edge to edge and
    /// put the metadata behind a "..." menu in the nav bar.
    private var htmlPrimaryView: some View {
        Group {
            if isLoading {
                downloadProgressView
            } else if let error {
                errorView(error)
            } else if case .html(let html) = fileContent {
                HTMLWebView(html: html, documentID: originalLease?.identity.digest ?? service.mediaIdentity(for: object).digest)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                downloadProgressView
            }
        }
        .navigationTitle(object.fileName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showingShareSheet = true
                    } label: {
                        Label("Share Link…", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        Task { await openFromCache() }
                    } label: {
                        Label("Open in…", systemImage: "arrow.down.circle")
                    }
                    .disabled(isDownloadingToCache)
                    Button {
                        Task { await prepareExport() }
                    } label: {
                        Label("Save to Files…", systemImage: "arrow.down.doc")
                    }
                    .disabled(isExporting)
                    storageClassMenu
                    Button {
                        showingDetails = true
                    } label: {
                        Label("File Details", systemImage: "info.circle")
                    }
                    if let url = service.getPublicURL(for: object.key) {
                        Link(destination: url) {
                            Label("Open in Browser", systemImage: "safari")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingDetails) {
            NavigationStack {
                ScrollView { metadataCard.padding() }
                    .task { await loadMetadata() }
                    .navigationTitle("File Details")
                    .copyEncryptionConfirmation(prompt: $copyEncryptionPrompt)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showingDetails = false }
                        }
                    }
            }
            .presentationDetents([.medium])
        }
        .task {
            await DetailLoadSchedule.initial(isHTML: true, content: { await loadFile() }, metadata: { await loadMetadata() })
        }
    }

    private var metadataCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("File Details")
                .font(.headline)

            MetadataRow(label: "Name", value: object.fileName)
            MetadataRow(label: "Size", value: object.formattedSize)
            MetadataRow(label: "Modified", value: object.lastModified.relativeFormatted())

            if let meta = objectMetadata {
                if let failure = metadataState.error {
                    Text(failure).font(.caption).foregroundStyle(.secondary)
                    Button("Retry Metadata") { Task { await loadMetadata(force: true) } }.font(.caption)
                }
                if let ct = meta.contentType {
                    MetadataRow(label: "Content-Type", value: ct)
                }
                if let sc = meta.storageClass {
                    MetadataRow(label: "Storage Class", value: sc)
                }
                if let enc = meta.contentEncoding {
                    MetadataRow(label: "Encoding", value: enc)
                }
                if let cc = meta.cacheControl {
                    MetadataRow(label: "Cache-Control", value: cc)
                }
                if let vid = meta.versionId {
                    MetadataRow(label: "Version ID", value: vid)
                }
                if let etag = meta.etag {
                    MetadataRow(label: "ETag", value: etag)
                }
                if let exp = meta.expirationDate {
                    MetadataRow(label: "Expires", value: exp)
                } else {
                    MetadataRow(label: "Expires", value: "No expiry")
                }
                if !meta.userMetadata.isEmpty {
                    Divider()
                    Text("Custom Metadata")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ForEach(meta.userMetadata.keys.sorted(), id: \.self) { key in
                        MetadataRow(label: key, value: meta.userMetadata[key] ?? "")
                    }
                }
            } else if let metadataError = metadataState.error {
                Text(metadataError).font(.caption).foregroundStyle(.secondary)
                Button("Retry Metadata") { Task { await loadMetadata(force: true) } }.font(.caption)
            } else if metadataState.isLoading {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Loading metadata…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(metadataState.phase == .empty ? "No additional metadata" : "Metadata not loaded")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let url = service.getPublicURL(for: object.key) {
                Link("Open in Browser", destination: url)
                    .font(.caption)
            }
        }
        .padding()
        .background(.gray.opacity(0.1))
        .cornerRadius(12)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    private var standardDetailView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                metadataCard

                // content display
                if isLoading {
                    downloadProgressView
                } else if let error = error {
                    errorView(error)
                } else if let content = fileContent {
                    switch content {
                    case .text(let text):
                        TextContentView(text: text)
                    case .image(let image):
                        ImageContentView(image: image)
                        if isImageObject {
                            copyAsDataURLButton(image: image)
                        }
                    case .video(let url):
                        VideoContentView(url: url, fileName: object.fileName, fileSize: object.formattedSize, originalIdentity: originalLease?.identity)
                    case .html(let html):
                        WebContentView(html: html, documentID: originalLease?.identity.digest ?? service.mediaIdentity(for: object).digest)
                    }
                }

                DisclosureGroup("Versions", isExpanded: $versionsExpanded) {
                    if versionsExpanded { versionsSection }
                }
                .task(id: versionsExpanded) { if versionsExpanded { await loadVersions() } }
                DisclosureGroup("S3 Tags", isExpanded: $tagsExpanded) {
                    if tagsExpanded { tagsSection }
                }
                .task(id: tagsExpanded) { if tagsExpanded { await loadTags() } }
                DisclosureGroup("Permissions", isExpanded: $permissionsExpanded) {
                    if permissionsExpanded { aclSection }
                }
                .task(id: permissionsExpanded) { if permissionsExpanded { await loadACL() } }
                DisclosureGroup("Lifecycle", isExpanded: $lifecycleExpanded) {
                    if lifecycleExpanded { lifecycleSection }
                }
                .task(id: lifecycleExpanded) { if lifecycleExpanded { await loadLifecycle() } }
            }
            .padding()
        }
        .navigationTitle(object.fileName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                storageClassMenu
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 16) {
                    if isDownloadingToCache {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Button {
                            Task { await openFromCache() }
                        } label: {
                            Image(systemName: "arrow.down.circle")
                        }
                    }

                    Button {
                        Task { await prepareExport() }
                    } label: {
                        Image(systemName: "arrow.down.doc")
                    }
                    .disabled(isExporting)

                    Button {
                        showingShareSheet = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .task {
            await DetailLoadSchedule.initial(isHTML: false, content: { await loadFile() }, metadata: { await loadMetadata() })
        }
        .confirmationDialog(
            "Restore this version?",
            isPresented: $showRestoreConfirm,
            titleVisibility: .visible
        ) {
            Button("Restore", role: .destructive) {
                if let vid = pendingRestoreVersionId {
                    Task { await restoreVersion(versionId: vid) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The selected version will be copied to the current key and become the latest version.")
        }
    }

    private var downloadProgressView: some View {
        VStack(spacing: 12) {
            ProgressView()

            if object.size > 0 {
                let progress = Double(downloadedBytes) / Double(object.size)
                ProgressView(value: min(progress, 1.0))
                    .progressViewStyle(.linear)
                    .frame(width: 200)

                Text("Downloading \(formatBytes(downloadedBytes)) / \(object.formattedSize)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Downloading...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(object.fileType.displayName)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1024.0
        if kb < 1024 {
            return String(format: "%.1f KB", kb)
        }
        let mb = kb / 1024.0
        return String(format: "%.1f MB", mb)
    }

    // The six tiers a user can move a general-purpose bucket object to.
    private let userFacingStorageClasses: [(label: String, value: S3ClientTypes.StorageClass)] = [
        ("Standard",               .standard),
        ("Intelligent-Tiering",    .intelligentTiering),
        ("Standard-IA",            .standardIa),
        ("One Zone-IA",            .onezoneIa),
        ("Glacier Instant",        .glacierIr),
        ("Glacier Flexible",       .glacier),
        ("Glacier Deep Archive",   .deepArchive),
    ]

    @ViewBuilder
    private var storageClassMenu: some View {
        let currentClass = objectMetadata?.storageClass
        Menu {
            ForEach(userFacingStorageClasses, id: \.label) { tier in
                Button {
                    Task { await applyStorageClass(tier.value) }
                } label: {
                    if currentClass == tier.value.rawValue {
                        Label(tier.label, systemImage: "checkmark")
                    } else {
                        Text(tier.label)
                    }
                }
                .disabled(isChangingStorageClass || currentClass == tier.value.rawValue)
            }
        } label: {
            if isChangingStorageClass {
                Label("Changing…", systemImage: "arrow.triangle.2.circlepath")
            } else {
                Label("Storage Class", systemImage: "archivebox")
            }
        }
        .disabled(isChangingStorageClass)
    }

    private func applyStorageClass(_ storageClass: S3ClientTypes.StorageClass,
                                   encryptionDecision: CopyEncryptionDecision = .automatic,
                                   expectedGeneration: UUID? = nil) async {
        let generation = expectedGeneration ?? service.session.generation
        guard service.session.isCurrent(generation) else { return }
        isChangingStorageClass = true
        defer { isChangingStorageClass = false }
        do {
            try await service.changeStorageClass(key: object.key, storageClass: storageClass, bucket: object.bucket,
                encryptionDecision: encryptionDecision, expectedGeneration: generation)
            await loadMetadata()
        } catch let requirement as CopyEncryptionRequirement {
            copyEncryptionPrompt = CopyEncryptionPrompt(requirement: requirement) { decision in
                Task { await applyStorageClass(storageClass, encryptionDecision: decision, expectedGeneration: generation) }
            }
        } catch {
            await MainActor.run {
                storageClassError = error.localizedDescription
                showStorageClassError = true
            }
        }
    }

    @ViewBuilder
    private func copyAsDataURLButton(image: UIImage) -> some View {
        HStack {
            if isCopyingDataURL {
                ProgressView()
                    .padding(.leading, 4)
                Text("Encoding…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if dataURLCopyDone {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Copied!")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    Task { await copyAsDataURL(image: image) }
                } label: {
                    Label("Copy as Data URL", systemImage: "doc.on.clipboard")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }
            Spacer()
        }
        .animation(.easeInOut(duration: 0.2), value: isCopyingDataURL)
        .animation(.easeInOut(duration: 0.2), value: dataURLCopyDone)
    }

    private func copyAsDataURL(image: UIImage) async {
        let generation = service.session.generation
        isCopyingDataURL = true
        defer { isCopyingDataURL = false }
        do {
            let lease = try await originalForExport()
            do {
                let mime = objectMetadata?.contentType ?? UTType(filenameExtension: lease.identity.fileExtension)?.preferredMIMEType ?? "application/octet-stream"
                let url = try await MediaFileIO.shared.dataURL(at: lease.url, mimeType: mime)
                await MediaOriginalStore.shared.release(lease)
                try Task.checkCancellation()
                guard service.session.isCurrent(generation) else { throw CancellationError() }
                UIPasteboard.general.string = url
                dataURLCopyDone = true
            } catch { await MediaOriginalStore.shared.release(lease); throw error }
        } catch {
            exportErrorMessage = error.localizedDescription; showExportError = true
        }
        try? await Task.sleep(for: .milliseconds(1_500))
        dataURLCopyDone = false
    }

    private func stageOriginal() async throws -> ExportFileLease {
        let generation = service.session.generation
        let original = try await originalForExport()
        do {
            try Task.checkCancellation()
            guard service.session.isCurrent(generation) else { throw CancellationError() }
            let staged = try await MediaExportStore.shared.stage(original)
            await MediaOriginalStore.shared.release(original)
            if Task.isCancelled || !service.session.isCurrent(generation) {
                await MediaExportStore.shared.release(staged)
                throw CancellationError()
            }
            return staged
        } catch { await MediaOriginalStore.shared.release(original); throw error }
    }

    private func originalForExport() async throws -> OriginalFileLease {
        guard presentationAccount == service.session.configuration.account else { throw CancellationError() }
        let current = service.mediaIdentity(for: object)
        if let originalLease, originalLease.identity.matches(account: current.account, bucket: current.bucket, key: current.key),
           let lease = try await MediaOriginalStore.shared.cachedFile(for: originalLease.identity) { return lease }
        // Streaming previews and restored navigation values may not carry the latest ETag.
        let requested = S3Object(key: object.key, size: -1, lastModified: object.lastModified, etag: nil, bucket: current.bucket)
        return try await service.downloadOriginalFile(for: requested)
    }

    private func prepareExport() async {
        isExporting = true
        defer { isExporting = false }
        do {
            let staged = try await stageOriginal()
            releaseExport()
            exportLease = staged; exportURL = staged.url
        } catch {
            exportErrorMessage = error.localizedDescription; showExportError = true
        }
    }

    private func releaseExport() {
        let lease = exportLease
        exportLease = nil; exportURL = nil
        if let lease { Task { await MediaExportStore.shared.release(lease) } }
    }

    private func releaseOpenFile() {
        let lease = openLease
        openLease = nil; cachedFileURL = nil
        if let lease { Task { await MediaExportStore.shared.release(lease) } }
    }

    @ViewBuilder
    private var versionsSection: some View {
        if isLoadingVersions {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.8)
                Text("Loading versions…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        } else if versions.count > 1 {
            VStack(alignment: .leading, spacing: 8) {
                Text("Versions (\(versions.count))")
                    .font(.headline)
                    .padding(.top, 8)

                ForEach(versions) { ver in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(ver.versionId.prefix(12) + "…")
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                                if ver.isLatest {
                                    Text("LATEST")
                                        .font(.caption2)
                                        .fontWeight(.semibold)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Color.blue.opacity(0.15))
                                        .foregroundStyle(.blue)
                                        .clipShape(Capsule())
                                }
                            }
                            Text("\(ver.lastModified.relativeFormatted()) · \(ver.formattedSize)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if !ver.isLatest {
                            if restoringVersionId == ver.versionId {
                                ProgressView().scaleEffect(0.7)
                            } else {
                                Button("Restore") {
                                    pendingRestoreVersionId = ver.versionId
                                    showRestoreConfirm = true
                                }
                                .font(.caption)
                                .buttonStyle(.bordered)
                                .disabled(restoringVersionId != nil)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }

    private func openFromCache() async {
        isDownloadingToCache = true
        defer { isDownloadingToCache = false }
        do {
            let staged = try await stageOriginal()
            releaseOpenFile()
            openLease = staged; cachedFileURL = staged.url
        } catch {
            exportErrorMessage = error.localizedDescription; showExportError = true
        }
    }

    private func loadTags(force: Bool = false) async {
        await tagEditor.load {
            if case .tags(let tags) = try await DetailMetadataCache.shared.load(.tags, object: object, service: service, force: force) {
                return tags
            }
            throw CancellationError()
        }
    }

    private func saveTags() async {
        let saved = await tagEditor.save { replacement in
            try await service.setObjectTags(
                key: object.key,
                tags: replacement.map { (key: $0.key, value: $0.value) },
                bucket: object.bucket
            )
        }
        if saved { DetailMetadataCache.shared.seed(.tags(tagEditor.tags), section: .tags, object: object, service: service) }
        if !saved && tagEditor.saveError != nil { showTagsError = true }
    }

    @ViewBuilder
    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("S3 Tags")
                    .font(.headline)
                Spacer()
                if tagEditor.loadState == .loading {
                    ProgressView().scaleEffect(0.7)
                } else if tagEditor.isEditing {
                    Button("Cancel") {
                        tagEditor.cancelEditing()
                    }
                    .font(.caption)
                    .disabled(tagEditor.isSaving)
                    Button {
                        Task { await saveTags() }
                    } label: {
                        if tagEditor.isSaving {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Text("Save")
                                .fontWeight(.semibold)
                        }
                    }
                    .font(.caption)
                    .disabled(!tagEditor.canSave)
                } else {
                    Button("Edit") {
                        tagEditor.beginEditing()
                    }
                    .font(.caption)
                    .disabled(!tagEditor.canEdit)
                }
            }
            .padding(.top, 8)

            if tagEditor.isEditing {
                ForEach(tagEditor.draft.indices, id: \.self) { i in
                    HStack(spacing: 8) {
                        TextField("Key", text: Binding(
                            get: { tagEditor.draft[i].key },
                            set: { tagEditor.draft[i].key = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .frame(maxWidth: .infinity)

                        Text("=")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextField("Value", text: Binding(
                            get: { tagEditor.draft[i].value },
                            set: { tagEditor.draft[i].value = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .frame(maxWidth: .infinity)

                        Button {
                            tagEditor.draft.remove(at: i)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                }
                .disabled(tagEditor.isSaving)

                Button {
                    tagEditor.draft.append(ObjectTag(key: "", value: ""))
                } label: {
                    Label("Add Tag", systemImage: "plus.circle")
                        .font(.caption)
                }
                .disabled(tagEditor.isSaving)
                Text("Saving replaces the object's complete tag set.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if case .failed(let message) = tagEditor.loadState {
                Text(message).font(.caption).foregroundStyle(.red)
                Button("Retry Loading Tags") { Task { await loadTags(force: true) } }
                    .font(.caption)
            } else if tagEditor.loadState == .idle {
                Button("Load Tags") { Task { await loadTags() } }.font(.caption)
            } else if tagEditor.loadState == .loading {
                Text("Loading tags…").font(.caption).foregroundStyle(.secondary)
            } else if tagEditor.tags.isEmpty {
                Text("No tags")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                ForEach(tagEditor.tags, id: \.key) { tag in
                    HStack {
                        Text(tag.key)
                            .font(.caption)
                            .fontWeight(.medium)
                        Text("=")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(tag.value)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding()
        .background(.gray.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - ACL

    private func loadACL() async {
        isLoadingACL = true
        defer { isLoadingACL = false }
        do {
            if case .permissions(let result) = try await DetailMetadataCache.shared.load(.permissions, object: object, service: service) {
                objectACL = result; aclError = nil
            }
        } catch {
            guard !(error is CancellationError) else { return }
            let msg = error.localizedDescription
            let display = msg.contains("AccessControlListNotSupported")
                ? "ACLs disabled on this bucket"
                : msg
            await MainActor.run { aclError = display }
        }
    }

    private func loadLifecycle(force: Bool = false) async {
        let requestID = lifecycleRequest.begin()
        let generation = service.session.generation
        defer { lifecycleRequest.finish(requestID) }
        do {
            guard case .lifecycle(let rules) = try await DetailMetadataCache.shared.load(.lifecycle, object: object, service: service, force: force),
                  service.session.isCurrent(generation), lifecycleRequest.owns(requestID) else { return }
            lifecycleRules = rules
            lifecycleError = nil
            if lifecycleRules.contains(where: {
                $0.isEnabled && !$0.filter.tags.isEmpty &&
                LifecyclePolicy.eligibility(filter: $0.filter, key: object.key, size: object.size, tags: nil) != .doesNotMatch
            }), tagEditor.loadState != .loaded { await loadTags() }
        } catch {
            guard !(error is CancellationError), service.session.isCurrent(generation), lifecycleRequest.owns(requestID) else { return }
            lifecycleError = error.localizedDescription
        }
    }

    private var aclSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Permissions")
                .font(.headline)

            if isLoadingACL {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text("Loading permissions…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let err = aclError {
                MetadataRow(label: "ACL", value: err)
            } else if let acl = objectACL {
                MetadataRow(label: "Access", value: acl.summary)
                if !acl.grants.isEmpty {
                    DisclosureGroup("Show grants (\(acl.grants.count))") {
                        ForEach(acl.grants) { grant in
                            HStack {
                                Text(grant.grantee)
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text(grant.permission)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .font(.caption)
                }
            }
        }
        .padding()
        .background(.gray.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var lifecycleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Lifecycle")
                    .font(.headline)
                Spacer()
                if isLoadingLifecycle {
                    ProgressView().scaleEffect(0.7)
                } else {
                    Button("Refresh") {
                        Task { await loadLifecycle(force: true) }
                    }
                    .font(.caption)
                }
            }
            .padding(.top, 8)

            if isLoadingLifecycle {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text("Loading lifecycle rules…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let lifecycleError {
                Text("Unable to load lifecycle rules: \(lifecycleError)")
                    .font(.caption).foregroundStyle(.red)
            } else if lifecycleRules.isEmpty {
                Text("No lifecycle rules configured")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else if let transition = nextTransition {
                VStack(alignment: .leading, spacing: 8) {
                    MetadataRow(label: "Estimated Eligibility", value: transition.transitionDate.relativeFormatted())
                    MetadataRow(label: "Target Storage Class", value: transition.targetStorageClass)
                    Text("S3 processes eligible objects asynchronously.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if lifecyclePrediction == .unknown {
                Text("Transition eligibility is unknown until the applicable rules and object metadata are available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No upcoming transitions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
        }
        .padding()
        .background(.gray.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func loadVersions() async {
        isLoadingVersions = true
        defer { isLoadingVersions = false }
        do {
            if case .versions(let result) = try await DetailMetadataCache.shared.load(.versions, object: object, service: service) {
                versions = result; versionsError = nil
            }
        } catch {
            guard !(error is CancellationError) else { return }
            await MainActor.run { versionsError = error.localizedDescription }
        }
    }

    private func restoreVersion(versionId: String, encryptionDecision: CopyEncryptionDecision = .automatic,
                                expectedGeneration: UUID? = nil) async {
        let generation = expectedGeneration ?? service.session.generation
        await versionRestore.restore(versionId, isCurrent: {
            presentationAccount == service.session.configuration.account && service.session.isCurrent(generation)
        }, write: {
            do {
                try await service.restoreVersion(key: object.key, versionId: versionId, bucket: object.bucket,
                    encryptionDecision: encryptionDecision, expectedGeneration: generation)
            } catch let requirement as CopyEncryptionRequirement {
                copyEncryptionPrompt = CopyEncryptionPrompt(requirement: requirement) { decision in
                    Task { await restoreVersion(versionId: versionId, encryptionDecision: decision, expectedGeneration: generation) }
                }
                throw CancellationError()
            }
        }, invalidate: {}, content: {
            await loadFile(forceRevisionRefresh: true)
            if let error { throw PreviewRefreshError(message: error) }
        }, metadata: {
            let metadata = try await service.headObject(key: object.key, bucket: object.bucket)
            guard service.session.isCurrent(generation) else { throw CancellationError() }
            metadataState.receive(metadata)
            DetailMetadataCache.shared.seed(.metadata(metadata), section: .metadata, object: object, service: service)
        }, versions: {
            let result = try await service.listObjectVersions(key: object.key, bucket: object.bucket)
            guard service.session.isCurrent(generation) else { throw CancellationError() }
            versions = result; versionsError = nil
            DetailMetadataCache.shared.seed(.versions(result), section: .versions, object: object, service: service)
        })
    }

    private func loadMetadata(force: Bool = false) async {
        await metadataState.load {
            if case .metadata(let meta) = try await DetailMetadataCache.shared.load(.metadata, object: object, service: service, force: force) {
                return meta
            }
            return nil
        }
    }

    private func loadFile(forceRevisionRefresh: Bool = false) async {
        let request = UUID(), generation = service.session.generation
        fileLoadID = request
        isLoading = true; error = nil; downloadedBytes = 0
        defer { if fileLoadID == request { isLoading = false } }
        do {
            guard presentationAccount == service.session.configuration.account else { throw CancellationError() }
            let requestedObject = forceRevisionRefresh
                ? S3Object(key: object.key, size: -1, lastModified: object.lastModified, etag: nil, bucket: object.bucket)
                : object
            if object.fileType == .video {
                let identity = service.mediaIdentity(for: requestedObject)
                if let cached = try await MediaOriginalStore.shared.cachedFile(for: identity) {
                    guard fileLoadID == request, service.session.isCurrent(generation), !Task.isCancelled else {
                        await MediaOriginalStore.shared.release(cached); throw CancellationError()
                    }
                    if let old = originalLease { await MediaOriginalStore.shared.release(old) }
                    originalLease = cached; fileContent = .video(cached.url)
                    return
                }
                if let url = service.generatePresignedURL(for: object.key, bucket: identity.bucket).flatMap(URL.init(string:)) {
                    guard fileLoadID == request, service.session.isCurrent(generation), !Task.isCancelled else { throw CancellationError() }
                    fileContent = .video(url)
                    return
                }
            }
            let lease = try await service.downloadOriginalFile(for: requestedObject) { value in
                Task { @MainActor in
                    if fileLoadID == request, service.session.isCurrent(generation) { downloadedBytes = value }
                }
            }
            guard fileLoadID == request, service.session.isCurrent(generation), !Task.isCancelled else {
                await MediaOriginalStore.shared.release(lease); throw CancellationError()
            }
            if let old = originalLease { await MediaOriginalStore.shared.release(old) }
            originalLease = lease
            switch object.fileType {
            case .image:
                let resolved = S3Object(key: object.key, size: lease.bytes, lastModified: object.lastModified,
                                        etag: lease.identity.etag, bucket: lease.identity.bucket)
                guard let image = await ImageCacheActor.shared.loadDisplayImage(for: resolved, using: service) else { throw MediaTransferError.missingBody }
                guard fileLoadID == request, service.session.isCurrent(generation) else { throw CancellationError() }
                fileContent = .image(image)
            case .video:
                fileContent = .video(lease.url)
            case .log, .text, .unknown, .html:
                let data = try await MediaFileIO.shared.data(at: lease.url)
                guard let text = String(data: data, encoding: .utf8) else { throw MediaTransferError.invalidResponse }
                guard fileLoadID == request, service.session.isCurrent(generation) else { throw CancellationError() }
                if object.fileType == .html { fileContent = .html(text) }
                else { fileContent = .text(text) }
            }
        } catch {
            if fileLoadID == request, !(error is CancellationError) { self.error = error.localizedDescription }
        }
    }
}

struct TextContentView: View {
    let text: String
    @State private var showLineNumbers = true
    @State private var preview = NumberedTextPreview()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Content")
                    .font(.headline)

                Spacer()

                Toggle("Line #", isOn: $showLineNumbers)
                    .labelsHidden()
            }

            if showLineNumbers {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(preview.lines) { line in
                            HStack(alignment: .top, spacing: 12) {
                                Text("\(line.number)")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 40, alignment: .trailing)

                                Text(String(line.text))
                                    .font(.system(.caption, design: .monospaced))
                            }
                        }
                    }
                    .padding(12)
                }
                .background(.black.opacity(0.05))
                .cornerRadius(8)
            } else {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.05))
                    .cornerRadius(8)
            }
        }
        .onChange(of: PreviewTextInput(text: text), initial: true) { _, input in
            preview.update(input)
        }
    }
}

struct WebContentView: View {
    let html: String
    var documentID = "inline"
    @State private var isFullScreen = false

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Report")
                    .font(.headline)

                Spacer()

                Button {
                    isFullScreen = true
                } label: {
                    Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }

            HTMLWebView(html: html, documentID: documentID)
                .frame(maxWidth: .infinity)
                .frame(height: 500)
                .cornerRadius(8)
        }
        .fullScreenCover(isPresented: $isFullScreen) {
            FullScreenWebView(html: html, documentID: documentID, isPresented: $isFullScreen)
        }
    }
}

struct FullScreenWebView: View {
    let html: String
    var documentID = "inline"
    @Binding var isPresented: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HTMLWebView(html: html, documentID: documentID)
                .ignoresSafeArea()

            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.white)
                    .shadow(radius: 10)
            }
            .padding()
        }
    }
}

/// WKWebView wrapper that loads a self-contained HTML string. Phone-mode reports
/// inline their images as base64 data URIs, so nothing is fetched from the network.
struct HTMLWebView: UIViewRepresentable {
    let html: String
    var documentID = "inline"

    @MainActor
    final class Coordinator {
        var loadGate = HTMLDocumentLoadGate()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        context.coordinator.loadGate.load(documentID: documentID, html: html) {
            webView.loadHTMLString($0, baseURL: nil)
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.loadGate.load(documentID: documentID, html: html) {
            webView.loadHTMLString($0, baseURL: nil)
        }
    }
}

struct ImageContentView: View {
    let image: UIImage
    @State private var zoom = MediaZoomState()
    @State private var isFullScreen = false

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Image")
                    .font(.headline)

                Spacer()

                Button {
                    isFullScreen = true
                } label: {
                    Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }

            ZoomableMediaImage(image: image, zoom: $zoom)
            .frame(maxWidth: .infinity)
            .frame(height: 300)
            .background(.gray.opacity(0.1))
            .cornerRadius(8)

            HStack {
                if zoom.scale > 1.0 {
                    Button("Reset") {
                        withAnimation { zoom.reset() }
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                Text("Pinch to zoom • Double tap to zoom • Drag to pan")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Dimensions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(Int(image.size.width)) × \(Int(image.size.height))")
                        .font(.caption)
                        .fontWeight(.medium)
                }

                Divider()
                    .frame(height: 30)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Scale")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.0f%%", image.scale * 100))
                        .font(.caption)
                        .fontWeight(.medium)
                }

                Spacer()
            }
            .padding(.top, 8)
        }
        .fullScreenCover(isPresented: $isFullScreen) {
            FullScreenImageView(image: image, isPresented: $isFullScreen)
        }
    }
}

struct FullScreenImageView: View {
    let image: UIImage
    @Binding var isPresented: Bool
    @State private var zoom = MediaZoomState()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ZoomableMediaImage(image: image, zoom: $zoom)

            VStack {
                HStack {
                    Spacer()
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.white)
                            .shadow(radius: 10)
                    }
                    .padding()
                }
                Spacer()
            }
        }
    }
}

struct VideoContentView: View {
    let url: URL
    var fileName: String = ""
    var fileSize: String = ""
    var originalIdentity: MediaObjectIdentity?
    @State private var playbackResources = MediaPlaybackResources()
    @State private var metadataTask: Task<Void, Never>?
    @State private var playbackToken: UUID?
    @State private var playerURL: URL?
    @State private var player: AVPlayer?
    @State private var isFullScreen = false
    @State private var duration: String?
    @State private var videoResolution: String?

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Video")
                    .font(.headline)

                Spacer()

                Button {
                    isFullScreen = true
                } label: {
                    Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }

            if let player {
                VideoPlayer(player: player)
                    .frame(maxWidth: .infinity)
                    .frame(height: 400)
                    .cornerRadius(8)
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Preparing video...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 400)
                .background(.black.opacity(0.05))
                .cornerRadius(8)
            }

            // Video metadata
            HStack(spacing: 16) {
                if let duration {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Duration")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(duration)
                            .font(.caption)
                            .fontWeight(.medium)
                    }

                    Divider()
                        .frame(height: 30)
                }

                if let videoResolution {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Resolution")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(videoResolution)
                            .font(.caption)
                            .fontWeight(.medium)
                    }

                    Divider()
                        .frame(height: 30)
                }

                if !fileSize.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Size")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(fileSize)
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                }

                Spacer()
            }
            .padding(.top, 8)
        }
        .task(id: url) {
            if playerURL != url {
                await playbackResources.release(ifGeneration: playbackToken)
                metadataTask?.cancel(); player?.pause(); player = nil
                duration = nil; videoResolution = nil
            }
            let token = UUID()
            playbackToken = token
            do {
                try await playbackResources.acquire(url: url, identity: originalIdentity, requestID: token)
                try Task.checkCancellation()
                if player == nil { playerURL = url; setupPlayer() }
            } catch { await playbackResources.release(ifGeneration: token) }
        }
        .onDisappear {
            if !isFullScreen {
                metadataTask?.cancel(); metadataTask = nil
                player?.pause(); player = nil
                let token = playbackToken
                Task { await playbackResources.release(ifGeneration: token) }
            }
        }
        .fullScreenCover(isPresented: $isFullScreen) {
            if let player { FullScreenVideoView(player: player, resources: playbackResources, isPresented: $isFullScreen) }
        }
    }

    private func setupPlayer() {
        let avPlayer = AVPlayer(url: url)
        player = avPlayer
        avPlayer.play()

        // Extract video metadata
        metadataTask?.cancel()
        metadataTask = Task {
            let asset = AVURLAsset(url: url)
            do {
                let cmDuration = try await asset.load(.duration)
                try Task.checkCancellation()
                let seconds = CMTimeGetSeconds(cmDuration)
                if seconds.isFinite && seconds > 0 {
                    let formatted = formatDuration(seconds)
                    await MainActor.run { duration = formatted }
                }

                // Get video resolution from first video track
                let tracks = try await asset.loadTracks(withMediaType: .video)
                if let track = tracks.first {
                    let size = try await track.load(.naturalSize)
                    let transform = try await track.load(.preferredTransform)
                    try Task.checkCancellation()
                    let correctedSize = size.applying(transform)
                    let width = abs(Int(correctedSize.width))
                    let height = abs(Int(correctedSize.height))
                    await MainActor.run { videoResolution = "\(width) x \(height)" }
                }
            } catch {
                print("[VideoContentView] Failed to load video metadata: \(error.localizedDescription)")
            }
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

struct FullScreenVideoView: View {
    let player: AVPlayer
    let resources: MediaPlaybackResources
    @Binding var isPresented: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VideoPlayer(player: player)
                .ignoresSafeArea()

            VStack {
                HStack {
                    Spacer()
                    Button {
                        player.pause()
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.white)
                            .shadow(radius: 10)
                    }
                    .padding()
                }
                Spacer()
            }
        }
        .onAppear {
            player.play()
        }
        .onDisappear {
            player.pause()
        }
    }
}

struct MetadataRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            Text(value)
                .font(.subheadline)
                .lineLimit(2)
        }
    }
}

/// Wraps UIActivityViewController so the user can save a file to Files, AirDrop it, etc.
struct ActivityView: UIViewControllerRepresentable {
    let url: URL
    var onDismiss: (() -> Void)? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        vc.completionWithItemsHandler = { _, _, _, _ in
            onDismiss?()
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// Wraps UIActivityViewController for sharing multiple files at once.
struct MultiFileActivityView: UIViewControllerRepresentable {
    let urls: [URL]
    var onDismiss: (() -> Void)? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        vc.completionWithItemsHandler = { _, _, _, _ in
            onDismiss?()
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

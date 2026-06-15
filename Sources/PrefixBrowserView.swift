import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import os.log

/// Self-contained folder/prefix drill-down view used from RecentFilesView.
/// Each navigation push instantiates a new PrefixBrowserView at the child prefix;
/// state (items, loading, error) is owned locally so this doesn't interfere with
/// BucketBrowserView's shared s3Service.currentPrefix / s3Service.items.
struct PrefixBrowserView: View {
    let s3Service: S3Service
    let prefix: String
    let bucket: String
    let title: String

    private let logger = Logger(subsystem: "com.s3browser", category: "PrefixBrowserView")

    @State private var items: [S3Item] = []
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var nextToken: String? = nil
    @State private var errorMessage: String? = nil

    // Upload state
    @State private var showUploadMenu = false
    @State private var showFilePicker = false
    @State private var showPhotoPicker = false
    @State private var selectedPhoto: PhotosPickerItem? = nil
    @State private var isUploading = false
    @State private var uploadProgress: Double = 0
    @State private var uploadResult: UploadResult? = nil

    enum UploadResult {
        case success(String)
        case failure(String)
    }

    var body: some View {
        Group {
            if isLoading && items.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let msg = errorMessage {
                ContentUnavailableView(
                    "Failed to Load",
                    systemImage: "exclamationmark.triangle",
                    description: Text(msg)
                )
            } else if items.isEmpty {
                ContentUnavailableView(
                    "Empty Folder",
                    systemImage: "folder",
                    description: Text("No files or folders here")
                )
            } else {
                List {
                    ForEach(items) { item in
                        switch item {
                        case .folder(let folder):
                            NavigationLink {
                                PrefixBrowserView(
                                    s3Service: s3Service,
                                    prefix: folder.prefix,
                                    bucket: bucket,
                                    title: folder.folderName
                                )
                            } label: {
                                FolderRow(folder: folder)
                            }
                        case .file(let object):
                            NavigationLink {
                                FileDetailView(object: object, service: s3Service)
                            } label: {
                                FileRow(object: object)
                            }
                        }
                    }

                    if let _ = nextToken {
                        HStack {
                            Spacer()
                            if isLoadingMore {
                                ProgressView()
                            } else {
                                Button("Load more") {
                                    Task { await loadMore() }
                                }
                                .buttonStyle(.bordered)
                            }
                            Spacer()
                        }
                        .listRowSeparator(.hidden)
                        .padding(.vertical, 8)
                    }
                }
                .refreshable { await load() }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                uploadButton
            }
        }
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
        .task { await load() }
    }

    // MARK: - Upload entry point

    private var uploadButton: some View {
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
        } label: {
            Image(systemName: "plus")
        }
        .disabled(isUploading)
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
                        Button {
                            uploadResult = nil
                        } label: {
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

    // MARK: - Handlers

    private func handlePhotoPickerItem(_ item: PhotosPickerItem) async {
        defer { Task { @MainActor in selectedPhoto = nil } }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            // Infer a filename from the item identifier; fall back to a timestamp.
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
                // Security-scoped access is required for URLs returned by UIDocumentPickerViewController.
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

    private func upload(data: Data, filename: String, contentType: String) async {
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
            logger.info("Uploaded \(key) to \(bucket)")
            await MainActor.run {
                isUploading = false
                uploadResult = .success(key)
            }
            await load()
        } catch {
            logger.error("Upload failed for \(key): \(error.localizedDescription)")
            await MainActor.run {
                isUploading = false
                uploadResult = .failure(error.localizedDescription)
            }
        }
    }

    // MARK: - Listing

    private func load() async {
        isLoading = true
        errorMessage = nil
        nextToken = nil
        do {
            let page = try await s3Service.listPrefix(prefix, bucket: bucket, continuationToken: nil)
            items = page.items
            nextToken = page.nextToken
        } catch {
            logger.error("listPrefix(\(prefix)) failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func loadMore() async {
        guard let token = nextToken, !isLoadingMore else { return }
        isLoadingMore = true
        do {
            let page = try await s3Service.listPrefix(prefix, bucket: bucket, continuationToken: token)
            items.append(contentsOf: page.items)
            nextToken = page.nextToken
        } catch {
            logger.error("listPrefix(\(prefix)) page failed: \(error.localizedDescription)")
        }
        isLoadingMore = false
    }
}

#Preview {
    NavigationStack {
        PrefixBrowserView(
            s3Service: S3Service(config: S3Config.default),
            prefix: "",
            bucket: "hairforceone-pro",
            title: "hairforceone-pro"
        )
    }
}

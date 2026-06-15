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
    @State private var searchText = ""
    @State private var sortOption: PrefixSortOption = .nameAZ
    @AppStorage("prefixBrowserViewStyle") private var viewStyleRaw: String = "standard"
    @AppStorage("prefixBrowserGridCardSize") private var cardSize: Double = 120

    private var viewStyle: ViewStyle {
        viewStyleRaw == "grid" ? .grid : .standard
    }

    // Delete state
    @State private var showDeleteError = false
    @State private var deleteErrorMessage = ""

    // Move/copy state
    @State private var moveCopyTarget: S3Object? = nil
    @State private var moveCopyMode: PrefixPickerSheet.Mode = .copy
    @State private var showMoveCopyError = false
    @State private var moveCopyErrorMessage = ""

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

    private var displayedItems: [S3Item] {
        let filtered: [S3Item] = searchText.isEmpty ? items : items.filter { item in
            item.displayName.localizedCaseInsensitiveContains(searchText)
        }
        return filtered.sorted { a, b in
            // Folders always sort before files.
            if a.isFolder != b.isFolder { return a.isFolder }
            switch sortOption {
            case .nameAZ:    return a.displayName.localizedCompare(b.displayName) == .orderedAscending
            case .nameZA:    return a.displayName.localizedCompare(b.displayName) == .orderedDescending
            case .dateNewest: return a.sortDate > b.sortDate
            case .dateOldest: return a.sortDate < b.sortDate
            }
        }
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
            } else if !searchText.isEmpty && displayedItems.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else if items.isEmpty {
                ContentUnavailableView(
                    "Empty Folder",
                    systemImage: "folder",
                    description: Text("No files or folders here")
                )
            } else if viewStyle == .grid {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: cardSize), spacing: 10)], spacing: 10) {
                        ForEach(displayedItems) { item in
                            gridCell(for: item)
                        }
                    }
                    .padding(.horizontal, 12)

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
                        .padding(.vertical, 8)
                    }
                }
                .refreshable { await load() }
            } else {
                List {
                    ForEach(displayedItems) { item in
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
                            .contextMenu {
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
                                Divider()
                                Button(role: .destructive) {
                                    Task { await deleteItem(.file(object)) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    Task { await deleteItem(.file(object)) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
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
        .searchable(text: $searchText, prompt: "Search in \(title)")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 4) {
                    if viewStyle == .grid {
                        Slider(value: $cardSize, in: 80...200)
                            .frame(width: 80)
                    }
                    viewStyleToggle
                    sortMenuButton
                    uploadButton
                }
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
        .alert("Delete Failed", isPresented: $showDeleteError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteErrorMessage)
        }
        .sheet(item: $moveCopyTarget) { object in
            PrefixPickerSheet(
                s3Service: s3Service,
                sourceBucket: bucket,
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
        .task { await load() }
    }

    // MARK: - Grid cell

    @ViewBuilder
    private func gridCell(for item: S3Item) -> some View {
        if case .file(let object) = item {
            NavigationLink(destination: FileDetailView(object: object, service: s3Service)) {
                PrefixGridItem(item: item, cardSize: cardSize)
            }
            .buttonStyle(.plain)
            .contextMenu {
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
                Divider()
                Button(role: .destructive) {
                    Task { await deleteItem(item) }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        } else if case .folder(let folder) = item {
            NavigationLink(destination: PrefixBrowserView(
                s3Service: s3Service,
                prefix: folder.prefix,
                bucket: bucket,
                title: folder.folderName
            )) {
                PrefixGridItem(item: item, cardSize: cardSize)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Delete

    private func deleteItem(_ item: S3Item) async {
        guard case .file(let object) = item else { return }
        do {
            try await s3Service.deleteObject(key: object.key, bucket: bucket)
            items.removeAll { $0.id == item.id }
        } catch {
            logger.error("Delete failed for \(object.key): \(error.localizedDescription)")
            await MainActor.run {
                deleteErrorMessage = "Could not delete \(object.fileName): \(error.localizedDescription)"
                showDeleteError = true
            }
        }
    }

    // MARK: - Move / Copy

    private func performMoveCopy(object: S3Object, destPrefix: String) async {
        let filename = object.fileName
        let destKey = destPrefix.isEmpty ? filename : "\(destPrefix)\(filename)"
        do {
            try await s3Service.copyObject(
                key: object.key,
                to: destKey,
                sourceBucket: bucket,
                destBucket: bucket
            )
            if moveCopyMode == .move {
                try await s3Service.deleteObject(key: object.key, bucket: bucket)
                items.removeAll { $0.id == S3Item.file(object).id }
            }
            logger.info("\(moveCopyMode == .move ? "Moved" : "Copied") \(object.key) -> \(destKey)")
            if moveCopyMode == .copy { await load() }
        } catch {
            logger.error("Move/copy failed for \(object.key): \(error.localizedDescription)")
            await MainActor.run {
                moveCopyErrorMessage = error.localizedDescription
                showMoveCopyError = true
            }
        }
    }

    // MARK: - View style toggle

    private var viewStyleToggle: some View {
        Button {
            viewStyleRaw = (viewStyle != .grid) ? "grid" : "standard"
        } label: {
            Image(systemName: viewStyle != .grid ? "square.grid.2x2" : "list.bullet")
        }
    }

    // MARK: - Sort menu

    private var sortMenuButton: some View {
        Menu {
            ForEach(PrefixSortOption.allCases, id: \.self) { option in
                Button {
                    sortOption = option
                } label: {
                    if sortOption == option {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
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

// MARK: - Supporting types

enum PrefixSortOption: CaseIterable {
    case nameAZ, nameZA, dateNewest, dateOldest

    var label: String {
        switch self {
        case .nameAZ:     return "Name (A - Z)"
        case .nameZA:     return "Name (Z - A)"
        case .dateNewest: return "Date (Newest)"
        case .dateOldest: return "Date (Oldest)"
        }
    }
}

// MARK: - PrefixGridItem

private let prefixStarStore = StarStore.shared

struct PrefixGridItem: View {
    let item: S3Item
    let cardSize: Double
    @State private var thumbnail: UIImage?

    private var iconColor: Color {
        guard case .file(let obj) = item else { return .blue }
        switch obj.fileType {
        case .log:     return .blue
        case .image:   return .purple
        case .video:   return .orange
        case .text:    return .green
        case .html:    return .teal
        case .unknown: return .gray
        }
    }

    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                ZStack {
                    switch item {
                    case .folder:
                        Image(systemName: "folder.fill")
                            .font(.system(size: cardSize > 100 ? 32 : 22))
                            .foregroundStyle(.blue)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .file(let object):
                        if let thumbnail {
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
                        if object.fileType == .video {
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

                if case .file(let obj) = item, prefixStarStore.isStarred(obj.key) {
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
        .task { await loadThumbnail() }
    }

    private func loadThumbnail() async {
        guard case .file(let object) = item,
              object.fileType == .image || object.fileType == .video else { return }
        if let cached = await ImageCacheActor.shared.getThumbnail(for: object.key) {
            await MainActor.run { self.thumbnail = cached }
        }
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

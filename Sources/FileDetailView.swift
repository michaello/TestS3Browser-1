import SwiftUI
import AVKit
import WebKit
import AWSS3

struct FileDetailView: View {
    let object: S3Object
    let service: S3Service

    @State private var fileContent: FileContent?
    @State private var isLoading = false
    @State private var error: String?
    @State private var downloadedBytes: Int64 = 0
    @State private var showingDetails = false
    @State private var showingShareSheet = false
    @State private var objectMetadata: S3ObjectMetadata? = nil
    @State private var exportURL: URL? = nil
    @State private var isExporting = false
    @State private var showExportError = false
    @State private var exportErrorMessage = ""
    @State private var isCopyingDataURL = false
    @State private var dataURLCopyDone = false
    @State private var isDownloadingToCache = false
    @State private var cachedFileURL: URL? = nil
    @State private var isChangingStorageClass = false
    @State private var storageClassError: String? = nil
    @State private var showStorageClassError = false
    @State private var versions: [S3VersionEntry] = []
    @State private var isLoadingVersions = false
    @State private var versionsError: String? = nil
    @State private var restoringVersionId: String? = nil
    @State private var showRestoreConfirm = false
    @State private var pendingRestoreVersionId: String? = nil

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
        .sheet(isPresented: $showingShareSheet) {
            SharePresignedURLSheet(object: object, s3Service: service)
        }
        .sheet(isPresented: Binding(get: { exportURL != nil }, set: { if !$0 { exportURL = nil } })) {
            if let url = exportURL {
                ActivityView(url: url) {
                    exportURL = nil
                }
            }
        }
        .sheet(isPresented: Binding(get: { cachedFileURL != nil }, set: { if !$0 { cachedFileURL = nil } })) {
            if let url = cachedFileURL {
                ActivityView(url: url) {
                    cachedFileURL = nil
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
                HTMLWebView(html: html)
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
                    .navigationTitle("File Details")
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
            async let fileLoad: Void = loadFile()
            async let metaLoad: Void = loadMetadata()
            async let versLoad: Void = loadVersions()
            _ = await (fileLoad, metaLoad, versLoad)
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
            } else {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Loading metadata…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                        VideoContentView(url: url, fileName: object.fileName, fileSize: object.formattedSize)
                    case .html(let html):
                        WebContentView(html: html)
                    }
                }

                versionsSection
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
            async let fileLoad: Void = loadFile()
            async let metaLoad: Void = loadMetadata()
            async let versLoad: Void = loadVersions()
            _ = await (fileLoad, metaLoad, versLoad)
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

    private func applyStorageClass(_ storageClass: S3ClientTypes.StorageClass) async {
        isChangingStorageClass = true
        defer { isChangingStorageClass = false }
        do {
            try await service.changeStorageClass(key: object.key, storageClass: storageClass, bucket: object.bucket)
            await loadMetadata()
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
        isCopyingDataURL = true
        defer { isCopyingDataURL = false }

        let ext = (object.key as NSString).pathExtension.lowercased()
        let mimeType: String
        switch ext {
        case "jpg", "jpeg": mimeType = "image/jpeg"
        case "png":         mimeType = "image/png"
        case "gif":         mimeType = "image/gif"
        case "webp":        mimeType = "image/webp"
        default:            mimeType = "image/png"
        }

        let data: Data
        if ext == "png" {
            data = image.pngData() ?? Data()
        } else {
            data = image.jpegData(compressionQuality: 1.0) ?? Data()
        }

        let b64 = data.base64EncodedString()
        let dataURL = "data:\(mimeType);base64,\(b64)"
        await MainActor.run {
            UIPasteboard.general.string = dataURL
            dataURLCopyDone = true
        }

        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await MainActor.run { dataURLCopyDone = false }
    }

    private func prepareExport() async {
        isExporting = true
        defer { isExporting = false }

        do {
            let data: Data
            switch fileContent {
            case .text(let text):
                data = Data(text.utf8)
            case .image(let image):
                data = image.pngData() ?? Data()
            case .video(let url):
                data = try Data(contentsOf: url)
            case .html(let html):
                data = Data(html.utf8)
            case nil:
                data = try await service.downloadObject(key: object.key, bucket: object.bucket)
            }

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathComponent(object.fileName)
            try FileManager.default.createDirectory(
                at: tempURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: tempURL)
            await MainActor.run { exportURL = tempURL }
        } catch {
            await MainActor.run {
                exportErrorMessage = error.localizedDescription
                showExportError = true
            }
        }
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

    private var cacheFileURL: URL {
        let sanitized = object.key.replacingOccurrences(of: "/", with: "_")
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("s3cache")
            .appendingPathComponent(sanitized)
    }

    private func openFromCache() async {
        isDownloadingToCache = true
        defer { isDownloadingToCache = false }

        let dest = cacheFileURL
        if !FileManager.default.fileExists(atPath: dest.path) {
            do {
                try FileManager.default.createDirectory(
                    at: dest.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let data = try await service.downloadObject(key: object.key, bucket: object.bucket)
                try data.write(to: dest)
            } catch {
                return
            }
        }
        await MainActor.run { cachedFileURL = dest }
    }

    private func loadVersions() async {
        isLoadingVersions = true
        defer { isLoadingVersions = false }
        do {
            let result = try await service.listObjectVersions(key: object.key, bucket: object.bucket)
            await MainActor.run { versions = result }
        } catch {
            await MainActor.run { versionsError = error.localizedDescription }
        }
    }

    private func restoreVersion(versionId: String) async {
        restoringVersionId = versionId
        defer { restoringVersionId = nil }
        do {
            try await service.restoreVersion(key: object.key, versionId: versionId, bucket: object.bucket)
            await loadVersions()
        } catch {
            // Restore failure is silently swallowed; the list refresh will show the real state.
        }
    }

    private func loadMetadata() async {
        do {
            let meta = try await service.headObject(key: object.key, bucket: object.bucket)
            await MainActor.run { objectMetadata = meta }
        } catch {
            // Metadata load failure is non-fatal; the card stays in loading state.
        }
    }

    private func loadFile() async {
        isLoading = true
        error = nil
        downloadedBytes = 0

        do {
            // Check cache first for images
            if object.fileType == .image {
                if let cachedImage = await ImageCacheActor.shared.getFullImage(for: object.key) {
                    await MainActor.run {
                        fileContent = .image(cachedImage)
                        isLoading = false
                    }
                    return
                }
            }

            let data = try await service.downloadObject(key: object.key)
            await MainActor.run {
                downloadedBytes = Int64(data.count)
            }

            switch object.fileType {
            case .log, .text:
                if let text = String(data: data, encoding: .utf8) {
                    fileContent = .text(text)
                } else {
                    error = "Unable to decode text content"
                }
            case .image:
                // Cache the image for future use (both full and thumbnail)
                if let image = await ImageCacheActor.shared.cacheImage(from: data, for: object.key) {
                    fileContent = .image(image)
                } else {
                    error = "Unable to decode image"
                }
            case .video:
                // Write video data to temp file for AVPlayer
                let tempDir = FileManager.default.temporaryDirectory
                let tempURL = tempDir.appendingPathComponent(object.fileName)
                try data.write(to: tempURL)
                fileContent = .video(tempURL)
            case .html:
                // Reports from phone mode are self-contained (images inlined as
                // base64), so the HTML renders in a web view with no extra fetches.
                if let html = String(data: data, encoding: .utf8) {
                    fileContent = .html(html)
                } else {
                    error = "Unable to decode HTML content"
                }
            case .unknown:
                if let text = String(data: data, encoding: .utf8) {
                    fileContent = .text(text)
                } else {
                    error = "Unsupported file type"
                }
            }
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }
}

struct TextContentView: View {
    let text: String
    @State private var showLineNumbers = true

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
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(text.split(separator: "\n").enumerated()), id: \.offset) { index, line in
                            HStack(alignment: .top, spacing: 12) {
                                Text("\(index + 1)")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 40, alignment: .trailing)

                                Text(String(line))
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
    }
}

struct WebContentView: View {
    let html: String
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

            HTMLWebView(html: html)
                .frame(maxWidth: .infinity)
                .frame(height: 500)
                .cornerRadius(8)
        }
        .fullScreenCover(isPresented: $isFullScreen) {
            FullScreenWebView(html: html, isPresented: $isFullScreen)
        }
    }
}

struct FullScreenWebView: View {
    let html: String
    @Binding var isPresented: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HTMLWebView(html: html)
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

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(html, baseURL: nil)
    }
}

struct ImageContentView: View {
    let image: UIImage
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
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

            ZStack {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                scale = max(1.0, min(value, 5.0))
                            }
                    )
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                if scale > 1.0 {
                                    offset = CGSize(
                                        width: lastOffset.width + value.translation.width,
                                        height: lastOffset.height + value.translation.height
                                    )
                                }
                            }
                            .onEnded { _ in
                                lastOffset = offset
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation {
                            if scale > 1.0 {
                                scale = 1.0
                                offset = .zero
                                lastOffset = .zero
                            } else {
                                scale = 2.0
                            }
                        }
                    }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 300)
            .background(.gray.opacity(0.1))
            .cornerRadius(8)

            HStack {
                if scale > 1.0 {
                    Button("Reset") {
                        withAnimation {
                            scale = 1.0
                            offset = .zero
                            lastOffset = .zero
                        }
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
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            scale = max(1.0, min(value, 5.0))
                        }
                )
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if scale > 1.0 {
                                offset = CGSize(
                                    width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height
                                )
                            }
                        }
                        .onEnded { _ in
                            lastOffset = offset
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation {
                        if scale > 1.0 {
                            scale = 1.0
                            offset = .zero
                            lastOffset = .zero
                        } else {
                            scale = 2.0
                        }
                    }
                }

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
        .onAppear {
            setupPlayer()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
        .fullScreenCover(isPresented: $isFullScreen) {
            FullScreenVideoView(url: url, isPresented: $isFullScreen)
        }
    }

    private func setupPlayer() {
        let avPlayer = AVPlayer(url: url)
        player = avPlayer
        avPlayer.play()

        // Extract video metadata
        Task {
            let asset = AVURLAsset(url: url)
            do {
                let cmDuration = try await asset.load(.duration)
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
    let url: URL
    @Binding var isPresented: Bool
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            }

            VStack {
                HStack {
                    Spacer()
                    Button {
                        player?.pause()
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
            let avPlayer = AVPlayer(url: url)
            player = avPlayer
            avPlayer.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
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

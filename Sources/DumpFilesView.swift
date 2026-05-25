import SwiftUI
import os.log

/// Displays files uploaded from the phone (dump/ prefix in S3)
struct DumpFilesView: View {
    private let logger = Logger(subsystem: "com.s3browser", category: "DumpFilesView")
    let s3Service: S3Service
    @State private var dumpFiles: [S3Object] = []
    @State private var isLoading = false
    @State private var hasLoadedOnce = false
    @State private var loadError: String?
    @AppStorage("s3DumpViewMode") private var viewModeRaw: String = "grid"

    enum ViewMode {
        case list
        case grid
    }

    private var viewMode: ViewMode {
        viewModeRaw == "grid" ? .grid : .list
    }

    /// Only image files for gallery navigation
    private var imageFiles: [S3Object] {
        dumpFiles.filter { $0.fileType == .image }
    }

    var body: some View {
        NavigationStack {
            contentView
                .navigationTitle("Uploads")
                .toolbar { toolbarContent }
        }
        .task { await initialLoad() }
    }

    @ViewBuilder
    private var contentView: some View {
        if isLoading && !hasLoadedOnce {
            VStack(spacing: 8) {
                ProgressView()
                Text("Loading uploads...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = loadError {
            ContentUnavailableView(
                "Load Failed",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else if dumpFiles.isEmpty && hasLoadedOnce {
            ScrollView {
                ContentUnavailableView(
                    "No Uploads",
                    systemImage: "square.and.arrow.up",
                    description: Text("Files uploaded from your phone will appear here.\nUse the Upload tab or Share Extension to add files.")
                )
                .frame(maxWidth: .infinity, minHeight: 300)
            }
            .refreshable { await refreshDumpFiles() }
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
            ForEach(dumpFiles) { file in
                NavigationLink(destination: destinationView(for: file)) {
                    RecentFileRow(object: file, s3Service: s3Service)
                }
                .contextMenu { fileContextMenu(for: file) }
            }
        }
        .refreshable { await refreshDumpFiles() }
    }

    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 12) {
                ForEach(dumpFiles) { file in
                    NavigationLink(destination: destinationView(for: file)) {
                        RecentFileGridItem(object: file, s3Service: s3Service, cardSize: 100)
                    }
                    .contextMenu { fileContextMenu(for: file) }
                }
            }
            .padding()
        }
        .refreshable { await refreshDumpFiles() }
    }

    @ViewBuilder
    private func fileContextMenu(for file: S3Object) -> some View {
        Button(role: .destructive) {
            Task { await deleteFile(file) }
        } label: {
            Label("Delete", systemImage: "trash")
        }

        Button {
            UIPasteboard.general.string = file.key
        } label: {
            Label("Copy Path", systemImage: "doc.on.doc")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 12) {
                Button {
                    viewModeRaw = viewMode == .list ? "grid" : "list"
                } label: {
                    Image(systemName: viewMode == .list ? "square.grid.2x2" : "list.bullet")
                }

                Button {
                    Task { await refreshDumpFiles() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
    }

    @ViewBuilder
    private func destinationView(for file: S3Object) -> some View {
        if file.fileType == .image {
            let index = imageFiles.firstIndex(where: { $0.id == file.id }) ?? 0
            ImageGalleryView(images: imageFiles, initialIndex: index, s3Service: s3Service)
        } else {
            FileDetailView(object: file, service: s3Service)
        }
    }

    private func initialLoad() async {
        guard !s3Service.currentBucket.isEmpty else { return }
        await refreshDumpFiles()
    }

    private func refreshDumpFiles() async {
        isLoading = true
        loadError = nil

        do {
            let files = try await s3Service.fetchDumpFiles()
            await MainActor.run {
                dumpFiles = files
                isLoading = false
                hasLoadedOnce = true
            }
        } catch {
            logger.error("Failed to load dump files: \(error.localizedDescription)")
            await MainActor.run {
                loadError = error.localizedDescription
                isLoading = false
                hasLoadedOnce = true
            }
        }
    }

    private func deleteFile(_ file: S3Object) async {
        do {
            try await s3Service.deleteObject(key: file.key)
            logger.info("Deleted dump file: \(file.key)")
            await MainActor.run {
                dumpFiles.removeAll { $0.id == file.id }
            }
        } catch {
            logger.error("Failed to delete file \(file.key): \(error.localizedDescription)")
        }
    }
}

#Preview {
    DumpFilesView(s3Service: S3Service(config: S3Config.default))
}

import SwiftUI
import os.log

/// Displays files uploaded from the phone (dump/ prefix in S3)
struct DumpFilesView: View {
    @State private var rowProjection = DerivedRowsCache<[S3Object]>()
    @State private var galleryProjection = DerivedRowsCache<[S3Object]>()
    private let logger = Logger(subsystem: "com.s3browser", category: "DumpFilesView")
    let s3Service: S3Service
    private var dumpQuery: ListingQuery {
        ListingQuery(account: s3Service.session.configuration.account, bucket: s3Service.currentBucket, prefix: "dump/", delimiter: nil)
    }
    private var dumpFiles: [S3Object] {
        rowProjection.value(for: projectionKey) {
            (s3Service.session.listings.value(for: dumpQuery)?.files ?? []).sorted { $0.modified > $1.modified }.map(\.s3Object)
        }
    }
    private var projectionKey: DerivedRowsKey {
        DerivedRowsKey(revision: s3Service.session.listings.revision(for: dumpQuery),
            fields: [dumpQuery.account, dumpQuery.bucket, dumpQuery.prefix])
    }
    private var listPresentation: ListPresentation {
        .resolve(hasSnapshot: s3Service.session.listings.value(for: dumpQuery) != nil,
            rowCount: dumpFiles.count, isLoading: isLoading, error: loadError)
    }
    @State private var loadRequest = RequestOwnership()
    private var isLoading: Bool { loadRequest.isLoading }
    @State private var hasLoadedOnce = false
    @State private var loadError: String?
    @State private var showingUpload = false
    @State private var deletion = MutationFeedback()
    @State private var failedDelete: S3Object?
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
        galleryProjection.value(for: projectionKey) { dumpFiles.filter { $0.fileType == .image } }
    }

    var body: some View {
        AuditTelemetry.shared.measureViewConstruction(.dump) { measuredContent }
    }

    private var measuredContent: some View {
        NavigationStack {
            contentView
                .navigationTitle("Upload")
                .safeAreaInset(edge: .top) {
                    if isLoading && !dumpFiles.isEmpty { ProgressView("Refreshing uploads...") }
                    if let error = loadError, !dumpFiles.isEmpty {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                        Button("Retry Refresh") { Task { await refreshDumpFiles(force: true) } }.disabled(isLoading)
                    }
                }
                .toolbar { toolbarContent }
                .sheet(isPresented: $showingUpload) {
                    DropUploadView(s3Service: s3Service)
                }
        }
        .task(id: dumpQuery) { await initialLoad() }
        .alert("Delete Failed", isPresented: Binding(
            get: { deletion.errorMessage != nil }, set: { if !$0 { deletion.clearError() } }
        )) {
            Button("Retry") { if let file = failedDelete { Task { await deleteFile(file) } } }
            Button("Dismiss", role: .cancel) { deletion.clearError() }
        } message: { Text(deletion.errorMessage ?? "") }
    }

    @ViewBuilder
    private var contentView: some View {
        if listPresentation == .initialLoading {
            VStack(spacing: 8) {
                ProgressView()
                Text("Loading uploads...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = loadError, dumpFiles.isEmpty {
            ContentUnavailableView {
                Label("Load Failed", systemImage: "exclamationmark.triangle")
            } description: { Text(error) } actions: {
                Button("Retry") { Task { await refreshDumpFiles(force: true) } }
            }
        } else if dumpFiles.isEmpty && hasLoadedOnce {
            ScrollView {
                ContentUnavailableView(
                    "No Uploads",
                    systemImage: "square.and.arrow.up",
                    description: Text("Files uploaded from your phone will appear here.\nUse the Upload tab or Share Extension to add files.")
                )
                .frame(maxWidth: .infinity, minHeight: 300)
            }
            .refreshable { await refreshDumpFiles(force: true) }
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
        .refreshable { await refreshDumpFiles(force: true) }
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
        .refreshable { await refreshDumpFiles(force: true) }
    }

    @ViewBuilder
    private func fileContextMenu(for file: S3Object) -> some View {
        Button(role: .destructive) {
            Task { await deleteFile(file) }
        } label: {
            Label("Delete", systemImage: "trash")
        }
        .disabled(deletion.isRunning)

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
                    Task { await refreshDumpFiles(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }

                Button {
                    showingUpload = true
                } label: {
                    Image(systemName: "plus")
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

    private func refreshDumpFiles(force: Bool = false) async {
        let requestID = loadRequest.begin()
        let generation = s3Service.session.generation
        defer { loadRequest.finish(requestID) }
        loadError = nil

        do {
            _ = try await s3Service.fetchDumpFiles(force: force)
            guard loadRequest.owns(requestID), s3Service.session.isCurrent(generation) else { return }
            await MainActor.run {
                hasLoadedOnce = true
            }
        } catch is CancellationError {
            return
        } catch {
            guard loadRequest.owns(requestID), s3Service.session.isCurrent(generation) else { return }
            logger.error("Failed to load dump files: \(error.localizedDescription)")
            await MainActor.run {
                loadError = error.localizedDescription
                hasLoadedOnce = true
            }
        }
    }

    private func deleteFile(_ file: S3Object) async {
        let bucket = file.bucket ?? s3Service.currentBucket
        let succeeded = await deletion.perform(action: {
            try await s3Service.deleteObject(key: file.key, bucket: bucket)
        }, didSucceed: {
            logger.info("Deleted dump file: \(file.key)")
        })
        failedDelete = succeeded ? nil : file
    }
}

#Preview {
    DumpFilesView(s3Service: S3Service(config: S3Config.default))
}

import SwiftUI
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
    @State private var errorMessage: String? = nil

    var body: some View {
        Group {
            if isLoading {
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
                }
                .refreshable { await load() }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let loaded = try await s3Service.listPrefix(prefix, bucket: bucket)
            items = loaded
        } catch {
            logger.error("listPrefix(\(prefix)) failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
        isLoading = false
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

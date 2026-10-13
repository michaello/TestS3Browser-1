import SwiftUI
import os.log

/// Sheet that lets the user browse the bucket prefix tree and pick a destination
/// for a Move or Copy operation. Confirms with "Move here" / "Copy here" buttons.
struct PrefixPickerSheet: View {
    enum Mode { case move, copy }

    let s3Service: S3Service
    let sourceBucket: String
    let sourceObject: S3Object
    let mode: Mode
    /// Synchronously hands off a choice; the parent starts remote work after dismissal.
    let onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    private let logger = Logger(subsystem: "com.s3browser", category: "PrefixPickerSheet")

    /// Stack of prefixes the user has drilled into. Empty = bucket root.
    @State private var prefixStack: [String] = []
    @State private var listing = PagedListingState()
    private var isLoading: Bool { listing.isLoading }
    @State private var selection = DestinationSelection()

    private var currentPrefix: String { prefixStack.last ?? "" }
    private var query: ListingQuery {
        ListingQuery(account: s3Service.session.configuration.account, bucket: sourceBucket, prefix: currentPrefix)
    }

    private var confirmLabel: String {
        let here = currentPrefix.isEmpty ? "/" : "/\(currentPrefix)"
        return mode == .move ? "Move here\(here)" : "Copy here\(here)"
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && listing.page == nil {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        // Back row when drilled in
                        if !prefixStack.isEmpty {
                            Button {
                                prefixStack.removeLast()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "chevron.left")
                                    Text("Back")
                                }
                                .foregroundStyle(Color.accentColor)
                            }
                        }

                        ForEach(folders) { folder in
                            Button {
                                prefixStack.append(folder.prefix)
                            } label: {
                                HStack {
                                    Image(systemName: "folder.fill")
                                        .foregroundStyle(.blue)
                                    Text(folder.folderName)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .foregroundStyle(.primary)
                        }

                        if let error = listing.error {
                            Text(error).font(.caption).foregroundStyle(.secondary)
                            Button("Retry") { Task { await loadFolders(force: true) } }
                        }
                        if listing.hasMore {
                            Button("Load more folders") { Task { await loadMoreFolders() } }
                                .disabled(isLoading || listing.isLoadingMore)
                            if listing.isLoadingMore { ProgressView() }
                        }
                        if folders.isEmpty && !isLoading && listing.error == nil && !listing.hasMore {
                            Text("No sub-folders")
                                .foregroundStyle(.secondary)
                                .font(.subheadline)
                        }
                    }
                }
            }
            .navigationTitle(currentPrefix.isEmpty ? sourceBucket : currentPrefix)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { selection.cancel(); dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        confirm()
                    } label: {
                        Text(mode == .move ? "Move" : "Copy")
                            .fontWeight(.semibold)
                    }
                    .disabled(selection.hasDecided || isSameDestination || !listing.canConfirmDestination(query))
                }
            }
            .safeAreaInset(edge: .bottom) {
                destinationBanner
            }
        }
        .task(id: query) { await loadFolders() }
        .onDisappear { selection.cancel() }
    }

    // MARK: - Subviews

    private var destinationBanner: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "arrow.right.circle.fill")
                    .foregroundStyle(isSameDestination ? Color.secondary : Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(confirmLabel)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    if isSameDestination {
                        Text("Source and destination are the same")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemBackground))
        }
    }

    // MARK: - Helpers

    private var folders: [S3Folder] {
        guard listing.query == query else { return [] }
        return (listing.page?.folders ?? []).map { S3Folder(prefix: $0) }
    }

    private var isSameDestination: Bool {
        S3TransferKeys.isSameDestination(sourceBucket: sourceObject.bucket ?? sourceBucket,
            sourceKey: sourceObject.key, destinationBucket: sourceBucket, destinationPrefix: currentPrefix)
    }

    private func loadFolders(force: Bool = false) async {
        let expected = query
        do {
            try await listing.reload(expected, force: force) { token in
                try await s3Service.fetchPrefixMetadataPage(expected, token: token)
            }
        } catch {
            logger.error("PrefixPickerSheet listPrefix failed: \(error.localizedDescription)")
        }
    }

    private func loadMoreFolders() async {
        let expected = query
        do {
            try await listing.loadMore { token in try await s3Service.fetchPrefixMetadataPage(expected, token: token) }
        } catch { logger.error("PrefixPickerSheet pagination failed: \(error.localizedDescription)") }
    }

    private func confirm() {
        guard let destination = selection.confirm(currentPrefix,
            canConfirm: listing.canConfirmDestination(query)) else { return }
        onConfirm(destination)
        dismiss()
    }
}

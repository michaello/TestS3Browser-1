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
    /// Called with the chosen destination prefix on confirm. The callee performs the operation.
    let onConfirm: (String) async -> Void

    @Environment(\.dismiss) private var dismiss
    private let logger = Logger(subsystem: "com.s3browser", category: "PrefixPickerSheet")

    /// Stack of prefixes the user has drilled into. Empty = bucket root.
    @State private var prefixStack: [String] = []
    @State private var items: [S3Item] = []
    @State private var isLoading = false
    @State private var isConfirming = false

    private var currentPrefix: String { prefixStack.last ?? "" }

    private var confirmLabel: String {
        let here = currentPrefix.isEmpty ? "/" : "/\(currentPrefix)"
        return mode == .move ? "Move here\(here)" : "Copy here\(here)"
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
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

                        if folders.isEmpty && !isLoading {
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
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await confirm() }
                    } label: {
                        if isConfirming {
                            ProgressView()
                        } else {
                            Text(mode == .move ? "Move" : "Copy")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(isConfirming || isSameDestination)
                }
            }
            .safeAreaInset(edge: .bottom) {
                destinationBanner
            }
        }
        .task(id: currentPrefix) { await loadFolders() }
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
        items.compactMap { if case .folder(let f) = $0 { return f } else { return nil } }
    }

    private var isSameDestination: Bool {
        currentPrefix == (sourceObject.bucket.map { _ in "" } ?? "") &&
        sourceBucket == (sourceObject.bucket ?? sourceBucket) &&
        currentPrefix == sourcePrefix
    }

    private var sourcePrefix: String {
        let parts = sourceObject.key.split(separator: "/").dropLast()
        return parts.isEmpty ? "" : parts.joined(separator: "/") + "/"
    }

    private func loadFolders() async {
        isLoading = true
        do {
            let page = try await s3Service.listPrefix(currentPrefix, bucket: sourceBucket)
            items = page.items
        } catch {
            logger.error("PrefixPickerSheet listPrefix failed: \(error.localizedDescription)")
        }
        isLoading = false
    }

    private func confirm() async {
        isConfirming = true
        await onConfirm(currentPrefix)
        isConfirming = false
        dismiss()
    }
}

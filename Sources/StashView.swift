import SwiftUI
import os.log

/// Phone-mode reports living in the phone-stash bucket under reports/YYYY/MM/DD/.
/// Loaded with one ListObjectsV2 call scoped to the reports/ prefix, so it is fast
/// regardless of how large the other buckets are. Newest report shows first.
struct StashView: View {
    private let logger = Logger(subsystem: "com.s3browser", category: "StashView")
    let s3Service: S3Service
    private let bucket = "phone-stash"
    /// Separate seen-tracking namespace so the Recent tab's all-buckets scan (which
    /// marks phone-stash keys seen under the plain bucket name) cannot clobber the
    /// Stash tab's "new until tapped" state.
    private let seenKey = "phone-stash:stash"

    @State private var reports: [S3Object] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var navigationPath = NavigationPath()
    /// Keys of reports we have not seen or tapped yet - emphasized in the list.
    @State private var newKeys: Set<String> = []
    /// Drives the delete-failure alert. Set when deleteReport catches a thrown error.
    @State private var showDeleteError = false
    @State private var deleteErrorMessage = ""

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if isLoading && reports.isEmpty {
                    ProgressView("Loading reports...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    ContentUnavailableView {
                        Label("Couldn't load reports", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    }
                } else if reports.isEmpty {
                    ContentUnavailableView {
                        Label("No reports yet", systemImage: "doc.richtext")
                    } description: {
                        Text("Reports published with /phone show up here.")
                    }
                } else {
                    List(reports) { report in
                        Button {
                            markSeen(report)
                            navigationPath.append(report)
                        } label: {
                            StashRow(report: report, isNew: newKeys.contains(report.key))
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) {
                                Task { await deleteReport(report) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Stash")
            .navigationDestination(for: S3Object.self) { report in
                FileDetailView(object: report, service: s3Service)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .refreshable { await load() }
            .task {
                if reports.isEmpty { await load() }
            }
            .deleteErrorAlert(isPresented: $showDeleteError, message: deleteErrorMessage)
        }
    }

    private func load() async {
        isLoading = true
        error = nil
        do {
            let fetched = try await s3Service.fetchStashReports(bucket: bucket)

            // Flag reports we have not seen before. Only flag when we have a prior
            // seen record, so the very first visit does not light up everything.
            let keys = fetched.map { $0.key }
            var unseen: Set<String> = []
            if await SeenPhotosTracker.shared.hasSeenPhotos(for: seenKey) {
                unseen = Set(await SeenPhotosTracker.shared.findNewPhotos(currentPhotos: keys, bucket: seenKey))
            } else if !keys.isEmpty {
                // First visit: record them as seen so they are not all "new" next time.
                await SeenPhotosTracker.shared.markAsSeen(photoKeys: keys, bucket: seenKey)
            }

            await MainActor.run {
                reports = fetched
                // Keep emphasis on anything still unseen, plus anything already
                // flagged new in this session that the user has not tapped yet.
                newKeys = unseen.union(newKeys).intersection(Set(keys))
            }
            // Prefetch so tapping a report opens instantly.
            s3Service.prefetchObjects(fetched)
        } catch {
            await MainActor.run { self.error = error.localizedDescription }
            logger.error("Failed to load stash reports: \(error.localizedDescription)")
        }
        await MainActor.run { isLoading = false }
    }

    /// A report stops being "new" once tapped. Persist that so it stays seen across
    /// launches, and drop the in-list emphasis immediately.
    private func markSeen(_ report: S3Object) {
        guard newKeys.contains(report.key) else { return }
        newKeys.remove(report.key)
        Task {
            // Additive - keep the rest of the bucket's seen record intact.
            await SeenPhotosTracker.shared.addSeen(photoKeys: [report.key], bucket: seenKey)
        }
    }

    /// Deletes a report from the phone-stash bucket and removes it from the list.
    /// On failure, surfaces the error in the delete-failure alert.
    private func deleteReport(_ report: S3Object) async {
        do {
            try await s3Service.deleteObject(key: report.key, bucket: bucket)
            logger.info("Deleted report: \(report.key)")
            await MainActor.run { reports.removeAll { $0.key == report.key } }
        } catch {
            logger.error("Failed to delete report \(report.key): \(error.localizedDescription)")
            await MainActor.run {
                deleteErrorMessage = "Could not delete \(report.fileName): \(error.localizedDescription)"
                showDeleteError = true
            }
        }
    }
}

private struct StashRow: View {
    let report: S3Object
    let isNew: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.richtext")
                .font(.title2)
                .foregroundStyle(isNew ? .teal : .secondary)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(report.fileName)
                        .font(.subheadline)
                        .fontWeight(isNew ? .semibold : .regular)
                        .lineLimit(1)

                    if isNew {
                        Text("NEW")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.teal))
                    }
                }
                Text("\(report.lastModified.relativeFormattedCompact()) - \(report.formattedSize)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Unseen reports get a filled accent dot, seen ones the usual chevron.
            if isNew {
                Circle()
                    .fill(.teal)
                    .frame(width: 8, height: 8)
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

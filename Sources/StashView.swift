import SwiftUI
import os.log

/// Phone-mode reports living in the phone-stash bucket under reports/YYYY/MM/DD/.
/// Loaded with one ListObjectsV2 call scoped to the reports/ prefix, so it is fast
/// regardless of how large the other buckets are. Newest report shows first.
struct StashView: View {
    private let logger = Logger(subsystem: "com.s3browser", category: "StashView")
    let s3Service: S3Service

    @State private var reports: [S3Object] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var navigationPath = NavigationPath()

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
                        NavigationLink(value: report) {
                            StashRow(report: report)
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
        }
    }

    private func load() async {
        isLoading = true
        error = nil
        do {
            let fetched = try await s3Service.fetchStashReports()
            await MainActor.run { reports = fetched }
            // Prefetch so tapping a report opens instantly.
            s3Service.prefetchObjects(fetched)
        } catch {
            await MainActor.run { self.error = error.localizedDescription }
            logger.error("Failed to load stash reports: \(error.localizedDescription)")
        }
        await MainActor.run { isLoading = false }
    }
}

private struct StashRow: View {
    let report: S3Object

    /// reports/2026/05/25/171239-report.html -> "May 25, 2026 - 17:12:39"
    private var displayDate: String {
        report.lastModified.formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.richtext")
                .font(.title2)
                .foregroundStyle(.teal)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(report.fileName)
                    .font(.subheadline)
                    .lineLimit(1)
                Text("\(displayDate) - \(report.formattedSize)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

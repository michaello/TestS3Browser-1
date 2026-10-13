import SwiftUI
import os.log

@Observable @MainActor
final class StatsViewModel {
    var stats: [BucketStats] = []
    var isLoading = false
    var error: String?
    private var requestID: UUID?

    private let logger = Logger(subsystem: "com.s3browser", category: "StatsViewModel")

    func load(s3Service: S3Service, force: Bool = false) async {
        let id = UUID()
        requestID = id
        let generation = s3Service.session.generation
        isLoading = true
        error = nil
        do {
            let fetched = try await s3Service.fetchBucketStats(force: force)
            guard requestID == id, s3Service.session.isCurrent(generation) else { return }
            stats = fetched
            error = s3Service.recentRefreshError
        } catch {
            guard requestID == id, s3Service.session.isCurrent(generation) else { return }
            logger.error("fetchBucketStats failed: \(error.localizedDescription)")
            self.error = error.localizedDescription
        }
        if requestID == id { isLoading = false }
    }
}

struct StatsView: View {
    let s3Service: S3Service
    @State private var viewModel = StatsViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading && viewModel.stats.isEmpty {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Scanning buckets…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = viewModel.error, viewModel.stats.isEmpty {
                    ContentUnavailableView(
                        "Failed to Load",
                        systemImage: "exclamationmark.triangle",
                        description: Text(err)
                    )
                } else if viewModel.stats.isEmpty {
                    ContentUnavailableView(
                        "No Buckets",
                        systemImage: "cylinder.split.1x2",
                        description: Text("No accessible buckets found")
                    )
                } else {
                    statsList
                }
            }
            .navigationTitle("Storage Stats")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await viewModel.load(s3Service: s3Service, force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(viewModel.isLoading)
                }
            }
        }
        .task(id: s3Service.session.generation) { await viewModel.load(s3Service: s3Service) }
    }

    private var statsList: some View {
        List {
            if let message = viewModel.error ?? s3Service.recentRefreshError {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Totals include last saved data for unavailable buckets.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                summaryRow
            }
            Section("Buckets") {
                ForEach(viewModel.stats) { stat in
                    BucketStatsRow(stat: stat)
                }
            }
        }
        .refreshable { await viewModel.load(s3Service: s3Service, force: true) }
    }

    private var summaryRow: some View {
        let totalObjects = viewModel.stats.reduce(0) { $0 + $1.objectCount }
        let totalBytes = viewModel.stats.reduce(Int64(0)) { $0 + $1.totalBytes }
        let summary = BucketStats(bucket: "__summary__", objectCount: totalObjects, totalBytes: totalBytes)
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(s3Service.isCatalogComplete ? "Total Objects" : "Objects (incomplete)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(summary.formattedCount)
                    .font(.headline)
            }
            Divider().frame(height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(s3Service.isCatalogComplete ? "Total Size" : "Size (incomplete)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(summary.formattedSize)
                    .font(.headline)
            }
            Spacer()
            Text("\(viewModel.stats.count) buckets")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct BucketStatsRow: View {
    let stat: BucketStats

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "cylinder.split.1x2")
                .foregroundStyle(.blue)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(stat.bucket)
                    .font(.headline)
                    .lineLimit(1)
                Text(stat.formattedCount)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(stat.formattedSize)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    StatsView(s3Service: S3Service(config: S3Config.default))
}

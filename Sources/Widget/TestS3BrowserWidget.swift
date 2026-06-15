import WidgetKit
import SwiftUI

private let appGroupSuite = "group.com.crispytoast.TestS3Browser"
private let recentUploadsKey = "recentUploads"

// Mirrors S3Object's Codable shape stored by S3Service.
struct WidgetUpload: Codable, Identifiable {
    let key: String
    let size: Int64
    let lastModified: Date
    let etag: String?
    let bucket: String?

    var id: String { bucket.map { "\($0)/\(key)" } ?? key }

    var fileName: String {
        URL(string: key)?.lastPathComponent ?? key
    }

    var isImage: Bool {
        let ext = fileName.lowercased().split(separator: ".").last.map(String.init) ?? ""
        return ["png", "jpg", "jpeg", "gif", "heic"].contains(ext)
    }

    var formattedSize: String {
        let kb = Double(size) / 1024.0
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        return String(format: "%.1f MB", kb / 1024.0)
    }

    var relativeDate: String {
        let interval = Date().timeIntervalSince(lastModified)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }
}

struct RecentUploadsEntry: TimelineEntry {
    let date: Date
    let uploads: [WidgetUpload]
}

struct RecentUploadsProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecentUploadsEntry {
        RecentUploadsEntry(date: .now, uploads: [])
    }

    func getSnapshot(in context: Context, completion: @escaping (RecentUploadsEntry) -> Void) {
        completion(RecentUploadsEntry(date: .now, uploads: loadUploads()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecentUploadsEntry>) -> Void) {
        let uploads = loadUploads()
        let entry = RecentUploadsEntry(date: .now, uploads: uploads)
        // Refresh every 15 minutes.
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 15, to: .now) ?? .now
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    private func loadUploads() -> [WidgetUpload] {
        guard
            let defaults = UserDefaults(suiteName: appGroupSuite),
            let data = defaults.data(forKey: recentUploadsKey),
            let uploads = try? JSONDecoder().decode([WidgetUpload].self, from: data)
        else { return [] }
        return Array(uploads.prefix(3))
    }
}

// MARK: - Small widget (single most recent file)

struct SmallWidgetView: View {
    let uploads: [WidgetUpload]

    var body: some View {
        if let top = uploads.first {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: top.isImage ? "photo" : "doc")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(top.fileName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                Text(top.relativeDate)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let bucket = top.bucket {
                    Text(bucket)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(12)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "icloud.slash")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("No uploads yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Medium widget (up to 3 recent files)

struct MediumWidgetView: View {
    let uploads: [WidgetUpload]

    var body: some View {
        if uploads.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "icloud.slash")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("No uploads yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Image(systemName: "arrow.up.to.line")
                        .font(.caption.weight(.semibold))
                    Text("Recent Uploads")
                        .font(.caption.weight(.semibold))
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 6)

                ForEach(uploads) { upload in
                    HStack(spacing: 10) {
                        Image(systemName: upload.isImage ? "photo" : "doc")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(upload.fileName)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            Text("\(upload.formattedSize) · \(upload.relativeDate)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let bucket = upload.bucket {
                            Text(bucket)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .frame(maxWidth: 80, alignment: .trailing)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)

                    if upload.id != uploads.last?.id {
                        Divider()
                            .padding(.leading, 44)
                    }
                }
                Spacer()
            }
        }
    }
}

// MARK: - Widget entry view

struct TestS3BrowserWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: RecentUploadsEntry

    var body: some View {
        switch family {
        case .systemSmall:
            SmallWidgetView(uploads: entry.uploads)
        case .systemMedium:
            MediumWidgetView(uploads: entry.uploads)
        default:
            MediumWidgetView(uploads: entry.uploads)
        }
    }
}

// MARK: - Widget definition

struct TestS3BrowserWidget: Widget {
    let kind = "TestS3BrowserWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RecentUploadsProvider()) { entry in
            TestS3BrowserWidgetEntryView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Recent Uploads")
        .description("Shows the 3 most recently uploaded files to S3.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Widget bundle

@main
struct TestS3BrowserWidgetBundle: WidgetBundle {
    var body: some Widget {
        TestS3BrowserWidget()
    }
}

#Preview(as: .systemSmall) {
    TestS3BrowserWidget()
} timeline: {
    RecentUploadsEntry(date: .now, uploads: [])
}

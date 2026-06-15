import SwiftUI

/// Bottom-sheet overlay listing all available buckets with cached object counts.
/// Fetches counts once per open; tapping a bucket switches the active one and dismisses.
struct BucketSwitcherOverlay: View {
    let s3Service: S3Service
    let onSelect: (String) -> Void
    let onDismiss: () -> Void

    @State private var bucketCounts: [String: (count: Int, truncated: Bool)] = [:]
    @State private var isFetching = false

    var body: some View {
        VStack(spacing: 0) {
            // Drag handle
            Capsule()
                .fill(Color(.systemGray4))
                .frame(width: 36, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 4)

            HStack {
                Text("Buckets")
                    .font(.headline)
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color(.systemGray3))
                        .font(.title3)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(s3Service.availableBuckets, id: \.self) { bucket in
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                onSelect(bucket)
                            }
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "cylinder.split.1x2")
                                    .foregroundStyle(bucket == s3Service.currentBucket ? .blue : .secondary)
                                    .font(.title3)
                                    .frame(width: 28)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(bucket)
                                        .font(.body)
                                        .fontWeight(bucket == s3Service.currentBucket ? .semibold : .regular)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)

                                    if let info = bucketCounts[bucket] {
                                        Text(info.truncated ? "\(info.count)+ objects" : "\(info.count) object\(info.count == 1 ? "" : "s")")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else if isFetching {
                                        Text("Loading…")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                }

                                Spacer()

                                if bucket == s3Service.currentBucket {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                        .fontWeight(.semibold)
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Divider()
                            .padding(.leading, 62)
                    }
                }
            }
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 20, x: 0, y: -4)
        .task { await fetchCounts() }
    }

    private func fetchCounts() async {
        guard !isFetching else { return }
        isFetching = true
        await withTaskGroup(of: (String, Int, Bool).self) { group in
            for bucket in s3Service.availableBuckets {
                group.addTask {
                    let (count, truncated) = await s3Service.quickObjectCount(bucket: bucket)
                    return (bucket, count, truncated)
                }
            }
            for await (bucket, count, truncated) in group {
                bucketCounts[bucket] = (count, truncated)
            }
        }
        isFetching = false
    }
}

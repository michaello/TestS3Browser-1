import SwiftUI

struct UploadQueueSheet: View {
    @State private var manager = UploadQueueManager.shared

    var body: some View {
        NavigationStack {
            Group {
                if manager.items.isEmpty {
                    ContentUnavailableView(
                        "No Uploads",
                        systemImage: "arrow.up.circle",
                        description: Text("Queued uploads will appear here.")
                    )
                } else {
                    List(manager.items) { item in
                        UploadQueueRow(item: item, manager: manager)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Upload Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear Done") {
                        manager.removeCompleted()
                    }
                    .disabled(!manager.items.contains(where: \.isDone))
                }
            }
        }
    }
}

private struct UploadQueueRow: View {
    let item: UploadItem
    let manager: UploadQueueManager

    var body: some View {
        HStack(spacing: 12) {
            stateIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(item.filename)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(item.key.split(separator: "/").last.map(String.init) ?? item.key)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if case .failed(let msg) = item.state {
                    Text(msg)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                if item.retryCount > 0 {
                    Text("Attempt \(item.retryCount + 1)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if case .failed = item.state {
                Button("Retry") {
                    manager.retry(id: item.id)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.orange)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch item.state {
        case .pending:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
                .frame(width: 28)
        case .uploading(let progress):
            ZStack {
                CircularProgressView(progress: progress)
                    .frame(width: 28, height: 28)
            }
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .frame(width: 28)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .frame(width: 28)
        }
    }
}

private struct CircularProgressView: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.25), lineWidth: 3)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(progress * 100))%")
                .font(.system(size: 7, weight: .medium))
        }
    }
}

#Preview {
    UploadQueueSheet()
}

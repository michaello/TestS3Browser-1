import SwiftUI

/// Half-height sheet for sharing a presigned S3 URL with a configurable expiry.
/// The user picks an expiry duration, then copies or shares the generated URL.
struct SharePresignedURLSheet: View {
    let object: S3Object
    let s3Service: S3Service
    @Environment(\.dismiss) private var dismiss

    struct ExpiryOption: Identifiable {
        let id: Int
        let label: String
        var seconds: Int { id }
    }

    private let expiryOptions: [ExpiryOption] = [
        ExpiryOption(id: 3_600,     label: "1 hour"),
        ExpiryOption(id: 86_400,    label: "1 day"),
        ExpiryOption(id: 259_200,   label: "3 days"),
        ExpiryOption(id: 604_800,   label: "7 days"),
    ]

    @State private var selectedExpiry = 86_400
    @State private var copyToast: String?

    private var generatedURL: String? {
        s3Service.generatePresignedURL(for: object.key, bucket: object.bucket, expiresIn: selectedExpiry)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // File identity
                HStack(spacing: 12) {
                    Image(systemName: object.fileType.icon)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(object.fileName)
                            .font(.headline)
                            .lineLimit(1)
                        Text(object.formattedSize)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal)

                // Expiry picker
                VStack(alignment: .leading, spacing: 10) {
                    Text("Link expires after")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)

                    HStack(spacing: 10) {
                        ForEach(expiryOptions) { option in
                            Button {
                                selectedExpiry = option.id
                            } label: {
                                Text(option.label)
                                    .font(.subheadline)
                                    .fontWeight(selectedExpiry == option.id ? .semibold : .regular)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .frame(maxWidth: .infinity)
                                    .background(
                                        selectedExpiry == option.id
                                            ? Color.accentColor
                                            : Color(.secondarySystemBackground),
                                        in: RoundedRectangle(cornerRadius: 8)
                                    )
                                    .foregroundStyle(selectedExpiry == option.id ? Color.white : Color.primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }

                // URL preview
                if let url = generatedURL {
                    Text(url)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .padding(.horizontal)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Action buttons
                HStack(spacing: 12) {
                    Button {
                        guard let url = generatedURL else { return }
                        UIPasteboard.general.string = url
                        showToast("Link copied")
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(generatedURL == nil)

                    if let url = generatedURL {
                        ShareLink(item: url) {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button {
                        } label: {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(true)
                    }
                }
                .padding(.horizontal)

                Spacer()
            }
            .padding(.top, 20)
            .navigationTitle("Share Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay(alignment: .bottom) {
                if let toast = copyToast {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(toast)
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .cornerRadius(10)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: copyToast)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func showToast(_ message: String) {
        copyToast = message
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { copyToast = nil }
        }
    }
}

#Preview {
    SharePresignedURLSheet(
        object: S3Object(key: "dump/photo.jpg", size: 1_024_000, lastModified: Date(), etag: nil, bucket: "my-bucket"),
        s3Service: S3Service(config: S3Config.default)
    )
}

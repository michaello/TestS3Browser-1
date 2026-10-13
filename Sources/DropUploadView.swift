import SwiftUI
import PhotosUI
import os.log

/// View for uploading images to S3 dump folder via photo picker or drag-and-drop
struct DropUploadView: View {
    private let logger = Logger(subsystem: "com.s3browser", category: "DropUploadView")
    let s3Service: S3Service

    @State private var selectedItem: PhotosPickerItem?
    @State private var isUploading = false
    @State private var uploadProgress: Double = 0
    @State private var uploadResult: UploadResult?
    @State private var isDropTargeted = false
    @State private var batchSummary: String?
    @State private var copyToast: String?
    @State private var uploadInputTask: Task<Void, Never>?

    enum UploadResult {
        case success(String)
        case failure(String)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                VStack(spacing: 24) {
                    Spacer()

                    // Drop zone
                    dropZone

                    // Or use photo picker
                    PhotosPicker(
                        selection: $selectedItem,
                        matching: .images,
                        photoLibrary: .shared()
                    ) {
                        Label("Choose from Library", systemImage: "photo.on.rectangle")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                    .disabled(isUploading)
                    .padding(.horizontal)

                    // Upload status
                    if isUploading {
                        VStack(spacing: 6) {
                            ProgressView(value: uploadProgress)
                                .progressViewStyle(.linear)
                                .padding(.horizontal)
                            Text(uploadProgress < 1 ? "Uploading \(Int(uploadProgress * 100))%..." : "Finishing...")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let batchSummary {
                        Text(batchSummary).font(.caption).padding(.horizontal)
                    }
                    // Result message
                    if let result = uploadResult {
                        resultView(result)
                    }

                    Spacer()
                }

                // Copy toast
                if let toast = copyToast {
                    VStack {
                        Spacer()
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
                        .padding(.bottom, 16)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: copyToast)
            .navigationTitle("Upload to Dump")
            .onChange(of: selectedItem) { _, newItem in
                let context = UploadContext(service: s3Service, prefix: "dump/")
                let previous = uploadInputTask
                previous?.cancel()
                uploadInputTask = Task {
                    await previous?.value
                    guard !Task.isCancelled else { return }
                    await handleSelectedItem(newItem, context: context)
                }
            }
            .onDisappear { uploadInputTask?.cancel() }
        }
    }

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    isDropTargeted ? Color.blue : Color.gray.opacity(0.5),
                    style: StrokeStyle(lineWidth: 2, dash: [10])
                )
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(isDropTargeted ? Color.blue.opacity(0.1) : Color.clear)
                )

            VStack(spacing: 16) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 48))
                    .foregroundStyle(isDropTargeted ? .blue : .gray)

                Text("Drop image here")
                    .font(.title2)
                    .foregroundStyle(isDropTargeted ? .blue : .secondary)

                Text("or use the button below")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 200)
        .padding(.horizontal)
        .dropDestination(for: Data.self) { items, _ in
            guard !items.isEmpty else { return false }
            let context = UploadContext(service: s3Service, prefix: "dump/")
            Task { await uploadImages(items, context: context) }
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
    }

    @ViewBuilder
    private func resultView(_ result: UploadResult) -> some View {
        switch result {
        case .success(let key):
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Upload successful!")
                        .fontWeight(.semibold)
                }

                Text(key)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                HStack(spacing: 12) {
                    Button {
                        UIPasteboard.general.string = key
                        showCopyToast("Path copied")
                    } label: {
                        Label("Copy Path", systemImage: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        if let url = s3Service.generatePresignedURL(for: key, expiresIn: 86400) {
                            UIPasteboard.general.string = url
                            showCopyToast("Link copied")
                        } else {
                            showCopyToast("Could not generate link")
                        }
                    } label: {
                        Label("Copy Link", systemImage: "link")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
            .background(Color.green.opacity(0.1))
            .cornerRadius(12)
            .padding(.horizontal)

        case .failure(let error):
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                    Text("Upload failed")
                        .fontWeight(.semibold)
                }

                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .background(Color.red.opacity(0.1))
            .cornerRadius(12)
            .padding(.horizontal)
        }
    }

    private func handleSelectedItem(_ item: PhotosPickerItem?, context: UploadContext) async {
        guard let item = item else { return }
        isUploading = true
        uploadProgress = 0
        uploadResult = nil
        batchSummary = nil
        defer { isUploading = false }
        do {
            try await UploadPreparation.perform(destination: context.destination,
                load: { try await item.loadTransferable(type: ImportedUploadFile.self)?.payload },
                isCurrentAccount: { context.matches(s3Service) },
                send: { payload, _ in
                    guard case .file(let file) = payload.body else { throw UploadPreparationError.unavailableRepresentation }
                    let key = try await s3Service.uploadToDump(imageFile: file, bucket: context.destination.bucket,
                        expectedConfig: context.configuration, expectedGeneration: context.generation,
                        onProgress: { uploadProgress = $0 })
                    batchSummary = "Uploaded 1 of 1 image."
                    uploadResult = .success(key)
                    selectedItem = nil
                })
        } catch is CancellationError {
            // The view ended before representation loading could start a queued upload.
        } catch {
            logger.error("Failed to load image: \(error.localizedDescription)")
            uploadResult = .failure(error.localizedDescription)
        }
    }

    private func showCopyToast(_ message: String) {
        copyToast = message
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { copyToast = nil }
        }
    }

    private func uploadImages(_ items: [Data], context: UploadContext) async {
        isUploading = true
        uploadProgress = 0
        uploadResult = nil
        batchSummary = nil
        defer { isUploading = false }
        let outcome = await ImageDropBatch.process(items) { image in
            try await s3Service.uploadToDump(imageData: image.data, bucket: context.destination.bucket,
                expectedConfig: context.configuration, expectedGeneration: context.generation,
                onProgress: { uploadProgress = $0 })
        }
        batchSummary = outcome.summary
        if outcome.failures.isEmpty, let key = outcome.uploadedKeys.last {
            uploadResult = .success(key)
            selectedItem = nil
        } else {
            uploadResult = .failure(outcome.summary)
        }
    }

}

#Preview {
    DropUploadView(s3Service: S3Service(config: S3Config.default))
}

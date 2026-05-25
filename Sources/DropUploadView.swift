import SwiftUI
import PhotosUI
import os.log

/// View for uploading images to S3 dump folder via photo picker or drag-and-drop
struct DropUploadView: View {
    private let logger = Logger(subsystem: "com.s3browser", category: "DropUploadView")
    let s3Service: S3Service

    @State private var selectedItem: PhotosPickerItem?
    @State private var isUploading = false
    @State private var uploadResult: UploadResult?
    @State private var isDropTargeted = false

    enum UploadResult {
        case success(String)
        case failure(String)
    }

    var body: some View {
        NavigationStack {
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
                    HStack {
                        ProgressView()
                        Text("Uploading...")
                            .foregroundStyle(.secondary)
                    }
                }

                // Result message
                if let result = uploadResult {
                    resultView(result)
                }

                Spacer()
            }
            .navigationTitle("Upload to Dump")
            .onChange(of: selectedItem) { _, newItem in
                Task {
                    await handleSelectedItem(newItem)
                }
            }
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
            guard let data = items.first else { return false }
            Task {
                await uploadImageData(data)
            }
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

                Button {
                    UIPasteboard.general.string = key
                } label: {
                    Label("Copy Path", systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
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

    private func handleSelectedItem(_ item: PhotosPickerItem?) async {
        guard let item = item else { return }

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                await MainActor.run {
                    uploadResult = .failure("Could not load image data")
                }
                return
            }
            await uploadImageData(data)
        } catch {
            logger.error("Failed to load image: \(error.localizedDescription)")
            await MainActor.run {
                uploadResult = .failure(error.localizedDescription)
            }
        }
    }

    private func uploadImageData(_ data: Data) async {
        await MainActor.run {
            isUploading = true
            uploadResult = nil
        }

        do {
            // Convert to JPEG if needed for consistency
            let jpegData: Data
            if let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.8) {
                jpegData = jpeg
            } else {
                jpegData = data
            }

            let key = try await s3Service.uploadToDump(imageData: jpegData)
            logger.info("Uploaded to \(key)")

            await MainActor.run {
                isUploading = false
                uploadResult = .success(key)
                selectedItem = nil
            }
        } catch {
            logger.error("Upload failed: \(error.localizedDescription)")
            await MainActor.run {
                isUploading = false
                uploadResult = .failure(error.localizedDescription)
            }
        }
    }
}

#Preview {
    DropUploadView(s3Service: S3Service(config: S3Config.default))
}

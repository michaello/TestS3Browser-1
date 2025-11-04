import SwiftUI

struct FileDetailView: View {
    let object: S3Object
    let service: S3Service

    @State private var fileContent: FileContent?
    @State private var isLoading = false
    @State private var error: String?

    enum FileContent {
        case text(String)
        case image(UIImage)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // metadata section
                VStack(alignment: .leading, spacing: 8) {
                    Text("File Details")
                        .font(.headline)

                    MetadataRow(label: "Name", value: object.fileName)
                    MetadataRow(label: "Size", value: object.formattedSize)
                    MetadataRow(label: "Modified", value: object.lastModified.relativeFormatted())

                    if let url = service.getPublicURL(for: object.key) {
                        Link("Open in Browser", destination: url)
                            .font(.caption)
                    }
                }
                .padding()
                .background(.gray.opacity(0.1))
                .cornerRadius(12)

                // content display
                if isLoading {
                    HStack {
                        ProgressView()
                        Text("Loading...")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                } else if let error = error {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                } else if let content = fileContent {
                    switch content {
                    case .text(let text):
                        TextContentView(text: text)
                    case .image(let image):
                        ImageContentView(image: image)
                    }
                }
            }
            .padding()
        }
        .navigationTitle(object.fileName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadFile()
        }
    }

    private func loadFile() async {
        isLoading = true
        error = nil

        do {
            // Check cache first for images
            if object.fileType == .image {
                if let cachedImage = await ImageCacheActor.shared.getFullImage(for: object.key) {
                    await MainActor.run {
                        fileContent = .image(cachedImage)
                        isLoading = false
                    }
                    return
                }
            }

            let data = try await service.downloadObject(key: object.key)

            switch object.fileType {
            case .log, .text:
                if let text = String(data: data, encoding: .utf8) {
                    fileContent = .text(text)
                } else {
                    error = "Unable to decode text content"
                }
            case .image:
                // Cache the image for future use (both full and thumbnail)
                if let image = await ImageCacheActor.shared.cacheImage(from: data, for: object.key) {
                    fileContent = .image(image)
                } else {
                    error = "Unable to decode image"
                }
            case .unknown:
                if let text = String(data: data, encoding: .utf8) {
                    fileContent = .text(text)
                } else {
                    error = "Unsupported file type"
                }
            }
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }
}

struct TextContentView: View {
    let text: String
    @State private var showLineNumbers = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Content")
                    .font(.headline)

                Spacer()

                Toggle("Line #", isOn: $showLineNumbers)
                    .labelsHidden()
            }

            if showLineNumbers {
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(text.split(separator: "\n").enumerated()), id: \.offset) { index, line in
                            HStack(alignment: .top, spacing: 12) {
                                Text("\(index + 1)")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 40, alignment: .trailing)

                                Text(String(line))
                                    .font(.system(.caption, design: .monospaced))
                            }
                        }
                    }
                    .padding(12)
                }
                .background(.black.opacity(0.05))
                .cornerRadius(8)
            } else {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.05))
                    .cornerRadius(8)
            }
        }
    }
}

struct ImageContentView: View {
    let image: UIImage
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var isFullScreen = false

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Image")
                    .font(.headline)

                Spacer()

                Button {
                    isFullScreen = true
                } label: {
                    Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }

            ZStack {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                scale = max(1.0, min(value, 5.0))
                            }
                    )
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                if scale > 1.0 {
                                    offset = CGSize(
                                        width: lastOffset.width + value.translation.width,
                                        height: lastOffset.height + value.translation.height
                                    )
                                }
                            }
                            .onEnded { _ in
                                lastOffset = offset
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation {
                            if scale > 1.0 {
                                scale = 1.0
                                offset = .zero
                                lastOffset = .zero
                            } else {
                                scale = 2.0
                            }
                        }
                    }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 300)
            .background(.gray.opacity(0.1))
            .cornerRadius(8)

            HStack {
                if scale > 1.0 {
                    Button("Reset") {
                        withAnimation {
                            scale = 1.0
                            offset = .zero
                            lastOffset = .zero
                        }
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                Text("Pinch to zoom • Double tap to zoom • Drag to pan")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Dimensions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(Int(image.size.width)) × \(Int(image.size.height))")
                        .font(.caption)
                        .fontWeight(.medium)
                }

                Divider()
                    .frame(height: 30)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Scale")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.0f%%", image.scale * 100))
                        .font(.caption)
                        .fontWeight(.medium)
                }

                Spacer()
            }
            .padding(.top, 8)
        }
        .fullScreenCover(isPresented: $isFullScreen) {
            FullScreenImageView(image: image, isPresented: $isFullScreen)
        }
    }
}

struct FullScreenImageView: View {
    let image: UIImage
    @Binding var isPresented: Bool
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            scale = max(1.0, min(value, 5.0))
                        }
                )
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if scale > 1.0 {
                                offset = CGSize(
                                    width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height
                                )
                            }
                        }
                        .onEnded { _ in
                            lastOffset = offset
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation {
                        if scale > 1.0 {
                            scale = 1.0
                            offset = .zero
                            lastOffset = .zero
                        } else {
                            scale = 2.0
                        }
                    }
                }

            VStack {
                HStack {
                    Spacer()
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.white)
                            .shadow(radius: 10)
                    }
                    .padding()
                }
                Spacer()
            }
        }
    }
}

struct MetadataRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            Text(value)
                .font(.subheadline)
                .lineLimit(2)
        }
    }
}

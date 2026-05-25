import SwiftUI
import os.log

/// Full-screen image gallery with swipe navigation between images
/// Shows thumbnail initially during loading, then displays full image when loaded
struct ImageGalleryView: View {
    let images: [S3Object]
    let initialIndex: Int
    let s3Service: S3Service

    @State private var currentIndex: Int
    @State private var loadedImages: [String: UIImage] = [:]
    @State private var isLoading: [String: Bool] = [:]
    @State private var dragOffset: CGFloat = 0
    @State private var isDraggingVertically = false
    @Environment(\.dismiss) private var dismiss

    private let logger = Logger(subsystem: "com.s3browser", category: "ImageGalleryView")

    init(images: [S3Object], initialIndex: Int, s3Service: S3Service) {
        self.images = images
        self.initialIndex = initialIndex
        self.s3Service = s3Service
        self._currentIndex = State(initialValue: initialIndex)
    }

    var body: some View {
        ZStack {
            TabView(selection: $currentIndex) {
                ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                    ImagePageView(
                        object: image,
                        s3Service: s3Service,
                        loadedImage: loadedImages[image.key],
                        isLoading: isLoading[image.key] ?? false,
                        onImageLoaded: { loadedImage in
                            loadedImages[image.key] = loadedImage
                        },
                        onLoadingChanged: { loading in
                            isLoading[image.key] = loading
                        }
                    )
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .offset(y: dragOffset)
            .scaleEffect(1.0 - min(abs(dragOffset) / 1000.0, 0.15))
        }
        .background(Color.black.opacity(1.0 - min(abs(dragOffset) / 400.0, 0.5)))
        .ignoresSafeArea()
        .simultaneousGesture(
            DragGesture(minimumDistance: 50)
                .onChanged { value in
                    let verticalAmount = abs(value.translation.height)
                    let horizontalAmount = abs(value.translation.width)

                    // Only activate for clearly vertical drags (3x ratio)
                    // and only allow downward drag (positive height)
                    if !isDraggingVertically && verticalAmount > horizontalAmount * 3.0 && value.translation.height > 50 {
                        isDraggingVertically = true
                    }

                    if isDraggingVertically {
                        // Only track downward movement
                        dragOffset = max(0, value.translation.height)
                    }
                }
                .onEnded { value in
                    if isDraggingVertically && dragOffset > 150 {
                        dismiss()
                    } else {
                        withAnimation(.spring(response: 0.3)) {
                            dragOffset = 0
                        }
                    }
                    isDraggingVertically = false
                }
        )
        .navigationTitle(images.isEmpty ? "" : images[currentIndex].fileName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !images.isEmpty {
                    Text("\(currentIndex + 1) / \(images.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: currentIndex) { _, newIndex in
            // Preload adjacent images
            preloadAdjacentImages(around: newIndex)
        }
        .task {
            preloadAdjacentImages(around: currentIndex)
        }
    }

    /// Preloads images adjacent to the current index for smoother swiping
    private func preloadAdjacentImages(around index: Int) {
        let indicesToPreload = [index - 1, index, index + 1].filter { $0 >= 0 && $0 < images.count }

        for i in indicesToPreload {
            let image = images[i]
            guard loadedImages[image.key] == nil, isLoading[image.key] != true else { continue }

            Task {
                await preloadImage(for: image)
            }
        }
    }

    /// Preloads a single image into the cache
    private func preloadImage(for object: S3Object) async {
        // Check if already cached
        if let cached = await ImageCacheActor.shared.getFullImage(for: object.key) {
            await MainActor.run {
                loadedImages[object.key] = cached
            }
            return
        }

        await MainActor.run {
            isLoading[object.key] = true
        }

        do {
            let data = try await s3Service.downloadObject(key: object.key)
            if let image = await ImageCacheActor.shared.cacheImage(from: data, for: object.key) {
                await MainActor.run {
                    loadedImages[object.key] = image
                    isLoading[object.key] = false
                }
            }
        } catch {
            logger.error("Failed to preload image \(object.key): \(error.localizedDescription)")
            await MainActor.run {
                isLoading[object.key] = false
            }
        }
    }
}

/// Individual page in the image gallery showing a single image
struct ImagePageView: View {
    let object: S3Object
    let s3Service: S3Service
    let loadedImage: UIImage?
    let isLoading: Bool
    let onImageLoaded: (UIImage) -> Void
    let onLoadingChanged: (Bool) -> Void

    @State private var thumbnail: UIImage?
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private let logger = Logger(subsystem: "com.s3browser", category: "ImagePageView")

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black

                Group {
                    if let fullImage = loadedImage {
                        // Full image loaded
                        zoomableImage(fullImage)
                    } else if let thumb = thumbnail {
                        // Show thumbnail while loading full image
                        ZStack {
                            Image(uiImage: thumb)
                                .resizable()
                                .scaledToFit()
                                .blur(radius: 2)

                            ProgressView()
                                .scaleEffect(1.5)
                                .tint(.white)
                        }
                    } else {
                        // No image yet, show placeholder
                        VStack(spacing: 16) {
                            Image(systemName: "photo")
                                .font(.system(size: 60))
                                .foregroundStyle(.gray)

                            if isLoading {
                                ProgressView()
                                    .tint(.white)
                            }
                        }
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .task {
            await loadImages()
        }
    }

    /// Creates a zoomable image view that doesn't interfere with TabView swiping
    @ViewBuilder
    private func zoomableImage(_ image: UIImage) -> some View {
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
                    .onEnded { _ in
                        if scale < 1.0 {
                            withAnimation {
                                scale = 1.0
                            }
                        }
                    }
            )
            .highPriorityGesture(
                scale > 1.0 ?
                DragGesture()
                    .onChanged { value in
                        offset = CGSize(
                            width: lastOffset.width + value.translation.width,
                            height: lastOffset.height + value.translation.height
                        )
                    }
                    .onEnded { _ in
                        lastOffset = offset
                    }
                : nil
            )
            .onTapGesture(count: 2) {
                withAnimation {
                    if scale > 1.0 {
                        resetZoom()
                    } else {
                        scale = 2.0
                    }
                }
            }
    }

    private func resetZoom() {
        scale = 1.0
        offset = .zero
        lastOffset = .zero
    }

    private func loadImages() async {
        // Load thumbnail first (from cache)
        if let cachedThumb = await ImageCacheActor.shared.getThumbnail(for: object.key) {
            await MainActor.run {
                thumbnail = cachedThumb
            }
        }

        // Check if full image is already cached
        if let cachedFull = await ImageCacheActor.shared.getFullImage(for: object.key) {
            onImageLoaded(cachedFull)
            return
        }

        // Load full image if not already loading
        guard !isLoading else { return }

        onLoadingChanged(true)

        do {
            let data = try await s3Service.downloadObject(key: object.key)
            if let image = await ImageCacheActor.shared.cacheImage(from: data, for: object.key) {
                onImageLoaded(image)
            }
        } catch {
            logger.error("Failed to load image \(object.key): \(error.localizedDescription)")
        }

        onLoadingChanged(false)
    }
}

#Preview {
    NavigationStack {
        ImageGalleryView(
            images: [],
            initialIndex: 0,
            s3Service: S3Service(config: S3Config.default)
        )
    }
}

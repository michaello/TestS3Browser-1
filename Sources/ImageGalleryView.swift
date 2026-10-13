import SwiftUI
import os.log

/// Full-screen image gallery with swipe navigation between images
/// Shows thumbnail initially during loading, then displays full image when loaded
struct ImageGalleryView: View {
    let images: [S3Object]
    let initialIndex: Int
    let s3Service: S3Service

    @State private var currentIndex: Int
    @State private var presentationAccount: String
    @State private var workingSet = GalleryWorkingSet<UIImage>()
    @State private var projection = GalleryIdentityProjection<S3Object, MediaObjectIdentity>()
    @State private var dragOffset: CGFloat = 0
    @State private var isDraggingVertically = false
    @Environment(\.dismiss) private var dismiss

    private let logger = Logger(subsystem: "com.s3browser", category: "ImageGalleryView")

    init(images: [S3Object], initialIndex: Int, s3Service: S3Service) {
        self.images = images
        self.initialIndex = initialIndex
        self.s3Service = s3Service
        self._currentIndex = State(initialValue: max(0, min(initialIndex, images.count - 1)))
        self._presentationAccount = State(initialValue: s3Service.session.configuration.account)
    }

    var body: some View {
        AuditTelemetry.shared.measureViewConstruction(.gallery) { measuredContent }
    }

    private var measuredContent: some View {
        ZStack {
            TabView(selection: $currentIndex) {
                ForEach(images.indices, id: \.self) { index in
                    let image = images[index]
                    let identity = projection.identities.indices.contains(index) ? projection.identities[index] : s3Service.mediaIdentity(for: image)
                    ImagePageView(
                        object: image,
                        s3Service: s3Service,
                        loadedImage: workingSet.values[identity],
                        isLoading: workingSet.loading.contains(identity),
                        errorMessage: workingSet.errors[identity]
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
        .navigationTitle(images.indices.contains(currentIndex) ? images[currentIndex].fileName : "")
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
        .onChange(of: currentIndex) { _, _ in updateWorkingSet() }
        .onChange(of: images) { _, _ in projection.update(images, identity: { s3Service.mediaIdentity(for: $0) });updateWorkingSet() }
        .task { projection.update(images, identity: { s3Service.mediaIdentity(for: $0) });updateWorkingSet() }
        .onDisappear { workingSet.clear() }
        .onChange(of: s3Service.session.configuration.account) { _, _ in workingSet.clear(); dismiss() }
    }

    private func updateWorkingSet() {
        guard presentationAccount == s3Service.session.configuration.account else { workingSet.clear(); return }
        let generation = s3Service.session.generation
        let mapped = projection.objects
        workingSet.select(projection.identities, index: currentIndex) { identity in
            guard let object = mapped[identity], s3Service.session.isCurrent(generation),
                  let image = await ImageCacheActor.shared.loadDisplayImage(for: object, using: s3Service),
                  s3Service.session.isCurrent(generation), let cgImage = image.cgImage else {
                throw MediaTransferError.missingBody
            }
            return GalleryImageValue(value: image, bytes: cgImage.bytesPerRow * cgImage.height)
        }
    }
}

/// Individual page in the image gallery showing a single image
struct ImagePageView: View {
    let object: S3Object
    let s3Service: S3Service
    let loadedImage: UIImage?
    let isLoading: Bool
    let errorMessage: String?

    @State private var thumbnail: UIImage?
    @State private var zoom = MediaZoomState()

    private let logger = Logger(subsystem: "com.s3browser", category: "ImagePageView")

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black

                Group {
                    if let fullImage = loadedImage {
                        // Full image loaded
                        ZoomableMediaImage(image: fullImage, zoom: $zoom)
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

                            if isLoading { ProgressView().tint(.white) }
                            if let errorMessage { Text(errorMessage).foregroundStyle(.secondary).font(.caption) }
                        }
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .task(id: s3Service.mediaIdentity(for: object).digest) {
            resetZoom()
            thumbnail = nil
            let generation = s3Service.session.generation
            let cached = await ImageCacheActor.shared.getThumbnail(for: s3Service.mediaIdentity(for: object))
            guard !Task.isCancelled, s3Service.session.isCurrent(generation) else { return }
            thumbnail = cached
        }
    }

    private func resetZoom() { zoom.reset() }


}


/// Shared interaction for gallery, inline and fullscreen image presentations.
struct ZoomableMediaImage: View {
    let image: UIImage
    @Binding var zoom: MediaZoomState
    var body: some View {
        GeometryReader { geometry in
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: geometry.size.width, height: geometry.size.height)
                .scaleEffect(zoom.scale)
                .offset(zoom.offset)
                .gesture(MagnificationGesture()
                    .onChanged { zoom.magnify($0, image: image.size, viewport: geometry.size) }
                    .onEnded { _ in zoom.endMagnification(image: image.size, viewport: geometry.size) })
                .highPriorityGesture(zoom.scale > 1 ? DragGesture()
                    .onChanged { zoom.pan($0.translation, image: image.size, viewport: geometry.size) }
                    .onEnded { _ in zoom.endPan() } : nil)
                .onTapGesture(count: 2) {
                    withAnimation { zoom.doubleTap(image: image.size, viewport: geometry.size) }
                }
                .onChange(of: geometry.size) { _, size in zoom.clamp(image: image.size, viewport: size) }
                .onChange(of: ObjectIdentifier(image)) { _, _ in zoom.reset() }
        }
        .clipped()
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

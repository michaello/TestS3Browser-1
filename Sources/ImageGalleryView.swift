import SwiftUI
import UIKit
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
    @State private var zoomedPage: Int?
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
                        errorMessage: workingSet.errors[identity],
                        isActive: index == currentIndex,
                        onZoomChanged: { updateZoomOwnership($0, for: index) }
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
                    guard zoomedPage == nil else { return }
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
                    guard zoomedPage == nil else { return }
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
        .onChange(of: currentIndex) { _, _ in zoomedPage = nil; updateWorkingSet() }
        .onChange(of: images) { _, _ in projection.update(images, identity: { s3Service.mediaIdentity(for: $0) });updateWorkingSet() }
        .task { projection.update(images, identity: { s3Service.mediaIdentity(for: $0) });updateWorkingSet() }
        .onDisappear { workingSet.clear() }
        .onChange(of: s3Service.session.configuration.account) { _, _ in workingSet.clear(); dismiss() }
    }

    private func updateZoomOwnership(_ isZoomed: Bool, for index: Int) {
        if isZoomed, index == currentIndex {
            zoomedPage = index
            dragOffset = 0
            isDraggingVertically = false
        } else if zoomedPage == index {
            zoomedPage = nil
        }
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
    var isActive = true
    var onZoomChanged: (Bool) -> Void = { _ in }

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
                        ZoomableMediaImage(image: fullImage, zoom: $zoom, onZoomChanged: onZoomChanged)
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
        .onChange(of: isActive) { _, active in if !active { resetZoom() } }
    }

    private func resetZoom() { zoom.reset() }


}


/// Shared interaction for gallery, inline and fullscreen image presentations.
struct ZoomableMediaImage: View {
    let image: UIImage
    @Binding var zoom: MediaZoomState
    var onZoomChanged: (Bool) -> Void = { _ in }

    var body: some View {
        NativeZoomableMediaImage(image: image, zoom: $zoom, onZoomChanged: onZoomChanged)
            .onAppear { onZoomChanged(zoom.scale > 1.001) }
            .onDisappear { onZoomChanged(false) }
            .onChange(of: ObjectIdentifier(image)) { _, _ in zoom.reset(); onZoomChanged(false) }
            .onChange(of: zoom.scale) { _, scale in onZoomChanged(scale > 1.001) }
    }
}

private struct NativeZoomableMediaImage: UIViewRepresentable {
    let image: UIImage
    @Binding var zoom: MediaZoomState
    let onZoomChanged: (Bool) -> Void

    func makeUIView(context: Context) -> MediaImageScrollView { MediaImageScrollView() }

    func updateUIView(_ view: MediaImageScrollView, context: Context) {
        view.onZoomStateChange = { zoom = $0 }
        view.onZoomChanged = onZoomChanged
        view.update(image: image, state: zoom, animated: context.transaction.animation != nil)
    }

    static func dismantleUIView(_ view: MediaImageScrollView, coordinator: ()) {
        view.onZoomStateChange = nil
        view.onZoomChanged = nil
    }
}

/// UIKit owns touch tracking and deceleration. SwiftUI receives only settled state,
/// so a finger movement or momentum frame never rebuilds the image presentation.
@MainActor
final class MediaImageScrollView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    var onZoomStateChange: ((MediaZoomState) -> Void)?
    var onZoomChanged: ((Bool) -> Void)?

    private var viewport = CGSize.zero
    private var reportedState = MediaZoomState()
    private var updatingLayout = false
    private var capturesPan = false

    init() {
        super.init(frame: .zero)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 5
        decelerationRate = .normal
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        scrollsToTop = false
        delaysContentTouches = false
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = "Image"
        accessibilityIdentifier = "media.zoom"
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // At 1x our pan fails immediately, allowing gallery paging or parent scrolling.
        // Above 1x the image owns the drag, including at its edges.
        var ancestor = superview
        while let view = ancestor {
            if let scroll = view as? UIScrollView {
                scroll.panGestureRecognizer.require(toFail: panGestureRecognizer)
            }
            ancestor = view.superview
        }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer, zoomScale <= minimumZoomScale + 0.001, !isZooming {
            return false
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    func update(image: UIImage, state: MediaZoomState, animated: Bool) {
        if imageView.image !== image {
            imageView.image = image
            reportedState = state
            capturesPan = state.scale > minimumZoomScale + 0.001
            viewport = .zero
            setNeedsLayout()
        } else if state != reportedState {
            reportedState = state
            updatingLayout = true
            setZoomScale(state.scale, animated: animated && !UIAccessibility.isReduceMotionEnabled)
            if !animated || UIAccessibility.isReduceMotionEnabled {
                centerImage()
                restoreOffset(state.offset)
            }
            updatingLayout = false
            capturesPan = state.scale > minimumZoomScale + 0.001
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = bounds.size
        guard size != viewport, size.width > 0, size.height > 0,
              let image = imageView.image, image.size.width > 0, image.size.height > 0 else { return }
        // Keep the point at the center visible when the viewport rotates or resizes.
        let firstLayout = viewport == .zero
        let center = firstLayout ? CGPoint(x: 0.5, y: 0.5) : CGPoint(
            x: (contentOffset.x + viewport.width / 2) / max(contentSize.width, 1),
            y: (contentOffset.y + viewport.height / 2) / max(contentSize.height, 1)
        )
        let scale = firstLayout ? reportedState.scale : zoomScale
        updatingLayout = true
        viewport = size
        setZoomScale(1, animated: false)
        let fit = min(size.width / image.size.width, size.height / image.size.height)
        imageView.frame = CGRect(origin: .zero, size: CGSize(width: image.size.width * fit, height: image.size.height * fit))
        contentSize = imageView.bounds.size
        setZoomScale(scale, animated: false)
        centerImage()
        if firstLayout {
            restoreOffset(reportedState.offset)
        } else {
            setContentOffset(boundedOffset(CGPoint(x: center.x * contentSize.width - size.width / 2,
                                                  y: center.y * contentSize.height - size.height / 2)), animated: false)
        }
        capturesPan = zoomScale > minimumZoomScale + 0.001
        updatingLayout = false
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) { capturePan(true) }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        guard !updatingLayout else { return }
        publishSettledState()
        capturePan(zoomScale > minimumZoomScale + 0.001)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { publishSettledState() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { publishSettledState() }

    @objc private func toggleZoom(_ tap: UITapGestureRecognizer) {
        toggleZoom(at: tap.location(in: imageView), animated: !UIAccessibility.isReduceMotionEnabled)
    }

    func toggleZoom(at point: CGPoint, animated: Bool) {
        capturePan(true)
        if zoomScale > minimumZoomScale + 0.001 {
            setZoomScale(minimumZoomScale, animated: animated)
        } else {
            let size = CGSize(width: bounds.width / 2, height: bounds.height / 2)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                            width: size.width, height: size.height), animated: animated)
        }
        if !animated {
            publishSettledState()
            capturePan(zoomScale > minimumZoomScale + 0.001)
        }
    }

    private func centerImage() {
        let horizontal = max(0, (bounds.width - contentSize.width) / 2)
        let vertical = max(0, (bounds.height - contentSize.height) / 2)
        let inset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        if contentInset != inset { contentInset = inset }
    }

    private func boundedOffset(_ offset: CGPoint) -> CGPoint {
        CGPoint(x: min(max(-contentInset.left, contentSize.width - bounds.width + contentInset.right), max(-contentInset.left, offset.x)),
                y: min(max(-contentInset.top, contentSize.height - bounds.height + contentInset.bottom), max(-contentInset.top, offset.y)))
    }

    private func restoreOffset(_ offset: CGSize) {
        let center = CGPoint(x: (contentSize.width - bounds.width) / 2, y: (contentSize.height - bounds.height) / 2)
        setContentOffset(boundedOffset(CGPoint(x: center.x - offset.width, y: center.y - offset.height)), animated: false)
    }

    private func publishSettledState() {
        guard !updatingLayout, let image = imageView.image else { return }
        var state = MediaZoomState()
        state.settle(scale: zoomScale, offset: CGSize(width: (contentSize.width - bounds.width) / 2 - contentOffset.x,
                                                    height: (contentSize.height - bounds.height) / 2 - contentOffset.y),
                     image: image.size, viewport: bounds.size)
        reportedState = state
        imageView.accessibilityValue = "\(Int(state.scale * 100))% zoom"
        onZoomStateChange?(state)
    }

    private func capturePan(_ captured: Bool) {
        guard !updatingLayout, capturesPan != captured else { return }
        capturesPan = captured
        onZoomChanged?(captured)
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

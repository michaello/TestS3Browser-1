import CoreGraphics

/// Magnification is relative to one gesture. The settled scale carries between gestures;
/// pan is bounded by the aspect-fitted image's actual scaled overflow.
struct MediaZoomState: Equatable {
    private(set) var scale: CGFloat = 1
    private(set) var offset: CGSize = .zero
    private var settledScale: CGFloat = 1
    private var settledOffset: CGSize = .zero

    mutating func magnify(_ relative: CGFloat, image: CGSize, viewport: CGSize) {
        guard relative.isFinite else { return }
        scale = min(5, max(1, settledScale * relative))
        clamp(image: image, viewport: viewport)
    }
    mutating func endMagnification(image: CGSize, viewport: CGSize) {
        settledScale = scale
        clamp(image: image, viewport: viewport)
        settledOffset = offset
    }
    mutating func pan(_ translation: CGSize, image: CGSize, viewport: CGSize) {
        guard translation.width.isFinite, translation.height.isFinite else { return }
        offset = CGSize(width: settledOffset.width + translation.width, height: settledOffset.height + translation.height)
        clamp(image: image, viewport: viewport)
    }
    mutating func endPan() { settledOffset = offset }
    mutating func doubleTap(image: CGSize, viewport: CGSize) {
        if scale > 1 { reset() }
        else { scale = 2; settledScale = 2; clamp(image: image, viewport: viewport) }
    }
    mutating func reset() { scale = 1; settledScale = 1; offset = .zero; settledOffset = .zero }
    mutating func clamp(image: CGSize, viewport: CGSize) {
        guard scale > 1, image.width > 0, image.height > 0, viewport.width > 0, viewport.height > 0,
              image.width.isFinite, image.height.isFinite, viewport.width.isFinite, viewport.height.isFinite else {
            offset = .zero; settledOffset = .zero; return
        }
        let fit = min(viewport.width / image.width, viewport.height / image.height)
        let horizontal = max(0, (image.width * fit * scale - viewport.width) / 2)
        let vertical = max(0, (image.height * fit * scale - viewport.height) / 2)
        offset.width = min(horizontal, max(-horizontal, offset.width))
        offset.height = min(vertical, max(-vertical, offset.height))
        settledOffset.width = min(horizontal, max(-horizontal, settledOffset.width))
        settledOffset.height = min(vertical, max(-vertical, settledOffset.height))
    }
}

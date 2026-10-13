import CoreGraphics
import Testing
@testable import AuditCore

@Suite("N14 accumulated zoom and bounded image pan")
struct N14MediaZoomTests {
    let image = CGSize(width: 400, height: 400)
    let viewport = CGSize(width: 200, height: 200)

    @Test("Magnification accumulates between gestures and panned image returning to 1x recenters")
    func accumulatedAndRecenters() {
        var zoom = MediaZoomState()
        zoom.magnify(2, image: image, viewport: viewport)
        zoom.endMagnification(image: image, viewport: viewport)
        zoom.pan(CGSize(width: 80, height: 70), image: image, viewport: viewport); zoom.endPan()
        #expect(zoom.scale == 2)
        #expect(zoom.offset == CGSize(width: 80, height: 70))
        zoom.magnify(1.5, image: image, viewport: viewport)
        zoom.endMagnification(image: image, viewport: viewport)
        #expect(zoom.scale == 3)
        zoom.magnify(1 / 3, image: image, viewport: viewport)
        zoom.endMagnification(image: image, viewport: viewport)
        #expect(zoom.scale == 1)
        #expect(zoom.offset == .zero)
        zoom.pan(CGSize(width: 99, height: 99), image: image, viewport: viewport)
        #expect(zoom.offset == .zero)
        zoom.magnify(2, image: image, viewport: viewport)
        zoom.endMagnification(image: image, viewport: viewport)
        zoom.pan(CGSize(width: 10, height: 12), image: image, viewport: viewport)
        #expect(zoom.offset == CGSize(width: 10, height: 12))
    }

    @Test("Pan clamps to aspect-fitted scaled image bounds and recomputes on viewport resize")
    func aspectFittedBounds() {
        var zoom = MediaZoomState()
        let wide = CGSize(width: 800, height: 200)
        zoom.magnify(2, image: wide, viewport: viewport)
        zoom.endMagnification(image: wide, viewport: viewport)
        zoom.pan(CGSize(width: 1000, height: 1000), image: wide, viewport: viewport); zoom.endPan()
        #expect(zoom.offset == CGSize(width: 100, height: 0))
        zoom.clamp(image: wide, viewport: CGSize(width: 300, height: 100))
        #expect(zoom.offset == CGSize(width: 100, height: 0))
        zoom.pan(CGSize(width: -1000, height: -1000), image: wide, viewport: viewport)
        #expect(zoom.offset == CGSize(width: -100, height: 0))
        zoom.magnify(0.6, image: wide, viewport: viewport)
        #expect(abs(zoom.offset.width) <= 20.001)
    }

    @Test("Double tap, reset and invalid dimensions keep finite bounded interaction state")
    func resetAndInvalidInputs() {
        var zoom = MediaZoomState()
        zoom.doubleTap(image: image, viewport: viewport)
        #expect(zoom.scale == 2)
        zoom.doubleTap(image: image, viewport: viewport)
        #expect(zoom.scale == 1)
        zoom.magnify(100, image: image, viewport: viewport)
        #expect(zoom.scale == 5)
        zoom.magnify(.nan, image: image, viewport: viewport)
        #expect(zoom.scale == 5)
        zoom.pan(CGSize(width: 100, height: 100), image: image, viewport: .zero)
        #expect(zoom.offset == .zero)
        zoom.reset()
        #expect(zoom == MediaZoomState())
    }
}

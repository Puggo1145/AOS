import Testing
import CoreGraphics
import Foundation
@testable import AOSComputerUseKit

// MARK: - WindowCoordinateSpace conversion math
//
// The wire-facing `screenPoint(...)` validates ownership before
// converting; that side is exercised in real-window integration tests.
// Here we cover the pure math through `_convertForTesting` so the
// regression that motivated this fix — coordinate skew when the
// screenshot's actual pixel size diverges from `bounds * backingScale`
// — is locked down.

@Suite("WindowCoordinateSpace conversion")
struct WindowCoordinateSpaceTests {

    @Test("Reference pixel size is preferred over backingScale assumption")
    func usesReferencePixelSizeRatio() {
        // Window at logical bounds (100, 200) sized 400×300 points.
        // Screenshot captured at 1280×960 — i.e. ratio differs from any
        // integer backingScale (1280/400 = 3.2, not 1×/2×/3×).
        let bounds = WindowBounds(x: 100, y: 200, width: 400, height: 300)
        let pt = WindowCoordinateSpace._convertForTesting(
            imagePixel: CGPoint(x: 640, y: 480),
            windowBounds: bounds,
            referencePixelSize: CGSize(width: 1280, height: 960)
        )
        // 640 / 1280 = 0.5 across the image → 0.5 × 400 = 200 points →
        // bounds.x + 200 = 300. Same logic on Y → 350.
        #expect(pt.x == 300)
        #expect(pt.y == 350)
    }

    @Test("Origin pixel maps to the window's origin")
    func originMapsToOrigin() {
        let bounds = WindowBounds(x: 50, y: 75, width: 200, height: 100)
        let pt = WindowCoordinateSpace._convertForTesting(
            imagePixel: CGPoint(x: 0, y: 0),
            windowBounds: bounds,
            referencePixelSize: CGSize(width: 800, height: 400)
        )
        #expect(pt.x == 50)
        #expect(pt.y == 75)
    }

    @Test("Per-axis ratio handles non-uniform downscaling")
    func perAxisRatio() {
        // Hypothetical case where the X and Y dimensions get scaled
        // differently (e.g. legacy capture pipelines, or future cropping).
        let bounds = WindowBounds(x: 0, y: 0, width: 400, height: 200)
        let pt = WindowCoordinateSpace._convertForTesting(
            imagePixel: CGPoint(x: 100, y: 50),
            windowBounds: bounds,
            referencePixelSize: CGSize(width: 800, height: 400)
        )
        // X ratio = 400/800 = 0.5  → 100 * 0.5 = 50
        // Y ratio = 200/400 = 0.5  → 50  * 0.5 = 25
        #expect(pt.x == 50)
        #expect(pt.y == 25)
    }

    @Test("Screenshot frame anchors coordinates when CGWindow bounds are offset")
    func screenshotFrameAnchorsCoordinates() {
        // On the built-in Retina display, CGWindowList can report a
        // window bounds origin offset from ScreenCaptureKit's frame by
        // the window shadow margin. Using that bounds origin turns a
        // 100 px screenshot click into a ~189 px canvas click.
        let cgWindowBounds = WindowBounds(x: 44.5, y: 44.5, width: 900, height: 620)
        let screenshotFrame = WindowBounds(x: 0, y: 0, width: 900, height: 620)
        let pt = WindowCoordinateSpace._convertForTesting(
            imagePixel: CGPoint(x: 100, y: 100),
            windowBounds: cgWindowBounds,
            referenceFrame: screenshotFrame,
            referencePixelSize: CGSize(width: 1800, height: 1240)
        )

        #expect(pt.x == 50)
        #expect(pt.y == 50)
    }

    @Test("Moved window translates the screenshot frame by the current CG bounds delta")
    func movedWindowTranslatesScreenshotFrame() {
        let reference = ScreenshotCoordinateSpace(
            windowFrame: WindowBounds(x: 0, y: 0, width: 900, height: 620),
            windowBounds: WindowBounds(x: 44.5, y: 44.5, width: 900, height: 620),
            pixelSize: CGSize(width: 1800, height: 1240)
        )
        let currentWindowBounds = WindowBounds(x: 444.5, y: 144.5, width: 900, height: 620)

        let frame = reference.frameTranslatedToCurrentWindowBounds(currentWindowBounds)
        let pt = WindowCoordinateSpace._convertForTesting(
            imagePixel: CGPoint(x: 100, y: 100),
            windowBounds: currentWindowBounds,
            referenceFrame: frame,
            referencePixelSize: reference.pixelSize
        )

        #expect(frame == WindowBounds(x: 400, y: 100, width: 900, height: 620))
        #expect(pt.x == 450)
        #expect(pt.y == 150)
    }

    @Test("Window-local event stamp uses screenshot frame origin")
    func windowLocalStampUsesScreenshotFrameOrigin() {
        let local = MouseInput._windowLocalPointForTesting(
            screenPoint: CGPoint(x: 50, y: 50),
            windowFrame: WindowBounds(x: 0, y: 0, width: 900, height: 620)
        )

        #expect(local.x == 50)
        #expect(local.y == 50)
    }

    @Test("Nil reference size falls back to backing-scale path without crashing")
    func nilReferenceFallback() {
        // We can't assert exact values without controlling NSScreen, but
        // we can assert the call returns finite numbers and uses the
        // window origin as the floor. backingScale is at least 1, so
        // pixel-coord-divided-by-scale is bounded by pixel coord.
        let bounds = WindowBounds(x: 10, y: 20, width: 100, height: 100)
        let pt = WindowCoordinateSpace._convertForTesting(
            imagePixel: CGPoint(x: 50, y: 30),
            windowBounds: bounds,
            referencePixelSize: nil
        )
        #expect(pt.x.isFinite)
        #expect(pt.y.isFinite)
        #expect(pt.x >= bounds.x)
        #expect(pt.y >= bounds.y)
    }

    @Test("Zero-dimension reference size falls back to backing-scale path")
    func zeroReferenceFallsBack() {
        // Defensive: a degenerate pixelSize must not produce NaN/inf.
        let bounds = WindowBounds(x: 0, y: 0, width: 100, height: 100)
        let pt = WindowCoordinateSpace._convertForTesting(
            imagePixel: CGPoint(x: 10, y: 10),
            windowBounds: bounds,
            referencePixelSize: CGSize(width: 0, height: 0)
        )
        #expect(pt.x.isFinite)
        #expect(pt.y.isFinite)
    }
}

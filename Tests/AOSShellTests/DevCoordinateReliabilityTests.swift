import CoreGraphics
import Testing
import AOSComputerUseKit
@testable import AOSShell

@Suite("Dev coordinate reliability")
struct DevCoordinateReliabilityTests {
    @Test("coordinate script preserves ordered target grid points")
    func parseCoordinateScript() throws {
        let points = try DevCoordinateScript.parse(
            """
            12, 24
            36 48
            60,72
            """
        )

        #expect(points.map(\.x) == [12, 36, 60])
        #expect(points.map(\.y) == [24, 48, 72])
    }

    @Test("coordinate script rejects malformed lines")
    func parseCoordinateScriptRejectsMalformedLine() {
        #expect(throws: DevCoordinateScript.ParseError.self) {
            _ = try DevCoordinateScript.parse("10, 20, 30")
        }
    }

    @Test("comparison stays in target view-point space")
    func compareActualTargetPointInViewPointSpace() {
        let result = DevCoordinateReliabilityResult(
            index: 1,
            expected: CGPoint(x: 100, y: 50),
            actual: CGPoint(x: 51, y: 24),
            tolerancePixels: 3
        )

        #expect(result.actual == CGPoint(x: 51, y: 24))
        #expect(result.delta == CGSize(width: -49, height: -26))
        #expect(result.distance > 3)
        #expect(!result.passed)
    }

    @Test("comparison passes when target records the requested grid point")
    func comparePassesInViewPointSpace() {
        let result = DevCoordinateReliabilityResult(
            index: 1,
            expected: CGPoint(x: 100, y: 50),
            actual: CGPoint(x: 101, y: 49),
            tolerancePixels: 3
        )

        #expect(result.actual == CGPoint(x: 101, y: 49))
        #expect(result.delta == CGSize(width: 1, height: -1))
        #expect(result.distance < 3)
        #expect(result.passed)
    }

    @Test("target grid point converts to screenshot pixel using actual capture dimensions")
    func targetPointUsesActualCaptureDimensions() {
        let coordinateSpace = ScreenshotCoordinateSpace(
            windowFrame: WindowBounds(x: 0, y: 0, width: 900, height: 620),
            pixelSize: CGSize(width: 900, height: 620)
        )

        let point = DevCoordinateReliabilityInput.screenshotPixel(
            fromTargetPoint: CGPoint(x: 80, y: 80),
            coordinateSpace: coordinateSpace
        )

        #expect(point == CGPoint(x: 80, y: 80))
    }

    @Test("target grid point converts to Retina screenshot pixel when capture is doubled")
    func targetPointUsesRetinaCaptureDimensions() {
        let coordinateSpace = ScreenshotCoordinateSpace(
            windowFrame: WindowBounds(x: 0, y: 0, width: 900, height: 620),
            pixelSize: CGSize(width: 1800, height: 1240)
        )

        let point = DevCoordinateReliabilityInput.screenshotPixel(
            fromTargetPoint: CGPoint(x: 80, y: 80),
            coordinateSpace: coordinateSpace
        )

        #expect(point == CGPoint(x: 160, y: 160))
    }

    @Test("target reserves the top strip for window dragging")
    func targetReservesTopStripForWindowDragging() {
        #expect(DevCoordinateReliabilityLayout.isDragRegion(CGPoint(x: 80, y: 12)))
        #expect(!DevCoordinateReliabilityLayout.isDragRegion(CGPoint(x: 80, y: 48)))
    }

    @Test("target does not record drag sequences that start in the drag strip")
    func targetDoesNotRecordDragSequencesThatStartInDragStrip() {
        #expect(!DevCoordinateReliabilityLayout.shouldRecordCoordinateEvent(
            point: CGPoint(x: 80, y: 48),
            isWindowDragSequence: true
        ))
        #expect(DevCoordinateReliabilityLayout.shouldRecordCoordinateEvent(
            point: CGPoint(x: 80, y: 48),
            isWindowDragSequence: false
        ))
    }
}

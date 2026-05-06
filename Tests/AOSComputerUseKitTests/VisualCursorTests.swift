import CoreGraphics
import Testing
@testable import AOSComputerUseKit

@Suite("Visual cursor")
struct VisualCursorTests {
    @Test("software cursor hides one second after interaction")
    func softwareCursorIdleTimeout() {
        #expect(visualCursorPostInteractionIdleTimeout() == 1)
    }

    @Test("software cursor clamp keeps the cursor panel inside visible frame")
    func softwareCursorClampKeepsPanelInsideVisibleFrame() {
        let visibleFrame = CGRect(x: 100, y: 200, width: 640, height: 480)
        let geometry = CursorWindowGeometry(
            windowSize: CGSize(width: 32, height: 32),
            tipAnchor: CGPoint(x: 8, y: 24)
        )

        let clampedLowerLeft = visualCursorClampedTipPosition(
            CGPoint(x: visibleFrame.minX, y: visibleFrame.minY),
            visibleFrame: visibleFrame,
            geometry: geometry
        )
        let lowerLeftPanelFrame = CGRect(
            origin: geometry.origin(forTipPosition: clampedLowerLeft),
            size: geometry.windowSize
        )

        let clampedUpperRight = visualCursorClampedTipPosition(
            CGPoint(x: visibleFrame.maxX, y: visibleFrame.maxY),
            visibleFrame: visibleFrame,
            geometry: geometry
        )
        let upperRightPanelFrame = CGRect(
            origin: geometry.origin(forTipPosition: clampedUpperRight),
            size: geometry.windowSize
        )

        #expect(visibleFrame.contains(lowerLeftPanelFrame))
        #expect(visibleFrame.contains(upperRightPanelFrame))
    }

}

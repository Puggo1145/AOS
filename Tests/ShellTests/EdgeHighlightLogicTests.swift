import Testing
import Foundation
import CoreGraphics
@testable import Shell

// MARK: - EdgeHighlightLogicTests
//
// Pure helper tests for the radial-highlight active/inactive decision and the
// global→local point projection. The actual SwiftUI Canvas rendering is not
// covered here — we only exercise the math.

@Suite("Edge highlight hit-test math")
struct EdgeHighlightLogicTests {

    private let deviceNotchRect = CGRect(x: 600, y: 870, width: 200, height: 30)
    private let leaveSlack: CGFloat = 28
    private let interiorBand: CGFloat = 8

    @Test("mouse skimming the notch edge → active")
    func mouseSkimmingNotchEdgeActivates() {
        let mouse = CGPoint(x: 700, y: 899)
        let result = EdgeHighlightOverlay.computeHighlight(
            globalMouse: mouse,
            deviceNotchRect: deviceNotchRect,
            leaveSlack: leaveSlack,
            interiorBand: interiorBand
        )
        #expect(result.active)
    }

    @Test("mouse far outside hot zone → inactive")
    func mouseFarOutsideDeactivates() {
        let mouse = CGPoint(x: 100, y: 200)
        let result = EdgeHighlightOverlay.computeHighlight(
            globalMouse: mouse,
            deviceNotchRect: deviceNotchRect,
            leaveSlack: leaveSlack,
            interiorBand: interiorBand
        )
        #expect(!result.active)
    }

    @Test("mouse just outside slack boundary → inactive")
    func slackBoundaryIsExclusive() {
        let closedBar = NotchViewModel.makeClosedBarRect(deviceNotchRect: deviceNotchRect)
        let mouse = CGPoint(x: closedBar.maxX + leaveSlack + 1, y: closedBar.midY)
        let result = EdgeHighlightOverlay.computeHighlight(
            globalMouse: mouse,
            deviceNotchRect: deviceNotchRect,
            leaveSlack: leaveSlack,
            interiorBand: interiorBand
        )
        #expect(!result.active)
    }

    @Test("mouse deep inside the bar interior → inactive")
    func mouseInsideInteriorBandDeactivates() {
        let mouse = CGPoint(x: 700, y: 885)
        let result = EdgeHighlightOverlay.computeHighlight(
            globalMouse: mouse,
            deviceNotchRect: deviceNotchRect,
            leaveSlack: leaveSlack,
            interiorBand: interiorBand
        )
        #expect(!result.active)
    }

    @Test("local point is projected into the closed bar silhouette")
    func localPointUsesClosedBarCoordinates() {
        let closedBar = NotchViewModel.makeClosedBarRect(deviceNotchRect: deviceNotchRect)
        let mouse = CGPoint(x: 700, y: 899)
        let result = EdgeHighlightOverlay.computeHighlight(
            globalMouse: mouse,
            deviceNotchRect: deviceNotchRect,
            leaveSlack: leaveSlack,
            interiorBand: interiorBand
        )
        #expect(result.localPoint.x == mouse.x - closedBar.minX)
        #expect(result.localPoint.y == closedBar.maxY - mouse.y)
        #expect(result.localPoint.x >= 0)
        #expect(result.localPoint.x <= closedBar.width)
        #expect(result.localPoint.y >= 0)
        #expect(result.localPoint.y <= closedBar.height)
    }
}

import CoreGraphics
import Testing
@testable import Shell

@Suite("Notch placement geometry")
struct NotchPlacementGeometryTests {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let notch = CGRect(x: 620, y: 868, width: 200, height: 32)
    private let panel = CGSize(width: 500, height: 300)

    @Test("release inside top notch zone attaches to top")
    func releaseInsideTopNotchZoneAttachesTop() {
        let placement = NotchPlacementGeometry.placementOnRelease(
            screenRect: screen,
            deviceNotchRect: notch,
            panelSize: panel,
            pointer: CGPoint(x: notch.midX, y: screen.maxY - 4),
            dragOffset: CGPoint(x: 250, y: 20)
        )
        #expect(placement == .attachedTop)
    }

    @Test("release near top edge away from device notch attaches to top")
    func releaseNearTopEdgeAwayFromDeviceNotchAttachesTop() {
        let placement = NotchPlacementGeometry.placementOnRelease(
            screenRect: screen,
            deviceNotchRect: notch,
            panelSize: panel,
            pointer: CGPoint(x: 120, y: screen.maxY - 4),
            dragOffset: CGPoint(x: 250, y: 20)
        )
        #expect(placement == .attachedTop)
    }

    @Test("release exactly on top edge away from device notch attaches to top")
    func releaseExactlyOnTopEdgeAwayFromDeviceNotchAttachesTop() {
        let placement = NotchPlacementGeometry.placementOnRelease(
            screenRect: screen,
            deviceNotchRect: notch,
            panelSize: panel,
            pointer: CGPoint(x: 120, y: screen.maxY),
            dragOffset: CGPoint(x: 250, y: 20)
        )
        #expect(placement == .attachedTop)
    }

    @Test("release with panel touching top attaches even when pointer is below top zone")
    func releaseWithPanelTouchingTopAttachesEvenWhenPointerIsBelowTopZone() {
        let placement = NotchPlacementGeometry.placementOnRelease(
            screenRect: screen,
            deviceNotchRect: notch,
            panelSize: panel,
            pointer: CGPoint(x: 120, y: screen.maxY - 100),
            dragOffset: CGPoint(x: 250, y: panel.height - 100)
        )
        #expect(placement == .attachedTop)
    }

    @Test("release near top without panel touching top stays detached")
    func releaseNearTopWithoutPanelTouchingTopStaysDetached() {
        let frame = CGRect(x: 200, y: 552, width: panel.width, height: panel.height)
        let placement = NotchPlacementGeometry.placementOnRelease(
            screenRect: screen,
            deviceNotchRect: notch,
            panelFrame: frame
        )
        #expect(placement == .detached(frame))
    }

    @Test("release near left edge docks outside left edge")
    func releaseNearLeftEdgeDocksOutsideLeftEdge() {
        let placement = NotchPlacementGeometry.placementOnRelease(
            screenRect: screen,
            deviceNotchRect: notch,
            panelSize: panel,
            pointer: CGPoint(x: 8, y: 450),
            dragOffset: CGPoint(x: 250, y: 20)
        )
        guard case let .edgeDock(edge, hiddenFrame, revealFrame, triggerFrame, revealed) = placement else {
            Issue.record("Expected edge dock")
            return
        }
        #expect(edge == .left)
        #expect(revealed == false)
        #expect(hiddenFrame.maxX == screen.minX)
        #expect(revealFrame.minX == screen.minX)
        #expect(revealFrame.height == panel.height)
        #expect(triggerFrame.minX == screen.minX)
        #expect(triggerFrame.width == NotchPlacementGeometry.defaultEdgeTriggerThickness)
        #expect(triggerFrame.height == screen.height)
    }

    @Test("release docks by panel frame touching left edge even when pointer is away from edge")
    func releaseDocksByPanelFrameTouchingLeftEdgeEvenWhenPointerIsAwayFromEdge() {
        let placement = NotchPlacementGeometry.placementOnRelease(
            screenRect: screen,
            deviceNotchRect: notch,
            panelSize: panel,
            pointer: CGPoint(x: 250, y: 800),
            dragOffset: CGPoint(x: 250, y: 400)
        )
        guard case let .edgeDock(edge, hiddenFrame, revealFrame, _, false) = placement else {
            Issue.record("Expected edge dock")
            return
        }
        #expect(edge == .left)
        #expect(hiddenFrame.maxX == screen.minX)
        #expect(revealFrame.origin == CGPoint(x: screen.minX, y: 400))
    }

    @Test("release stays detached when pointer is near edge but panel frame is not touching edge")
    func releaseStaysDetachedWhenPointerIsNearEdgeButPanelFrameIsNotTouchingEdge() {
        let placement = NotchPlacementGeometry.placementOnRelease(
            screenRect: screen,
            deviceNotchRect: notch,
            panelSize: panel,
            pointer: CGPoint(x: 8, y: 450),
            dragOffset: CGPoint(x: -100, y: 50)
        )
        #expect(placement == .detached(CGRect(x: 108, y: 400, width: 500, height: 300)))
    }

    @Test("release near left without panel touching edge stays detached")
    func releaseNearLeftWithoutPanelTouchingEdgeStaysDetached() {
        let frame = CGRect(x: 8, y: 300, width: panel.width, height: panel.height)
        let placement = NotchPlacementGeometry.placementOnRelease(
            screenRect: screen,
            deviceNotchRect: notch,
            panelFrame: frame
        )
        #expect(placement == .detached(frame))
    }

    @Test("release near right without panel touching edge stays detached")
    func releaseNearRightWithoutPanelTouchingEdgeStaysDetached() {
        let frame = CGRect(x: screen.maxX - panel.width - 8, y: 300, width: panel.width, height: panel.height)
        let placement = NotchPlacementGeometry.placementOnRelease(
            screenRect: screen,
            deviceNotchRect: notch,
            panelFrame: frame
        )
        #expect(placement == .detached(frame))
    }

    @Test("release near bottom without panel touching edge stays detached")
    func releaseNearBottomWithoutPanelTouchingEdgeStaysDetached() {
        let frame = CGRect(x: 200, y: 8, width: panel.width, height: panel.height)
        let placement = NotchPlacementGeometry.placementOnRelease(
            screenRect: screen,
            deviceNotchRect: notch,
            panelFrame: frame
        )
        #expect(placement == .detached(frame))
    }

    @Test("release away from edges creates clamped detached frame")
    func releaseAwayFromEdgesCreatesDetachedFrame() {
        let placement = NotchPlacementGeometry.placementOnRelease(
            screenRect: screen,
            deviceNotchRect: notch,
            panelSize: panel,
            pointer: CGPoint(x: 300, y: 300),
            dragOffset: CGPoint(x: 100, y: 50)
        )
        #expect(placement == .detached(CGRect(x: 200, y: 250, width: 500, height: 300)))
    }

    @Test("detached frame helper clamps inside screen")
    func detachedFrameHelperClampsInsideScreen() {
        let frame = NotchPlacementGeometry.detachedFrame(
            screenRect: screen,
            panelSize: panel,
            pointer: CGPoint(x: 1200, y: 150),
            dragOffset: CGPoint(x: 10, y: 280)
        )
        #expect(frame == CGRect(x: 940, y: 0, width: 500, height: 300))
    }

    @Test("resizing a detached frame preserves its top edge")
    func resizingDetachedFramePreservesTopEdge() {
        let frame = CGRect(x: 200, y: 320, width: 500, height: 180)

        let resized = NotchPlacementGeometry.resizedDetachedFrame(
            screenRect: screen,
            currentFrame: frame,
            targetSize: CGSize(width: 500, height: 260)
        )

        #expect(resized.minX == frame.minX)
        #expect(resized.maxY == frame.maxY)
        #expect(resized.size == CGSize(width: 500, height: 260))
    }

    @Test("resizing a detached frame preserves touched right edge but still anchors vertically to top")
    func resizingDetachedFramePreservesTouchedRightEdgeButStillAnchorsVerticallyToTop() {
        let right = CGRect(x: screen.maxX - 500, y: 320, width: 500, height: 180)
        let resizedRight = NotchPlacementGeometry.resizedDetachedFrame(
            screenRect: screen,
            currentFrame: right,
            targetSize: CGSize(width: 420, height: 260)
        )

        #expect(resizedRight.maxX == screen.maxX)
        #expect(resizedRight.maxY == right.maxY)
        #expect(resizedRight.size == CGSize(width: 420, height: 260))

        let bottom = CGRect(x: 200, y: screen.minY, width: 500, height: 260)
        let resizedBottom = NotchPlacementGeometry.resizedDetachedFrame(
            screenRect: screen,
            currentFrame: bottom,
            targetSize: CGSize(width: 500, height: 180)
        )

        #expect(resizedBottom.minX == bottom.minX)
        #expect(resizedBottom.maxY == bottom.maxY)
        #expect(resizedBottom.minY > screen.minY)
        #expect(resizedBottom.size == CGSize(width: 500, height: 180))
    }

    @Test("resizing a bottom edge dock preserves the docked bottom edge")
    func resizingBottomEdgeDockPreservesDockedBottomEdge() {
        let placement = NotchPlacement.edgeDock(
            edge: .bottom,
            hiddenFrame: CGRect(x: 200, y: -180, width: 500, height: 180),
            revealFrame: CGRect(x: 200, y: screen.minY, width: 500, height: 180),
            triggerFrame: CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: 8),
            revealed: true
        )

        let resized = NotchPlacementGeometry.resizedFloatingPlacement(
            placement,
            screenRect: screen,
            targetSize: CGSize(width: 500, height: 260)
        )

        guard case let .edgeDock(edge, hiddenFrame, revealFrame, _, revealed) = resized else {
            Issue.record("Expected resized edge dock")
            return
        }
        #expect(edge == .bottom)
        #expect(revealed)
        #expect(revealFrame.minY == screen.minY)
        #expect(revealFrame.size == CGSize(width: 500, height: 260))
        #expect(hiddenFrame.maxY == screen.minY)
    }

    @Test("release with clamped frame touching right edge docks outside right edge")
    func releaseWithClampedFrameTouchingRightEdgeDocksOutsideRightEdge() {
        let placement = NotchPlacementGeometry.placementOnRelease(
            screenRect: screen,
            deviceNotchRect: notch,
            panelSize: panel,
            pointer: CGPoint(x: 1200, y: 150),
            dragOffset: CGPoint(x: 10, y: 280)
        )
        guard case let .edgeDock(edge, hiddenFrame, revealFrame, _, false) = placement else {
            Issue.record("Expected edge dock")
            return
        }
        #expect(edge == .right)
        #expect(revealFrame == CGRect(x: 940, y: 0, width: 500, height: 300))
        #expect(hiddenFrame.minX == screen.maxX)
    }

    @Test("corner tie prefers side edge")
    func cornerTiePrefersSideEdge() {
        let edge = NotchPlacementGeometry.nearestEdge(
            screenRect: screen,
            pointer: CGPoint(x: 8, y: 8),
            threshold: 16
        )
        #expect(edge == .left)
    }

    @Test("active rect follows placement")
    func activeRectFollowsPlacement() {
        let detached = NotchPlacement.detached(CGRect(x: 100, y: 100, width: 500, height: 300))
        #expect(NotchPlacementGeometry.mouseActiveRect(for: detached) == CGRect(x: 100, y: 100, width: 500, height: 300))

        let edge = NotchPlacement.edgeDock(
            edge: .right,
            hiddenFrame: CGRect(x: 1440, y: 300, width: 500, height: 300),
            revealFrame: CGRect(x: 940, y: 300, width: 500, height: 300),
            triggerFrame: CGRect(x: 1432, y: 0, width: 8, height: 900),
            revealed: false
        )
        #expect(NotchPlacementGeometry.mouseActiveRect(for: edge) == CGRect(x: 1432, y: 0, width: 8, height: 900))
    }

    @Test("revealed edge placement uses reveal frame for active rect")
    func revealedEdgePlacementUsesRevealFrameForActiveRect() {
        let placement = NotchPlacement.edgeDock(
            edge: .left,
            hiddenFrame: CGRect(x: -500, y: 300, width: 500, height: 300),
            revealFrame: CGRect(x: 0, y: 300, width: 500, height: 300),
            triggerFrame: CGRect(x: 0, y: 0, width: 8, height: 900),
            revealed: true
        )
        #expect(NotchPlacementGeometry.mouseActiveRect(for: placement) == CGRect(x: 0, y: 300, width: 500, height: 300))
    }
}

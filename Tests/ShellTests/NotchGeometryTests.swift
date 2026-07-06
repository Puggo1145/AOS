import Testing
import Foundation
import CoreGraphics
@testable import Shell

// MARK: - NotchGeometryTests
//
// Pure geometry math from NotchViewModel — no NSWindow / NSScreen access.
// Synthetic screen frame and device-notch rect drive the static helpers.

@Suite("Notch geometry derivations")
struct NotchGeometryTests {

    /// Synthetic 1440×900 retina-ish display with a 200×32 notch.
    private let screenRect = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let deviceNotchRect = CGRect(x: 620, y: 868, width: 200, height: 32)
    private let panel = CGSize(width: 720, height: 240)

    @Test("notchOpenedRect is centred horizontally on the screen")
    func openedRectIsCentred() {
        let rect = NotchGeometryModel.makeNotchOpenedRect(screenRect: screenRect, panel: panel)
        #expect(rect.midX == screenRect.midX)
        #expect(rect.width == panel.width)
        #expect(rect.height == panel.height)
        // Top-aligned: panel hangs from screenRect.maxY downward.
        #expect(rect.maxY == screenRect.maxY)
        #expect(rect.minY == screenRect.maxY - panel.height)
    }

    @Test("headlineOpenedRect aligns with device notch height")
    func headlineRectMatchesDeviceNotch() {
        let rect = NotchGeometryModel.makeHeadlineOpenedRect(
            screenRect: screenRect,
            panel: panel,
            deviceNotchHeight: deviceNotchRect.height
        )
        #expect(rect.height == deviceNotchRect.height)
        #expect(rect.width == panel.width)
        #expect(rect.maxY == screenRect.maxY)
    }

    @Test("closedBarRect spans device notch + two h×h satellite squares")
    func closedBarSpansSatellites() {
        let rect = NotchGeometryModel.makeClosedBarRect(deviceNotchRect: deviceNotchRect)
        #expect(rect.height == deviceNotchRect.height)
        #expect(rect.width == deviceNotchRect.width + deviceNotchRect.height * 2)
        #expect(rect.minX == deviceNotchRect.minX - deviceNotchRect.height)
        #expect(rect.midX == deviceNotchRect.midX)
    }

    @Test("device notch rect uses the system-reported auxiliary gap")
    func deviceNotchRectUsesAuxiliaryGap() {
        let rect = NotchWindowController.makeDeviceNotchRect(
            screenFrame: screenRect,
            notchHeight: 32,
            auxiliaryTopLeftWidth: 663,
            auxiliaryTopRightWidth: 664
        )
        #expect(rect.minX == 663)
        #expect(rect.maxX == 776)
        #expect(rect.midX == 719.5)
        #expect(rect.minY == 868)
    }

    @Test("notch center is converted into top strip local coordinates")
    func notchCenterUsesTopStripLocalCoordinates() {
        let offsetScreen = CGRect(x: -1512, y: 0, width: 1512, height: 982)
        let deviceNotch = CGRect(x: -849, y: 950, width: 185, height: 32)

        let center = NotchWindowController.makeNotchCenterXInWindow(
            screenFrame: offsetScreen,
            deviceNotchRect: deviceNotch
        )

        #expect(center == deviceNotch.midX - offsetScreen.minX)
    }

    @Test("openedRect width matches panel even on narrow screens")
    func openedRectIgnoresScreenWidth() {
        let narrow = CGRect(x: 0, y: 0, width: 800, height: 600)
        let rect = NotchGeometryModel.makeNotchOpenedRect(screenRect: narrow, panel: panel)
        #expect(rect.width == panel.width)
        #expect(rect.midX == narrow.midX)
    }

    // MARK: - Tray size policy
    //
    // `notchTraySize` is a wrapper over `makeTraySize`; service reads only
    // produce the inputs (noticeCount, expanded). These cases lock the
    // collapsed-vs-expanded clamping so a regression in tray sizing fails
    // here, not after a 480pt visual surprise in the running app.

    private let trayCollapsed: CGFloat = 42
    private let trayMax: CGFloat = 240
    private let trayWidth: CGFloat = 500

    @Test("tray height is zero when there are no notices")
    func trayHeightZeroWhenEmpty() {
        let s = NotchGeometryModel.makeTraySize(
            width: trayWidth, itemCount: 0, expanded: false,
            measuredContentHeight: 999, // ignored
            collapsedHeight: trayCollapsed, maxHeight: trayMax
        )
        #expect(s == CGSize(width: trayWidth, height: 0))
    }

    @Test("single-notice tray uses measured content height clamped above collapsed floor")
    func singleNoticeUsesMeasuredHeightWithFloor() {
        // Floor: even if measurement undershoots (e.g. before the first
        // layout pass writes `trayContentHeight`), we never paint shorter
        // than one row's worth — otherwise the drawer pops in.
        let undershoot = NotchGeometryModel.makeTraySize(
            width: trayWidth, itemCount: 1, expanded: false,
            measuredContentHeight: 10,
            collapsedHeight: trayCollapsed, maxHeight: trayMax
        )
        #expect(undershoot.height == trayCollapsed)
        // Natural fit between floor and ceiling passes through.
        let natural = NotchGeometryModel.makeTraySize(
            width: trayWidth, itemCount: 1, expanded: false,
            measuredContentHeight: 80,
            collapsedHeight: trayCollapsed, maxHeight: trayMax
        )
        #expect(natural.height == 80)
    }

    @Test("tray content taller than max is clamped — inner ScrollView takes over")
    func contentTallerThanMaxIsClamped() {
        let s = NotchGeometryModel.makeTraySize(
            width: trayWidth, itemCount: 4, expanded: true,
            measuredContentHeight: 999,
            collapsedHeight: trayCollapsed, maxHeight: trayMax
        )
        #expect(s.height == trayMax)
    }

    @Test("multi-notice + collapsed pins to the one-row collapsed height")
    func multiCollapsedPinsToCollapsed() {
        // Even if the inner VStack measured tall (all rows are still
        // *in the layout* per the SystemTrayView animation contract),
        // the collapsed drawer must render exactly one row's worth.
        let s = NotchGeometryModel.makeTraySize(
            width: trayWidth, itemCount: 3, expanded: false,
            measuredContentHeight: 200,
            collapsedHeight: trayCollapsed, maxHeight: trayMax
        )
        #expect(s.height == trayCollapsed)
    }

    @Test("multi-notice + expanded uses measured height, clamped into [collapsed, max]")
    func multiExpandedUsesMeasured() {
        let s = NotchGeometryModel.makeTraySize(
            width: trayWidth, itemCount: 3, expanded: true,
            measuredContentHeight: 130,
            collapsedHeight: trayCollapsed, maxHeight: trayMax
        )
        #expect(s.height == 130)
    }

    // MARK: - Opened total rect

    @Test("openedTotalRect is centered horizontally and hangs from screen top")
    func openedTotalRectHangsFromTop() {
        let total = CGSize(width: 500, height: 320)
        let rect = NotchGeometryModel.makeOpenedTotalRect(screenRect: screenRect, totalSize: total)
        #expect(rect.midX == screenRect.midX)
        #expect(rect.maxY == screenRect.maxY)
        #expect(rect.minY == screenRect.maxY - total.height)
        #expect(rect.size == total)
    }

    @Test("openedTotalRect grows downward as the tray adds height")
    func openedTotalRectGrowsDownward() {
        let mainOnly = CGSize(width: 500, height: 240)
        let withTray = CGSize(width: 500, height: 240 + 80)
        let r1 = NotchGeometryModel.makeOpenedTotalRect(screenRect: screenRect, totalSize: mainOnly)
        let r2 = NotchGeometryModel.makeOpenedTotalRect(screenRect: screenRect, totalSize: withTray)
        #expect(r1.maxY == r2.maxY) // top-aligned to screen
        #expect(r2.minY < r1.minY)  // bottom edge dropped by tray height
        #expect(r2.height - r1.height == 80)
    }

    @Test("local notch-window clicks do not close when measured panel height is stale")
    func localNotchWindowClickDoesNotCloseWithStaleHeight() {
        let staleMeasuredRect = NotchGeometryModel.makeOpenedTotalRect(
            screenRect: screenRect,
            totalSize: CGSize(width: 500, height: 120)
        )
        let clickedSettingsRow = NSPoint(x: screenRect.midX, y: screenRect.maxY - 260)

        #expect(NotchViewModel.shouldCloseOpenedClick(
            point: clickedSettingsRow,
            isLocalNotchWindowEvent: true,
            openedTotalRect: staleMeasuredRect,
            deviceNotchRect: deviceNotchRect
        ) == false)
    }

    @Test("opened click-through gate uses max overlay budget while measured height is stale")
    func openedClickThroughGateUsesMaxOverlayBudgetWhileMeasuredHeightIsStale() {
        let staleMeasuredRect = NotchGeometryModel.makeOpenedTotalRect(
            screenRect: screenRect,
            totalSize: CGSize(width: 500, height: 120)
        )
        let staleVisible = NotchGeometryModel.makeOpenedVisibleRect(openedTotalRect: staleMeasuredRect)
        let mouseActive = NotchGeometryModel.makeOpenedMouseActiveRect(
            visibleRect: staleVisible,
            screenRect: screenRect,
            width: 500,
            maxHeight: 480 + 240,
            measurementPending: true
        )
        let clickedSettingsRow = NSPoint(x: screenRect.midX, y: screenRect.maxY - 260)

        #expect(staleVisible.contains(clickedSettingsRow) == false)
        #expect(NotchWindowController.shouldIgnoreMouseEvents(
            mouse: clickedSettingsRow,
            mouseActiveRect: mouseActive
        ) == false)
    }

    @Test("opened click-through gate ignores blank space after measurement lands")
    func openedClickThroughGateIgnoresBlankSpaceAfterMeasurementLands() {
        let visible = NotchGeometryModel.makeOpenedVisibleRect(openedTotalRect:
            NotchGeometryModel.makeOpenedTotalRect(
                screenRect: screenRect,
                totalSize: CGSize(width: 500, height: 120)
            )
        )
        let mouseActive = NotchGeometryModel.makeOpenedMouseActiveRect(
            visibleRect: visible,
            screenRect: screenRect,
            width: 500,
            maxHeight: 480 + 240,
            measurementPending: false
        )
        let blankBelowActualUI = NSPoint(x: screenRect.midX, y: screenRect.maxY - 260)

        #expect(visible.contains(blankBelowActualUI) == false)
        #expect(NotchWindowController.shouldIgnoreMouseEvents(
            mouse: blankBelowActualUI,
            mouseActiveRect: mouseActive
        ))
    }

    @Test("global outside clicks still close the opened notch")
    func globalOutsideClickClosesOpenedNotch() {
        let rect = NotchGeometryModel.makeOpenedTotalRect(
            screenRect: screenRect,
            totalSize: CGSize(width: 500, height: 240)
        )
        let outside = NSPoint(x: screenRect.midX, y: rect.minY - 1)

        #expect(NotchViewModel.shouldCloseOpenedClick(
            point: outside,
            isLocalNotchWindowEvent: false,
            openedTotalRect: rect,
            deviceNotchRect: deviceNotchRect
        ))
    }

    @Test("window frame for attached top uses existing top strip")
    func windowFrameForAttachedTopUsesTopStrip() {
        let result = NotchWindowController.windowFrame(
            for: .attachedTop,
            screenFrame: screenRect,
            topStripHeight: 720
        )
        #expect(result == NotchWindowController.makeTopStripRect(screenFrame: screenRect, panelHeight: 720))
    }

    @Test("window frame for detached placement is detached frame")
    func windowFrameForDetachedPlacementIsDetachedFrame() {
        let frame = CGRect(x: 100, y: 100, width: 500, height: 300)
        let result = NotchWindowController.windowFrame(
            for: .detached(frame),
            screenFrame: screenRect,
            topStripHeight: 720
        )
        #expect(result == frame)
    }

    @Test("window frame for hidden edge dock is outside screen")
    func windowFrameForHiddenEdgeDockIsOutsideScreen() {
        let hidden = CGRect(x: -500, y: 300, width: 500, height: 300)
        let reveal = CGRect(x: 0, y: 300, width: 500, height: 300)
        let trigger = CGRect(x: 0, y: 0, width: 8, height: 900)
        let result = NotchWindowController.windowFrame(
            for: .edgeDock(edge: .left, hiddenFrame: hidden, revealFrame: reveal, triggerFrame: trigger, revealed: false),
            screenFrame: screenRect,
            topStripHeight: 720
        )
        #expect(result == hidden)
    }

    @Test("window frame for revealed edge dock is reveal frame")
    func windowFrameForRevealedEdgeDockIsRevealFrame() {
        let hidden = CGRect(x: -500, y: 300, width: 500, height: 300)
        let reveal = CGRect(x: 0, y: 300, width: 500, height: 300)
        let trigger = CGRect(x: 0, y: 0, width: 8, height: 900)
        let result = NotchWindowController.windowFrame(
            for: .edgeDock(edge: .left, hiddenFrame: hidden, revealFrame: reveal, triggerFrame: trigger, revealed: true),
            screenFrame: screenRect,
            topStripHeight: 720
        )
        #expect(result == reveal)
    }

    @Test("edge dock reveal and collapse animate the window frame")
    func edgeDockRevealAndCollapseAnimateWindowFrame() {
        let hidden = CGRect(x: -500, y: 300, width: 500, height: 300)
        let reveal = CGRect(x: 0, y: 300, width: 500, height: 300)
        let trigger = CGRect(x: 0, y: 0, width: 8, height: 900)
        let hiddenDock = NotchPlacement.edgeDock(
            edge: .left,
            hiddenFrame: hidden,
            revealFrame: reveal,
            triggerFrame: trigger,
            revealed: false
        )
        let revealedDock = NotchPlacement.edgeDock(
            edge: .left,
            hiddenFrame: hidden,
            revealFrame: reveal,
            triggerFrame: trigger,
            revealed: true
        )

        #expect(NotchWindowController.shouldAnimateWindowFrame(from: hiddenDock, to: revealedDock))
        #expect(NotchWindowController.shouldAnimateWindowFrame(from: revealedDock, to: hiddenDock))
    }

    @Test("edge dock frame animation uses a longer nonlinear curve")
    func edgeDockFrameAnimationUsesLongerNonlinearCurve() {
        let spec = NotchWindowController.edgeDockFrameAnimation

        #expect(spec.duration == 0.32)
        #expect(spec.controlPoint1 == CGPoint(x: 0.16, y: 1.0))
        #expect(spec.controlPoint2 == CGPoint(x: 0.3, y: 1.0))
    }

    @Test("notch silhouette animates shoulders and detached top corners")
    func notchSilhouetteAnimatesShouldersAndDetachedTopCorners() {
        var shape = NotchSilhouetteShape(
            cornerRadius: 32,
            shoulderRadius: NotchGeometryModel.openedShoulderRadius,
            topCornerRadius: 0
        )

        shape.animatableData = .init(.init(18, 18), .init(.init(18, 18), 0))

        #expect(shape.cornerRadius == 18)
        #expect(shape.shoulderRadius == 0)
        #expect(shape.topCornerRadius == 18)
        #expect(shape.topLeadingRadius == 18)
        #expect(shape.topTrailingRadius == 18)
        #expect(shape.bottomLeadingRadius == 18)
        #expect(shape.bottomTrailingRadius == 18)
    }

    @Test("detach morph source preserves the opened content footprint")
    func detachMorphSourcePreservesOpenedContentFootprint() {
        let finalSize = CGSize(width: 500, height: 250)
        let source = DetachMorphPresentation.make(
            phase: .source,
            placement: .detached(CGRect(x: 200, y: 300, width: 500, height: 250)),
            screenRect: screenRect,
            finalSize: finalSize,
            sourceHeight: 240,
            sourceBottomCornerRadius: 32,
            targetCornerRadius: 18,
            targetTopPadding: 10
        )
        let target = DetachMorphPresentation.make(
            phase: .target,
            placement: .detached(CGRect(x: 200, y: 300, width: 500, height: 250)),
            screenRect: screenRect,
            finalSize: finalSize,
            sourceHeight: 240,
            sourceBottomCornerRadius: 32,
            targetCornerRadius: 18,
            targetTopPadding: 10
        )

        #expect(source.contentTopPadding == 0)
        #expect(source.contentClipCornerRadii.topLeading == 0)
        #expect(source.contentClipCornerRadii.bottomLeading == 32)
        #expect(source.chromeOverlayOpacity == 0)
        #expect(source.silhouetteSize.width == finalSize.width + 2 * NotchGeometryModel.openedShoulderRadius)
        #expect(source.silhouetteSize.height == 240)

        #expect(target.contentTopPadding == 10)
        #expect(target.contentClipCornerRadii.topLeading == 18)
        #expect(target.contentClipCornerRadii.bottomLeading == 18)
        #expect(target.chromeOverlayOpacity == 0)
        #expect(target.silhouetteSize == finalSize)
    }

    @Test("edge-docked floating panel flattens the two corners on the docked side")
    func edgeDockedFloatingPanelFlattensDockedSideCorners() {
        let finalSize = CGSize(width: 500, height: 250)
        let hiddenFrame = CGRect(x: -500, y: 300, width: 500, height: 250)
        let revealFrame = CGRect(x: 0, y: 300, width: 500, height: 250)
        let triggerFrame = CGRect(x: 0, y: 0, width: 8, height: 900)

        let left = DetachMorphPresentation.make(
            phase: .idle,
            placement: .edgeDock(
                edge: .left,
                hiddenFrame: hiddenFrame,
                revealFrame: revealFrame,
                triggerFrame: triggerFrame,
                revealed: false
            ),
            screenRect: screenRect,
            finalSize: finalSize,
            sourceHeight: 240,
            sourceBottomCornerRadius: 32,
            targetCornerRadius: 18,
            targetTopPadding: 10
        )

        #expect(left.shapeCornerRadii.topLeading == 0)
        #expect(left.shapeCornerRadii.bottomLeading == 0)
        #expect(left.shapeCornerRadii.topTrailing == 18)
        #expect(left.shapeCornerRadii.bottomTrailing == 18)
        #expect(left.contentClipCornerRadii == left.shapeCornerRadii)

        let right = DetachMorphPresentation.make(
            phase: .idle,
            placement: .edgeDock(
                edge: .right,
                hiddenFrame: hiddenFrame,
                revealFrame: revealFrame,
                triggerFrame: triggerFrame,
                revealed: false
            ),
            screenRect: screenRect,
            finalSize: finalSize,
            sourceHeight: 240,
            sourceBottomCornerRadius: 32,
            targetCornerRadius: 18,
            targetTopPadding: 10
        )

        #expect(right.shapeCornerRadii.topLeading == 18)
        #expect(right.shapeCornerRadii.bottomLeading == 18)
        #expect(right.shapeCornerRadii.topTrailing == 0)
        #expect(right.shapeCornerRadii.bottomTrailing == 0)
        #expect(right.contentClipCornerRadii == right.shapeCornerRadii)

        let bottom = DetachMorphPresentation.make(
            phase: .idle,
            placement: .edgeDock(
                edge: .bottom,
                hiddenFrame: hiddenFrame,
                revealFrame: revealFrame,
                triggerFrame: triggerFrame,
                revealed: false
            ),
            screenRect: screenRect,
            finalSize: finalSize,
            sourceHeight: 240,
            sourceBottomCornerRadius: 32,
            targetCornerRadius: 18,
            targetTopPadding: 10
        )

        #expect(bottom.shapeCornerRadii.topLeading == 18)
        #expect(bottom.shapeCornerRadii.topTrailing == 18)
        #expect(bottom.shapeCornerRadii.bottomLeading == 0)
        #expect(bottom.shapeCornerRadii.bottomTrailing == 0)
        #expect(bottom.contentClipCornerRadii == bottom.shapeCornerRadii)
    }

    @Test("detached floating panel flattens corners as soon as its frame touches a dock edge")
    func detachedFloatingPanelFlattensCornersOnEdgeContactBeforeRelease() {
        let finalSize = CGSize(width: 500, height: 250)

        let leftContact = DetachMorphPresentation.make(
            phase: .idle,
            placement: .detached(CGRect(x: screenRect.minX, y: 300, width: 500, height: 250)),
            screenRect: screenRect,
            finalSize: finalSize,
            sourceHeight: 240,
            sourceBottomCornerRadius: 32,
            targetCornerRadius: 18,
            targetTopPadding: 10
        )

        #expect(leftContact.shapeCornerRadii.topLeading == 0)
        #expect(leftContact.shapeCornerRadii.bottomLeading == 0)
        #expect(leftContact.shapeCornerRadii.topTrailing == 18)
        #expect(leftContact.shapeCornerRadii.bottomTrailing == 18)

        let rightContact = DetachMorphPresentation.make(
            phase: .idle,
            placement: .detached(CGRect(x: screenRect.maxX - 500, y: 300, width: 500, height: 250)),
            screenRect: screenRect,
            finalSize: finalSize,
            sourceHeight: 240,
            sourceBottomCornerRadius: 32,
            targetCornerRadius: 18,
            targetTopPadding: 10
        )

        #expect(rightContact.shapeCornerRadii.topLeading == 18)
        #expect(rightContact.shapeCornerRadii.bottomLeading == 18)
        #expect(rightContact.shapeCornerRadii.topTrailing == 0)
        #expect(rightContact.shapeCornerRadii.bottomTrailing == 0)

        let bottomContact = DetachMorphPresentation.make(
            phase: .idle,
            placement: .detached(CGRect(x: 200, y: screenRect.minY, width: 500, height: 250)),
            screenRect: screenRect,
            finalSize: finalSize,
            sourceHeight: 240,
            sourceBottomCornerRadius: 32,
            targetCornerRadius: 18,
            targetTopPadding: 10
        )

        #expect(bottomContact.shapeCornerRadii.topLeading == 18)
        #expect(bottomContact.shapeCornerRadii.topTrailing == 18)
        #expect(bottomContact.shapeCornerRadii.bottomLeading == 0)
        #expect(bottomContact.shapeCornerRadii.bottomTrailing == 0)
    }

    @Test("detached panel docking outside an edge animates the window frame")
    func detachedPanelDockingOutsideEdgeAnimatesWindowFrame() {
        let hiddenDock = NotchPlacement.edgeDock(
            edge: .left,
            hiddenFrame: CGRect(x: -500, y: 300, width: 500, height: 300),
            revealFrame: CGRect(x: 0, y: 300, width: 500, height: 300),
            triggerFrame: CGRect(x: 0, y: 0, width: 8, height: 900),
            revealed: false
        )

        #expect(NotchWindowController.shouldAnimateWindowFrame(
            from: .detached(CGRect(x: 20, y: 300, width: 500, height: 300)),
            to: hiddenDock
        ))
    }

    @Test("detached panel returning to the top notch animates the window frame")
    func detachedPanelReturningToTopNotchAnimatesWindowFrame() {
        #expect(NotchWindowController.shouldAnimateWindowFrame(
            from: .detached(CGRect(x: 420, y: 440, width: 500, height: 300)),
            to: .attachedTop
        ))
    }

    @Test("detached panel growth expands the window canvas without AppKit frame animation")
    func detachedPanelGrowthExpandsWindowCanvasWithoutAppKitFrameAnimation() {
        let plan = NotchWindowController.windowFrameUpdatePlan(
            from: .detached(CGRect(x: 240, y: 360, width: 500, height: 180)),
            to: .detached(CGRect(x: 240, y: 300, width: 500, height: 240)),
            screenFrame: screenRect,
            topStripHeight: 720
        )

        #expect(plan == .set(
            CGRect(x: 240, y: 300, width: 500, height: 240),
            animated: false
        ))
        #expect(NotchWindowController.shouldAnimateWindowFrame(
            from: .detached(CGRect(x: 240, y: 360, width: 500, height: 180)),
            to: .detached(CGRect(x: 240, y: 300, width: 500, height: 240))
        ) == false)
    }

    @Test("detached panel shrink waits for the SwiftUI height animation before shrinking the window canvas")
    func detachedPanelShrinkWaitsForSwiftUIHeightAnimationBeforeShrinkingWindowCanvas() {
        let plan = NotchWindowController.windowFrameUpdatePlan(
            from: .detached(CGRect(x: 240, y: 300, width: 500, height: 240)),
            to: .detached(CGRect(x: 240, y: 360, width: 500, height: 180)),
            screenFrame: screenRect,
            topStripHeight: 720
        )

        #expect(plan == .deferSet(
            CGRect(x: 240, y: 360, width: 500, height: 180),
            delay: NotchWindowController.detachedWindowShrinkDelay
        ))
    }

    @Test("repeated detached shrink notifications keep the pending window shrink")
    func repeatedDetachedShrinkNotificationsKeepThePendingWindowShrink() {
        let target = CGRect(x: 240, y: 360, width: 500, height: 180)
        let firstPlan = NotchWindowController.windowFrameUpdatePlan(
            from: .detached(CGRect(x: 240, y: 300, width: 500, height: 240)),
            to: .detached(target),
            screenFrame: screenRect,
            topStripHeight: 720
        )
        #expect(firstPlan == .deferSet(
            target,
            delay: NotchWindowController.detachedWindowShrinkDelay
        ))

        let repeatedPlan = NotchWindowController.windowFrameUpdatePlan(
            from: .detached(CGRect(x: 240, y: 300, width: 500, height: 240)),
            to: .detached(target),
            screenFrame: screenRect,
            topStripHeight: 720,
            pendingDeferredFrame: target
        )
        #expect(repeatedPlan == .keepDeferred(target))
    }

    @Test("detached drag after pending shrink applies the moved frame immediately")
    func detachedDragAfterPendingShrinkAppliesMovedFrameImmediately() {
        let pendingShrinkTarget = CGRect(x: 240, y: 360, width: 500, height: 180)
        let movedFrame = CGRect(x: 320, y: 330, width: 500, height: 180)

        let plan = NotchWindowController.windowFrameUpdatePlan(
            from: .detached(CGRect(x: 240, y: 300, width: 500, height: 240)),
            to: .detached(movedFrame),
            screenFrame: screenRect,
            topStripHeight: 720,
            pendingDeferredFrame: pendingShrinkTarget
        )

        #expect(plan == .set(movedFrame, animated: false))
    }

    @Test("detached panel drag movement does not animate the window frame")
    func detachedPanelDragMovementDoesNotAnimateWindowFrame() {
        #expect(NotchWindowController.shouldAnimateWindowFrame(
            from: .detached(CGRect(x: 240, y: 360, width: 500, height: 180)),
            to: .detached(CGRect(x: 280, y: 340, width: 500, height: 180))
        ) == false)
    }

    @Test("non edge-dock placement changes do not animate the window frame")
    func nonEdgeDockPlacementChangesDoNotAnimateWindowFrame() {
        let hidden = CGRect(x: -500, y: 300, width: 500, height: 300)
        let reveal = CGRect(x: 0, y: 300, width: 500, height: 300)
        let trigger = CGRect(x: 0, y: 0, width: 8, height: 900)
        let hiddenDock = NotchPlacement.edgeDock(
            edge: .left,
            hiddenFrame: hidden,
            revealFrame: reveal,
            triggerFrame: trigger,
            revealed: false
        )

        #expect(NotchWindowController.shouldAnimateWindowFrame(from: .attachedTop, to: hiddenDock) == false)
        #expect(NotchWindowController.shouldAnimateWindowFrame(from: hiddenDock, to: .attachedTop) == false)
    }

    @Test("local physical-notch re-click closes the opened notch")
    func localPhysicalNotchClickClosesOpenedNotch() {
        let rect = NotchGeometryModel.makeOpenedTotalRect(
            screenRect: screenRect,
            totalSize: CGSize(width: 500, height: 240)
        )

        #expect(NotchViewModel.shouldCloseOpenedClick(
            point: NSPoint(x: deviceNotchRect.midX, y: deviceNotchRect.midY),
            isLocalNotchWindowEvent: true,
            openedTotalRect: rect,
            deviceNotchRect: deviceNotchRect
        ))
    }

    // MARK: - Visible hit rects

    @Test("opened visible rect extends 18pt past the logical rect on each side")
    func openedVisibleRectIncludesShoulders() {
        let logical = CGRect(x: 100, y: 200, width: 500, height: 240)
        let visible = NotchGeometryModel.makeOpenedVisibleRect(openedTotalRect: logical)
        #expect(visible.minX == logical.minX - 18)
        #expect(visible.maxX == logical.maxX + 18)
        #expect(visible.minY == logical.minY)
        #expect(visible.maxY == logical.maxY)
        #expect(visible.width == logical.width + 36)
    }

    @Test("closed visible rect extends 6pt past the bar on each side")
    func closedVisibleRectIncludesShoulders() {
        let bar = NotchGeometryModel.makeClosedBarRect(deviceNotchRect: deviceNotchRect)
        let visible = NotchGeometryModel.makeClosedVisibleRect(closedBarRect: bar)
        #expect(visible.minX == bar.minX - 6)
        #expect(visible.maxX == bar.maxX + 6)
        #expect(visible.height == bar.height)
    }
}

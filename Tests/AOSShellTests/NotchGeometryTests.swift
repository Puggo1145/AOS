import Testing
import Foundation
import CoreGraphics
@testable import AOSShell

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
        let rect = NotchViewModel.makeNotchOpenedRect(screenRect: screenRect, panel: panel)
        #expect(rect.midX == screenRect.midX)
        #expect(rect.width == panel.width)
        #expect(rect.height == panel.height)
        // Top-aligned: panel hangs from screenRect.maxY downward.
        #expect(rect.maxY == screenRect.maxY)
        #expect(rect.minY == screenRect.maxY - panel.height)
    }

    @Test("headlineOpenedRect aligns with device notch height")
    func headlineRectMatchesDeviceNotch() {
        let rect = NotchViewModel.makeHeadlineOpenedRect(
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
        let rect = NotchViewModel.makeClosedBarRect(deviceNotchRect: deviceNotchRect)
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
        let rect = NotchViewModel.makeNotchOpenedRect(screenRect: narrow, panel: panel)
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
        let s = NotchViewModel.makeTraySize(
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
        let undershoot = NotchViewModel.makeTraySize(
            width: trayWidth, itemCount: 1, expanded: false,
            measuredContentHeight: 10,
            collapsedHeight: trayCollapsed, maxHeight: trayMax
        )
        #expect(undershoot.height == trayCollapsed)
        // Natural fit between floor and ceiling passes through.
        let natural = NotchViewModel.makeTraySize(
            width: trayWidth, itemCount: 1, expanded: false,
            measuredContentHeight: 80,
            collapsedHeight: trayCollapsed, maxHeight: trayMax
        )
        #expect(natural.height == 80)
    }

    @Test("tray content taller than max is clamped — inner ScrollView takes over")
    func contentTallerThanMaxIsClamped() {
        let s = NotchViewModel.makeTraySize(
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
        let s = NotchViewModel.makeTraySize(
            width: trayWidth, itemCount: 3, expanded: false,
            measuredContentHeight: 200,
            collapsedHeight: trayCollapsed, maxHeight: trayMax
        )
        #expect(s.height == trayCollapsed)
    }

    @Test("multi-notice + expanded uses measured height, clamped into [collapsed, max]")
    func multiExpandedUsesMeasured() {
        let s = NotchViewModel.makeTraySize(
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
        let rect = NotchViewModel.makeOpenedTotalRect(screenRect: screenRect, totalSize: total)
        #expect(rect.midX == screenRect.midX)
        #expect(rect.maxY == screenRect.maxY)
        #expect(rect.minY == screenRect.maxY - total.height)
        #expect(rect.size == total)
    }

    @Test("openedTotalRect grows downward as the tray adds height")
    func openedTotalRectGrowsDownward() {
        let mainOnly = CGSize(width: 500, height: 240)
        let withTray = CGSize(width: 500, height: 240 + 80)
        let r1 = NotchViewModel.makeOpenedTotalRect(screenRect: screenRect, totalSize: mainOnly)
        let r2 = NotchViewModel.makeOpenedTotalRect(screenRect: screenRect, totalSize: withTray)
        #expect(r1.maxY == r2.maxY) // top-aligned to screen
        #expect(r2.minY < r1.minY)  // bottom edge dropped by tray height
        #expect(r2.height - r1.height == 80)
    }

    // MARK: - Visible hit rects

    @Test("opened visible rect extends 18pt past the logical rect on each side")
    func openedVisibleRectIncludesShoulders() {
        let logical = CGRect(x: 100, y: 200, width: 500, height: 240)
        let visible = NotchViewModel.makeOpenedVisibleRect(openedTotalRect: logical)
        #expect(visible.minX == logical.minX - 18)
        #expect(visible.maxX == logical.maxX + 18)
        #expect(visible.minY == logical.minY)
        #expect(visible.maxY == logical.maxY)
        #expect(visible.width == logical.width + 36)
    }

    @Test("closed visible rect extends 6pt past the bar on each side")
    func closedVisibleRectIncludesShoulders() {
        let bar = NotchViewModel.makeClosedBarRect(deviceNotchRect: deviceNotchRect)
        let visible = NotchViewModel.makeClosedVisibleRect(closedBarRect: bar)
        #expect(visible.minX == bar.minX - 6)
        #expect(visible.maxX == bar.maxX + 6)
        #expect(visible.height == bar.height)
    }
}

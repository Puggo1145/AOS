import CoreGraphics

// MARK: - NotchGeometryModel
//
// Pure geometry policy for the notch shell. Keeping these helpers out of
// NotchViewModel lets layout tests exercise panel/tray/hit-rect math without
// constructing the service graph that drives the live UI.

public enum NotchGeometryModel {
    /// Shoulder radius the painted silhouette extends past the logical rect on
    /// each side. The hit rect must match the rendered bounding box, otherwise
    /// clicks landing on visible shoulder pixels fall outside the window's
    /// non-mouse-transparent area and pass through to the app below. The
    /// values must stay in sync with `NotchShape.shoulderRadius` (opened) and
    /// the closed-bar shoulder used by the closed-state silhouette.
    public static let openedShoulderRadius: CGFloat = 18
    public static let closedShoulderRadius: CGFloat = 6

    public static func makeNotchOpenedRect(screenRect: CGRect, panel: CGSize) -> CGRect {
        CGRect(
            x: screenRect.midX - panel.width / 2,
            y: screenRect.maxY - panel.height,
            width: panel.width,
            height: panel.height
        )
    }

    public static func makeHeadlineOpenedRect(
        screenRect: CGRect,
        panel: CGSize,
        deviceNotchHeight: CGFloat
    ) -> CGRect {
        CGRect(
            x: screenRect.midX - panel.width / 2,
            y: screenRect.maxY - deviceNotchHeight,
            width: panel.width,
            height: deviceNotchHeight
        )
    }

    /// Tray drawer height policy.
    ///   - Zero notices: height 0.
    ///   - Single notice or expanded: measured content clamped into
    ///     [collapsedHeight, maxHeight].
    ///   - Multi-notice + collapsed: fixed collapsedHeight.
    public static func makeTraySize(
        width: CGFloat,
        itemCount: Int,
        expanded: Bool,
        measuredContentHeight: CGFloat,
        collapsedHeight: CGFloat,
        maxHeight: CGFloat
    ) -> CGSize {
        guard itemCount > 0 else {
            return CGSize(width: width, height: 0)
        }
        if itemCount == 1 || expanded {
            let h = min(max(measuredContentHeight, collapsedHeight), maxHeight)
            return CGSize(width: width, height: h)
        }
        return CGSize(width: width, height: collapsedHeight)
    }

    public static func makeOpenedTotalRect(
        screenRect: CGRect,
        totalSize: CGSize
    ) -> CGRect {
        CGRect(
            x: screenRect.midX - totalSize.width / 2,
            y: screenRect.maxY - totalSize.height,
            width: totalSize.width,
            height: totalSize.height
        )
    }

    public static func makeOpenedVisibleRect(openedTotalRect: CGRect) -> CGRect {
        openedTotalRect.insetBy(dx: -openedShoulderRadius, dy: 0)
    }

    public static func makeClosedVisibleRect(closedBarRect: CGRect) -> CGRect {
        closedBarRect.insetBy(dx: -closedShoulderRadius, dy: 0)
    }

    public static func makeClosedBarRect(deviceNotchRect: CGRect) -> CGRect {
        CGRect(
            x: deviceNotchRect.minX - deviceNotchRect.height,
            y: deviceNotchRect.minY,
            width: deviceNotchRect.width + deviceNotchRect.height * 2,
            height: deviceNotchRect.height
        )
    }
}

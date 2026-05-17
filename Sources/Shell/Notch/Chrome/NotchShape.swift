import SwiftUI

// MARK: - NotchOutlineShape
//
// A pure SwiftUI `Shape` that traces just the outer silhouette path of the
// notch — used as a mask source by EdgeHighlightOverlay so the radial
// highlight appears only along the edge stroke. The full visual silhouette
// (with the destinationOut shoulder cutouts) is rendered by `NotchShape`
// below; this is the simpler matching outline for highlight masking.
struct NotchOutlineShape: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = min(cornerRadius, min(rect.width, rect.height) / 2)
        // Top-left corner (square at the top, since the menu bar continues)
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX - r, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - r),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        p.closeSubpath()
        return p
    }
}

// MARK: - NotchEdgeHighlightShape
//
// Open highlight path for the interactive white glow. It intentionally omits
// the top edge because the notch attaches to the menu bar there; only the
// left, bottom-center, and right visible edges should catch the glow.
struct NotchEdgeHighlightShape: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = min(cornerRadius, min(rect.width, rect.height) / 2)
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
        p.addQuadCurve(
            to: CGPoint(x: rect.minX + r, y: rect.maxY),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY - r),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return p
    }
}


// MARK: - NotchSilhouetteShape
//
// Single Path-based silhouette covering the entire notch outline: two
// inverse-curve shoulders at the top corners, vertical sides, and the
// rounded bottom. The shape's local rect is the FULL bounding box —
// including the shoulders' outward extension — so the path's `minX/maxX`
// are at the far edges of the shoulders and the "main rect" lives at
// `[minX + shoulderRadius, maxX - shoulderRadius]`.
//
// Replaces the previous `Rectangle + clipShape + destinationOut shoulder
// overlays` approach. That approach used `compositingGroup()` which the
// renderer caches as a rasterised intermediate; during a springy open
// animation the shoulder cache could lag the main-rect frame interpolation
// (visible as the right shoulder briefly detaching), and during macOS
// Spaces transitions the OS could capture the cached intermediate at a
// different moment than the surrounding fill (visible as a flat-edged
// rectangle peeking past the shoulder curve). One Path → no caching →
// no sub-layer divergence.

struct NotchSilhouetteShape: Shape {
    /// Bottom corner radius of the silhouette.
    var cornerRadius: CGFloat
    /// Inverse-curve shoulder radius. The shape extends `shoulderRadius`
    /// past the main rect on each horizontal side; `path(in:)` interprets
    /// the input rect as already including this extension.
    var shoulderRadius: CGFloat

    /// Expose the radii to SwiftUI's animation system. Without this, the
    /// default `EmptyAnimatableData` makes corner/shoulder radii snap on
    /// status changes — `.frame` interpolates the size, but `path(in:)`
    /// runs once with the new radii, producing the visible "size morphs
    /// smoothly while the corners jump to the destination value first"
    /// glitch on open / close.
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(cornerRadius, shoulderRadius) }
        set {
            cornerRadius = newValue.first
            shoulderRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let halfHeight = max(rect.height / 2, 0)
        let halfMainWidth = max((rect.width - 2 * shoulderRadius) / 2, 0)
        let r = max(min(cornerRadius, min(halfHeight, halfMainWidth)), 0)
        let sh = max(min(shoulderRadius, halfHeight), 0)
        let mainMinX = rect.minX + sh
        let mainMaxX = rect.maxX - sh
        let topY = rect.minY
        let bottomY = rect.maxY

        // Far top-left of the left shoulder (attaches to the menu bar).
        p.move(to: CGPoint(x: rect.minX, y: topY))
        // Top edge across the entire silhouette.
        p.addLine(to: CGPoint(x: rect.maxX, y: topY))
        // Right shoulder inverse curve into the main rect.
        p.addQuadCurve(
            to: CGPoint(x: mainMaxX, y: topY + sh),
            control: CGPoint(x: mainMaxX, y: topY)
        )
        // Down the main rect's right edge.
        p.addLine(to: CGPoint(x: mainMaxX, y: bottomY - r))
        // Bottom-right rounded corner.
        p.addQuadCurve(
            to: CGPoint(x: mainMaxX - r, y: bottomY),
            control: CGPoint(x: mainMaxX, y: bottomY)
        )
        // Across the bottom edge.
        p.addLine(to: CGPoint(x: mainMinX + r, y: bottomY))
        // Bottom-left rounded corner.
        p.addQuadCurve(
            to: CGPoint(x: mainMinX, y: bottomY - r),
            control: CGPoint(x: mainMinX, y: bottomY)
        )
        // Up the main rect's left edge.
        p.addLine(to: CGPoint(x: mainMinX, y: topY + sh))
        // Left shoulder inverse curve out to the far top-left.
        p.addQuadCurve(
            to: CGPoint(x: rect.minX, y: topY),
            control: CGPoint(x: mainMinX, y: topY)
        )
        p.closeSubpath()
        return p
    }
}

// MARK: - NotchShape
//
// View wrapper that picks size + radii from the `status` and feeds them to
// `NotchSilhouetteShape`. SwiftUI's `.animation(_:value:status)` interpolates
// the underlying CGFloats and the Shape recomputes the path each frame, so
// the closed → popping → opened transitions read as one continuous jelly.

struct NotchShape: View {
    let status: NotchViewModel.Status
    let deviceNotchRect: CGRect
    let panelSize: CGSize

    /// Visual silhouette in closed/popping state must wrap the entire
    /// ClosedBar (icon + middle + emoji), so the bar gets the same
    /// rounded-bottom + concave-shoulder shape as the original device notch
    /// instead of three flat black rectangles.
    private var closedBarWidth: CGFloat {
        deviceNotchRect.width + 2 * deviceNotchRect.height
    }

    private var mainSize: CGSize {
        switch status {
        case .closed, .popping:
            // Popping shares the closed footprint: the hover "grow" effect
            // is applied as a top-anchored scaleEffect in NotchView so the
            // shape and the content scale together as one container.
            return CGSize(
                width: max(closedBarWidth, 0),
                height: max(deviceNotchRect.height, 0)
            )
        case .opened:
            return panelSize
        }
    }

    private var notchCornerRadius: CGFloat {
        switch status {
        case .closed, .popping: return 8
        case .opened: return 32
        }
    }

    private var shoulderRadius: CGFloat {
        switch status {
        case .closed, .popping: return 6
        case .opened: return 18
        }
    }

    var body: some View {
        NotchSilhouetteShape(
            cornerRadius: notchCornerRadius,
            shoulderRadius: shoulderRadius
        )
        .fill(Color.black)
        .frame(
            width: mainSize.width + 2 * shoulderRadius,
            height: mainSize.height
        )
    }
}

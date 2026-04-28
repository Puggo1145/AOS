import AppKit
import CoreGraphics
import Foundation

// MARK: - SoftwareCursorGlyphRenderer
//
// Clean, small vector arrow modelled on the macOS system cursor. Tip
// pinned to the visually top-left of the panel so coordinate math stays
// honest — the panel's bottom-left frame origin sits `windowSize.height
// - tipAnchor.y` below the tip, which is what `SoftwareCursorOverlay`
// expects when it converts a tip position into a panel origin.
//
// The renderer ignores the legacy fog parameters carried in
// `SoftwareCursorGlyphRenderState` (kept on the struct so the dynamics
// machinery doesn't need to know the artwork shrank). Click feedback is
// a subtle scale pulse plus an expanding ring centered on the tip.

struct SoftwareCursorGlyphRenderState {
    let rotation: CGFloat
    let cursorBodyOffset: CGVector
    let fogOffset: CGVector
    let fogOpacity: CGFloat
    let fogScale: CGFloat
    let clickProgress: CGFloat

    init(
        rotation: CGFloat,
        cursorBodyOffset: CGVector,
        fogOffset: CGVector,
        fogOpacity: CGFloat,
        fogScale: CGFloat,
        clickProgress: CGFloat
    ) {
        self.rotation = rotation
        self.cursorBodyOffset = cursorBodyOffset
        self.fogOffset = fogOffset
        self.fogOpacity = fogOpacity
        self.fogScale = fogScale
        self.clickProgress = clickProgress
    }
}

enum SoftwareCursorGlyphMetrics {
    /// Tight panel — 36×36 fits the arrow body plus the click-ring at
    /// peak expansion without running into the panel edge.
    static let windowSize = CGSize(width: 36, height: 36)

    /// Tip in view coords (y-up AppKit). `(3, windowSize.height - 3)`
    /// places the tip at the visually top-left corner with 3pt margin
    /// so the stroke and shadow stay inside the panel.
    static let tipAnchor = CGPoint(x: 3, y: 33)

    /// Reported visible glyph extent (used by motion-bounds maths in the
    /// overlay). The arrow body fits inside roughly 17×22 from the tip.
    static let pointerSize = CGSize(width: 17, height: 22)
    static let pointerOffset: CGPoint = .zero

    /// Visual neutral heading of the arrow tip — up-left, in CursorMotion's
    /// y-down screen-state convention. Matches the procedural contour
    /// orientation, so no extra rotation is applied during draw.
    static let targetNeutralHeading: CGFloat = -(3 * CGFloat.pi / 4)
    static let proceduralContourNeutralHeading: CGFloat = -(3 * CGFloat.pi / 4)
    static let pointerArtworkRotation: CGFloat = 0

    /// Carried for ABI compatibility with the legacy reference-image
    /// loader signature; unused — the renderer is fully procedural.
    static let referenceImageResourceName = ""
}

private enum SoftwareCursorGlyphColors {
    static let body = NSColor.black
    static let outline = NSColor.white
    static let shadow = NSColor.black.withAlphaComponent(0.35)
    static let ring = NSColor.white
}

enum SoftwareCursorGlyphRenderer {
    static func draw(
        in bounds: CGRect,
        context: CGContext,
        state: SoftwareCursorGlyphRenderState
    ) {
        let drawingState = state.appKitDrawingState
        let tipAnchor = SoftwareCursorGlyphMetrics.tipAnchor
        let pulseScale = 1 + drawingState.clickProgress * 0.08

        context.saveGState()
        context.setShouldAntialias(true)
        context.interpolationQuality = .high

        // Rotation + scale pivoted on the tip so the arrow doesn't drift
        // off the click target during dynamics rotation or click pulse.
        context.translateBy(x: tipAnchor.x, y: tipAnchor.y)
        // Damp the dynamics rotation — full rotation makes a small cursor
        // look spinny on short flicks.
        context.rotate(by: drawingState.rotation * 0.35)
        context.scaleBy(x: pulseScale, y: pulseScale)
        context.translateBy(x: -tipAnchor.x, y: -tipAnchor.y)

        let path = arrowPath(tipAt: tipAnchor)

        // Drop shadow under the body. NSGraphicsContext is the only way
        // to get an NSShadow applied to a NSBezierPath fill.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 2.4
        shadow.shadowOffset = CGSize(width: 0, height: -1.2)
        shadow.shadowColor = SoftwareCursorGlyphColors.shadow
        shadow.set()
        SoftwareCursorGlyphColors.body.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        // White outline first (drawn fat then over-filled), then crisp body.
        SoftwareCursorGlyphColors.outline.setStroke()
        path.lineWidth = 2.6
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        path.stroke()

        SoftwareCursorGlyphColors.body.setFill()
        path.fill()

        context.restoreGState()

        // Expanding ring on click. Centered at the (un-pulsed) tip so it
        // reads as feedback at the click target rather than on the body.
        if drawingState.clickProgress > 0.01 {
            let progress = drawingState.clickProgress
            let radius = 5 + progress * 11
            let alpha = (1 - progress) * 0.65
            let lineWidth: CGFloat = 1.6
            let rect = CGRect(
                x: tipAnchor.x - radius,
                y: tipAnchor.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            context.saveGState()
            context.setStrokeColor(SoftwareCursorGlyphColors.ring.withAlphaComponent(alpha).cgColor)
            context.setLineWidth(lineWidth)
            context.strokeEllipse(in: rect)
            context.restoreGState()
        }
    }

    /// Classic macOS arrow. Tip at `tip` in the view's coord space (y-up,
    /// AppKit convention). The shape is authored in icon space (y-down,
    /// tip at origin) for legibility; each point is converted at draw
    /// time. Body extends down-right of the tip — i.e. the cursor
    /// visually points up-left.
    private static func arrowPath(tipAt tip: CGPoint) -> NSBezierPath {
        // (x, y) in icon space, y grows downward.
        let raw: [(CGFloat, CGFloat)] = [
            (0,    0),       // tip
            (0,    16.5),    // outer left edge straight down
            (4.2,  12.6),    // inner notch (heads back up to start the tail)
            (7.5,  19.0),    // outer right of tail
            (9.4,  18.1),    // outermost tail point (bottom-right)
            (6.0,  11.9),    // inner top of tail (back into head)
            (11.5, 11.5),    // right corner of arrowhead
        ]
        let path = NSBezierPath()
        for (i, (x, y)) in raw.enumerated() {
            let pt = CGPoint(x: tip.x + x, y: tip.y - y)
            if i == 0 { path.move(to: pt) } else { path.line(to: pt) }
        }
        path.close()
        return path
    }
}

private extension SoftwareCursorGlyphRenderState {
    /// CursorMotion's dynamics state is interpreted in y-down screen
    /// space; AppKit draws in y-up. The overlay flips Y on the rotation
    /// and any vector that participates in drawing so motion that
    /// reads as "downward" in CursorMotion becomes downward on screen.
    var appKitDrawingState: SoftwareCursorGlyphRenderState {
        SoftwareCursorGlyphRenderState(
            rotation: -rotation,
            cursorBodyOffset: CGVector(dx: cursorBodyOffset.dx, dy: -cursorBodyOffset.dy),
            fogOffset: CGVector(dx: fogOffset.dx, dy: -fogOffset.dy),
            fogOpacity: fogOpacity,
            fogScale: fogScale,
            clickProgress: clickProgress
        )
    }
}

// AOS ships only the procedural pointer path. The playground source loaded a
// reference PNG from bundle/repo when present; we deliberately drop that to
// avoid carrying a binary asset.
func loadReferenceCursorWindowImage() -> NSImage? { nil }

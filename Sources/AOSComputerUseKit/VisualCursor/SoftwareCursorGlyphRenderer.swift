import AppKit
import CoreGraphics
import Foundation

// MARK: - SoftwareCursorGlyphRenderer
//
// Blue agent cursor. Tip stays pinned to the visually top-left of the
// panel so coordinate math stays honest — the panel's bottom-left frame
// origin sits `windowSize.height - tipAnchor.y` below the tip, which is
// what `SoftwareCursorOverlay` expects when it converts a tip position
// into a panel origin.
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
    /// Small panel fits the 16×16 pointer plus click feedback.
    static let windowSize = CGSize(width: 32, height: 32)

    /// Tip in view coords (y-up AppKit). `(3, windowSize.height - 3)`
    /// places the tip at the visually top-left corner with 3pt margin
    /// so the stroke and shadow stay inside the panel.
    static let tipAnchor = CGPoint(x: 8, y: 24)

    /// Reported visible glyph extent (used by motion-bounds maths in the
    /// overlay). The arrow body is intentionally kept at 16×16.
    static let pointerSize = CGSize(width: 16, height: 16)
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
    static let body = NSColor.systemBlue
    static let outline = NSColor.white
    static let shadow = NSColor.black.withAlphaComponent(0.28)
    static let ring = NSColor.systemBlue
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
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = CGSize(width: 0, height: -1.8)
        shadow.shadowColor = SoftwareCursorGlyphColors.shadow
        shadow.set()
        SoftwareCursorGlyphColors.body.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        // White outline first (drawn fat then over-filled), then crisp body.
        SoftwareCursorGlyphColors.outline.setStroke()
        path.lineWidth = 1.25
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
            let radius = 4 + progress * 8
            let alpha = (1 - progress) * 0.65
            let lineWidth: CGFloat = 1.3
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

    /// Cursor path ported from the product SVG. Coordinates are authored in
    /// SVG space, then scaled to a 16×16 pointer while keeping the rounded
    /// upper-left click corner aligned near `tip`.
    private static func arrowPath(tipAt tip: CGPoint) -> NSBezierPath {
        let origin = CGPoint(x: 2.85, y: 3.02)
        let scale: CGFloat = 0.8

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: tip.x + ((x - origin.x) * scale),
                y: tip.y - ((y - origin.y) * scale)
            )
        }

        let path = NSBezierPath()
        path.move(to: point(2.85, 3.02))
        path.curve(
            to: point(5.85, 0.02),
            controlPoint1: point(2.16, 1.15),
            controlPoint2: point(3.98, -0.67)
        )
        path.line(to: point(20.31, 5.37))
        path.curve(
            to: point(19.82, 9.87),
            controlPoint1: point(22.59, 6.22),
            controlPoint2: point(22.22, 9.55)
        )
        path.line(to: point(15.31, 10.48))
        path.curve(
            to: point(13.31, 12.48),
            controlPoint1: point(14.27, 10.62),
            controlPoint2: point(13.45, 11.44)
        )
        path.line(to: point(12.7, 16.99))
        path.curve(
            to: point(8.2, 17.48),
            controlPoint1: point(12.38, 19.39),
            controlPoint2: point(9.05, 19.76)
        )
        path.line(to: point(2.85, 3.02))
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

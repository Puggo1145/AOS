import AppKit
import CoreGraphics
import Foundation

struct VirtualMouseGlyphRenderState {
    let rotation: CGFloat
    let cursorBodyOffset: CGVector
    let fogOffset: CGVector
    let fogOpacity: CGFloat
    let fogScale: CGFloat
    let clickProgress: CGFloat

    var appKitDrawingState: VirtualMouseGlyphRenderState {
        VirtualMouseGlyphRenderState(
            rotation: -rotation,
            cursorBodyOffset: CGVector(dx: cursorBodyOffset.dx, dy: -cursorBodyOffset.dy),
            fogOffset: CGVector(dx: fogOffset.dx, dy: -fogOffset.dy),
            fogOpacity: fogOpacity,
            fogScale: fogScale,
            clickProgress: clickProgress
        )
    }
}

enum VirtualMouseGlyphMetrics {
    static let windowSize = CGSize(width: 126, height: 126)
    static let tipAnchor = CGPoint(x: 60.35, y: 70.3)
    static let resourceName = "official-software-cursor-window-252"
    static let targetNeutralHeading = -(3 * CGFloat.pi / 4)
}

enum VirtualMouseGlyphRenderer {
    private static let referenceImage = loadReferenceImage()

    static func draw(
        in bounds: CGRect,
        context: CGContext,
        state: VirtualMouseGlyphRenderState
    ) {
        let drawingState = state.appKitDrawingState
        let motionCompression = min(
            hypot(drawingState.cursorBodyOffset.dx, drawingState.cursorBodyOffset.dy) * 0.008,
            0.018
        )
        let pulseCompression = state.clickProgress * 0.03

        context.saveGState()
        context.interpolationQuality = .high
        context.translateBy(
            x: bounds.midX + drawingState.cursorBodyOffset.dx,
            y: bounds.midY + drawingState.cursorBodyOffset.dy
        )
        context.rotate(by: drawingState.rotation)
        context.scaleBy(
            x: 1 - motionCompression - pulseCompression,
            y: 1 + (pulseCompression * 0.4)
        )
        context.translateBy(x: -bounds.midX, y: -bounds.midY)
        referenceImage.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
        context.restoreGState()
    }

    private static func loadReferenceImage() -> NSImage {
        guard
            let url = Bundle.module.url(
                forResource: VirtualMouseGlyphMetrics.resourceName,
                withExtension: "png"
            ),
            let image = NSImage(contentsOf: url)
        else {
            preconditionFailure("Missing bundled virtual mouse cursor asset: \(VirtualMouseGlyphMetrics.resourceName).png")
        }

        return image
    }
}

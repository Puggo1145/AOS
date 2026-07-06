import Foundation

// MARK: - Detach morph presentation
//
// Pure geometry/derived-state for the attached→detached (and reverse) morph
// animation. Relocated out of NotchViewModel so the morph math can be
// exercised without constructing the viewmodel's service graph; see
// NotchGeometryTests for the coverage.

public enum DetachMorphPhase: Sendable, Equatable {
    case idle
    case source
    case target
}

public struct PanelCornerRadii: Sendable, Equatable {
    public let topLeading: CGFloat
    public let topTrailing: CGFloat
    public let bottomLeading: CGFloat
    public let bottomTrailing: CGFloat

    public init(
        topLeading: CGFloat,
        topTrailing: CGFloat,
        bottomLeading: CGFloat,
        bottomTrailing: CGFloat
    ) {
        self.topLeading = topLeading
        self.topTrailing = topTrailing
        self.bottomLeading = bottomLeading
        self.bottomTrailing = bottomTrailing
    }

    public init(all radius: CGFloat) {
        self.init(
            topLeading: radius,
            topTrailing: radius,
            bottomLeading: radius,
            bottomTrailing: radius
        )
    }
}

public struct DetachMorphPresentation: Sendable, Equatable {
    public let shoulderRadius: CGFloat
    public let contentTopPadding: CGFloat
    public let silhouetteSize: CGSize
    public let shapeCornerRadii: PanelCornerRadii
    public let contentClipCornerRadii: PanelCornerRadii
    public let chromeOverlayOpacity: CGFloat

    public nonisolated static func make(
        phase: DetachMorphPhase,
        placement: NotchPlacement,
        screenRect: CGRect,
        finalSize: CGSize,
        sourceHeight: CGFloat,
        sourceBottomCornerRadius: CGFloat,
        targetCornerRadius: CGFloat,
        targetTopPadding: CGFloat
    ) -> DetachMorphPresentation {
        precondition(screenRect.width > 0 && screenRect.height > 0, "Screen rect must be positive")
        precondition(finalSize.width > 0 && finalSize.height > 0, "Detach size must be positive")
        precondition(sourceHeight > 0, "Detach source height must be positive")
        precondition(targetTopPadding >= 0, "Detach top padding cannot be negative")

        switch phase {
        case .source:
            let shoulderRadius = NotchGeometryModel.openedShoulderRadius
            return DetachMorphPresentation(
                shoulderRadius: shoulderRadius,
                contentTopPadding: 0,
                silhouetteSize: CGSize(
                    width: finalSize.width + 2 * shoulderRadius,
                    height: sourceHeight
                ),
                shapeCornerRadii: PanelCornerRadii(
                    topLeading: 0,
                    topTrailing: 0,
                    bottomLeading: sourceBottomCornerRadius,
                    bottomTrailing: sourceBottomCornerRadius
                ),
                contentClipCornerRadii: PanelCornerRadii(
                    topLeading: 0,
                    topTrailing: 0,
                    bottomLeading: sourceBottomCornerRadius,
                    bottomTrailing: sourceBottomCornerRadius
                ),
                chromeOverlayOpacity: 0
            )
        case .target, .idle:
            let cornerRadii = edgeAdjustedCornerRadii(
                PanelCornerRadii(all: targetCornerRadius),
                placement: placement,
                screenRect: screenRect
            )
            return DetachMorphPresentation(
                shoulderRadius: 0,
                contentTopPadding: targetTopPadding,
                silhouetteSize: finalSize,
                shapeCornerRadii: cornerRadii,
                contentClipCornerRadii: cornerRadii,
                chromeOverlayOpacity: 0
            )
        }
    }

    private nonisolated static func edgeAdjustedCornerRadii(
        _ radii: PanelCornerRadii,
        placement: NotchPlacement,
        screenRect: CGRect
    ) -> PanelCornerRadii {
        let edge: NotchEdge?
        switch placement {
        case let .edgeDock(dockedEdge, _, _, _, _):
            edge = dockedEdge
        case let .detached(frame):
            edge = NotchPlacementGeometry.touchingDockEdge(
                screenRect: screenRect,
                frame: frame
            )
        case .attachedTop:
            edge = nil
        }

        guard let edge else {
            return radii
        }

        switch edge {
        case .left:
            return PanelCornerRadii(
                topLeading: 0,
                topTrailing: radii.topTrailing,
                bottomLeading: 0,
                bottomTrailing: radii.bottomTrailing
            )
        case .right:
            return PanelCornerRadii(
                topLeading: radii.topLeading,
                topTrailing: 0,
                bottomLeading: radii.bottomLeading,
                bottomTrailing: 0
            )
        case .bottom:
            return PanelCornerRadii(
                topLeading: radii.topLeading,
                topTrailing: radii.topTrailing,
                bottomLeading: 0,
                bottomTrailing: 0
            )
        case .top:
            return radii
        }
    }
}

import CoreGraphics

public enum NotchEdge: Sendable, Equatable {
    case left
    case right
    case top
    case bottom
}

public enum NotchPlacement: Sendable, Equatable {
    case attachedTop
    case detached(CGRect)
    case edgeDock(edge: NotchEdge, hiddenFrame: CGRect, revealFrame: CGRect, triggerFrame: CGRect, revealed: Bool)
}

public enum NotchPlacementGeometry {
    public static let defaultEdgeSnapThreshold: CGFloat = 24
    public static let defaultEdgeTriggerThickness: CGFloat = 8

    public static func placementOnRelease(
        screenRect: CGRect,
        deviceNotchRect: CGRect,
        panelSize: CGSize,
        pointer: CGPoint,
        dragOffset: CGPoint,
        edgeTriggerThickness: CGFloat = defaultEdgeTriggerThickness
    ) -> NotchPlacement {
        precondition(screenRect.width > 0 && screenRect.height > 0, "Screen rect must be positive")
        precondition(panelSize.width > 0 && panelSize.height > 0, "Panel size must be positive")
        precondition(deviceNotchRect.width > 0 && deviceNotchRect.height > 0, "Device notch rect must be positive")
        precondition(edgeTriggerThickness > 0, "Edge trigger thickness must be positive")

        let releasedFrame = detachedFrame(
            screenRect: screenRect,
            panelSize: panelSize,
            pointer: pointer,
            dragOffset: dragOffset
        )
        return placementOnRelease(
            screenRect: screenRect,
            deviceNotchRect: deviceNotchRect,
            panelFrame: releasedFrame,
            edgeTriggerThickness: edgeTriggerThickness
        )
    }

    public static func placementOnRelease(
        screenRect: CGRect,
        deviceNotchRect: CGRect,
        panelFrame: CGRect,
        edgeTriggerThickness: CGFloat = defaultEdgeTriggerThickness
    ) -> NotchPlacement {
        precondition(screenRect.width > 0 && screenRect.height > 0, "Screen rect must be positive")
        precondition(panelFrame.width > 0 && panelFrame.height > 0, "Panel frame must be positive")
        precondition(deviceNotchRect.width > 0 && deviceNotchRect.height > 0, "Device notch rect must be positive")
        precondition(edgeTriggerThickness > 0, "Edge trigger thickness must be positive")

        let releasedFrame = clamp(panelFrame, inside: screenRect)
        if releasedFrame.maxY == screenRect.maxY {
            return .attachedTop
        }

        guard let edge = touchingDockEdge(screenRect: screenRect, frame: releasedFrame) else {
            return .detached(releasedFrame)
        }
        return edgeDockPlacement(
            edge: edge,
            screenRect: screenRect,
            panelFrame: releasedFrame,
            triggerThickness: edgeTriggerThickness
        )
    }

    public static func nearestEdge(
        screenRect: CGRect,
        pointer: CGPoint,
        threshold: CGFloat = defaultEdgeSnapThreshold
    ) -> NotchEdge? {
        precondition(screenRect.width > 0 && screenRect.height > 0, "Screen rect must be positive")
        precondition(threshold > 0, "Edge snap threshold must be positive")

        let distances: [(NotchEdge, CGFloat, Int)] = [
            (.left, abs(pointer.x - screenRect.minX), 0),
            (.right, abs(screenRect.maxX - pointer.x), 0),
            (.top, abs(screenRect.maxY - pointer.y), 1),
            (.bottom, abs(pointer.y - screenRect.minY), 1)
        ]
        guard let nearest = distances
            .filter({ $0.1 <= threshold })
            .min(by: { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return lhs.2 < rhs.2
                }
                return lhs.1 < rhs.1
            }) else {
            return nil
        }
        return nearest.0
    }

    public static func nearestEdge(
        screenRect: CGRect,
        frame: CGRect,
        threshold: CGFloat = defaultEdgeSnapThreshold
    ) -> NotchEdge? {
        precondition(screenRect.width > 0 && screenRect.height > 0, "Screen rect must be positive")
        precondition(frame.width > 0 && frame.height > 0, "Frame must be positive")
        precondition(threshold > 0, "Edge snap threshold must be positive")

        let distances: [(NotchEdge, CGFloat, Int)] = [
            (.left, abs(frame.minX - screenRect.minX), 0),
            (.right, abs(screenRect.maxX - frame.maxX), 0),
            (.top, abs(screenRect.maxY - frame.maxY), 1),
            (.bottom, abs(frame.minY - screenRect.minY), 1)
        ]
        guard let nearest = distances
            .filter({ $0.1 <= threshold })
            .min(by: { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return lhs.2 < rhs.2
                }
                return lhs.1 < rhs.1
            }) else {
            return nil
        }
        return nearest.0
    }

    public static func touchingDockEdge(
        screenRect: CGRect,
        frame: CGRect
    ) -> NotchEdge? {
        precondition(screenRect.width > 0 && screenRect.height > 0, "Screen rect must be positive")
        precondition(frame.width > 0 && frame.height > 0, "Frame must be positive")

        let contacts: [(NotchEdge, Bool, Int)] = [
            (.left, frame.minX == screenRect.minX, 0),
            (.right, frame.maxX == screenRect.maxX, 0),
            (.bottom, frame.minY == screenRect.minY, 1)
        ]
        return contacts
            .filter(\.1)
            .min(by: { lhs, rhs in lhs.2 < rhs.2 })?
            .0
    }

    public static func detachedFrame(
        screenRect: CGRect,
        panelSize: CGSize,
        pointer: CGPoint,
        dragOffset: CGPoint
    ) -> CGRect {
        precondition(screenRect.width > 0 && screenRect.height > 0, "Screen rect must be positive")
        precondition(panelSize.width > 0 && panelSize.height > 0, "Panel size must be positive")

        let origin = CGPoint(x: pointer.x - dragOffset.x, y: pointer.y - dragOffset.y)
        return clamp(
            CGRect(origin: origin, size: panelSize),
            inside: screenRect
        )
    }

    public static func mouseActiveRect(for placement: NotchPlacement) -> CGRect {
        switch placement {
        case .attachedTop:
            return .zero
        case let .detached(frame):
            return frame
        case let .edgeDock(_, _, revealFrame, triggerFrame, revealed):
            return revealed ? revealFrame : triggerFrame
        }
    }

    public static func currentPanelFrame(
        placement: NotchPlacement,
        attachedFrame: CGRect
    ) -> CGRect {
        switch placement {
        case .attachedTop:
            return attachedFrame
        case let .detached(frame):
            return frame
        case let .edgeDock(_, hiddenFrame, revealFrame, _, revealed):
            return revealed ? revealFrame : hiddenFrame
        }
    }

    public static func resizedDetachedFrame(
        screenRect: CGRect,
        currentFrame: CGRect,
        targetSize: CGSize
    ) -> CGRect {
        resizedFloatingFrame(
            screenRect: screenRect,
            currentFrame: currentFrame,
            targetSize: targetSize,
            edgeAnchor: nil
        )
    }

    private static func resizedFloatingFrame(
        screenRect: CGRect,
        currentFrame: CGRect,
        targetSize: CGSize,
        edgeAnchor: NotchEdge?
    ) -> CGRect {
        precondition(screenRect.width > 0 && screenRect.height > 0, "Screen rect must be positive")
        precondition(currentFrame.width > 0 && currentFrame.height > 0, "Current frame must be positive")
        precondition(targetSize.width > 0 && targetSize.height > 0, "Target size must be positive")

        let x: CGFloat
        if edgeAnchor == .right || currentFrame.maxX == screenRect.maxX {
            x = screenRect.maxX - targetSize.width
        } else {
            x = currentFrame.minX
        }

        let y: CGFloat
        if edgeAnchor == .bottom {
            y = screenRect.minY
        } else {
            y = currentFrame.maxY - targetSize.height
        }

        return clamp(
            CGRect(origin: CGPoint(x: x, y: y), size: targetSize),
            inside: screenRect
        )
    }

    public static func resizedFloatingPlacement(
        _ placement: NotchPlacement,
        screenRect: CGRect,
        targetSize: CGSize
    ) -> NotchPlacement {
        precondition(screenRect.width > 0 && screenRect.height > 0, "Screen rect must be positive")
        precondition(targetSize.width > 0 && targetSize.height > 0, "Target size must be positive")

        switch placement {
        case .attachedTop:
            return .attachedTop
        case let .detached(frame):
            return .detached(resizedDetachedFrame(
                screenRect: screenRect,
                currentFrame: frame,
                targetSize: targetSize
            ))
        case let .edgeDock(edge, _, revealFrame, triggerFrame, revealed):
            let resizedRevealFrame = resizedFloatingFrame(
                screenRect: screenRect,
                currentFrame: revealFrame,
                targetSize: targetSize,
                edgeAnchor: edge
            )
            let triggerThickness: CGFloat
            switch edge {
            case .left, .right:
                triggerThickness = triggerFrame.width
            case .bottom:
                triggerThickness = triggerFrame.height
            case .top:
                preconditionFailure("Top edge uses attached notch placement")
            }
            guard case let .edgeDock(_, hiddenFrame, revealFrame, triggerFrame, _) =
                    edgeDockPlacement(
                        edge: edge,
                        screenRect: screenRect,
                        panelFrame: resizedRevealFrame,
                        triggerThickness: triggerThickness
                    ) else {
                preconditionFailure("Edge dock placement must stay edge dock")
            }
            return .edgeDock(
                edge: edge,
                hiddenFrame: hiddenFrame,
                revealFrame: revealFrame,
                triggerFrame: triggerFrame,
                revealed: revealed
            )
        }
    }

    public static func edgeDockPlacement(
        edge: NotchEdge,
        screenRect: CGRect,
        panelFrame: CGRect,
        triggerThickness: CGFloat = defaultEdgeTriggerThickness
    ) -> NotchPlacement {
        precondition(screenRect.width > 0 && screenRect.height > 0, "Screen rect must be positive")
        precondition(panelFrame.width > 0 && panelFrame.height > 0, "Panel frame must be positive")
        precondition(triggerThickness > 0, "Edge trigger thickness must be positive")
        precondition(edge != .top, "Top edge uses attached notch placement")

        let panelSize = panelFrame.size
        let hiddenFrame: CGRect
        let revealFrame: CGRect
        let triggerFrame: CGRect

        switch edge {
        case .left:
            revealFrame = CGRect(
                x: screenRect.minX,
                y: clampedOrigin(panelFrame.minY, length: panelSize.height, min: screenRect.minY, max: screenRect.maxY),
                width: panelSize.width,
                height: panelSize.height
            )
            hiddenFrame = revealFrame.offsetBy(dx: -panelSize.width, dy: 0)
            triggerFrame = CGRect(
                x: screenRect.minX,
                y: screenRect.minY,
                width: triggerThickness,
                height: screenRect.height
            )
        case .right:
            revealFrame = CGRect(
                x: screenRect.maxX - panelSize.width,
                y: clampedOrigin(panelFrame.minY, length: panelSize.height, min: screenRect.minY, max: screenRect.maxY),
                width: panelSize.width,
                height: panelSize.height
            )
            hiddenFrame = revealFrame.offsetBy(dx: panelSize.width, dy: 0)
            triggerFrame = CGRect(
                x: screenRect.maxX - triggerThickness,
                y: screenRect.minY,
                width: triggerThickness,
                height: screenRect.height
            )
        case .top:
            preconditionFailure("Top edge uses attached notch placement")
        case .bottom:
            revealFrame = CGRect(
                x: clampedOrigin(panelFrame.minX, length: panelSize.width, min: screenRect.minX, max: screenRect.maxX),
                y: screenRect.minY,
                width: panelSize.width,
                height: panelSize.height
            )
            hiddenFrame = revealFrame.offsetBy(dx: 0, dy: -panelSize.height)
            triggerFrame = CGRect(
                x: screenRect.minX,
                y: screenRect.minY,
                width: screenRect.width,
                height: triggerThickness
            )
        }

        return .edgeDock(
            edge: edge,
            hiddenFrame: hiddenFrame,
            revealFrame: revealFrame,
            triggerFrame: triggerFrame,
            revealed: false
        )
    }

    private static func clampedOrigin(
        _ origin: CGFloat,
        length: CGFloat,
        min: CGFloat,
        max: CGFloat
    ) -> CGFloat {
        Swift.max(min, Swift.min(origin, max - length))
    }

    private static func clamp(_ frame: CGRect, inside bounds: CGRect) -> CGRect {
        CGRect(
            x: Swift.max(bounds.minX, Swift.min(frame.minX, bounds.maxX - frame.width)),
            y: Swift.max(bounds.minY, Swift.min(frame.minY, bounds.maxY - frame.height)),
            width: frame.width,
            height: frame.height
        )
    }
}

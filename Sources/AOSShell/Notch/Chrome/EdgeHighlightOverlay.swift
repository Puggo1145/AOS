import SwiftUI
import AppKit
import Combine

// MARK: - EdgeHighlightOverlay
//
// White radial highlight that follows the mouse along the notch silhouette's
// edge. Active only in `.closed` and `.popping` per notch-ui.md "Edge
// highlight 交互"; the parent gates rendering on viewModel.status.
//
// Implementation:
//   - subscribe `EventMonitors.shared.mouseLocation` (already throttled to
//     ~60 Hz by the OS event mask)
//   - convert to view-local coords via a GeometryReader frame in `.global`
//   - render a `Canvas` painting a RadialGradient at the local point
//   - mask with `NotchShape().stroke(lineWidth: 3)` so highlight only shows
//     on edge pixels
//   - when mouse leaves the device-notch hot zone by ≥ 28pt, fade out

struct EdgeHighlightOverlay: View {
    let deviceNotchRect: CGRect
    let panelSize: CGSize
    let status: NotchViewModel.Status
    /// True size + corner of the silhouette underneath. The overlay's own
    /// frame is intentionally taller (so the cursor can be tracked in the
    /// leave-slack band below the bar) — but the mask outline must trace
    /// the silhouette itself, otherwise the gradient lights up empty space
    /// instead of the visible edge.
    let silhouetteSize: CGSize
    let silhouetteCornerRadius: CGFloat

    @State private var localMouse: CGPoint?
    @State private var visible: Bool = false

    private static let highlightRadius: CGFloat = 24
    private static let leaveSlack: CGFloat = 28
    /// How deep into the bar the cursor can travel before the highlight is
    /// suppressed. The highlight should read as a "skim" along the silhouette
    /// border — once the cursor sinks past this band the user has fully
    /// entered the bar, so the white edge glow should disappear.
    private static let interiorBand: CGFloat = 8

    var body: some View {
        GeometryReader { _ in
            ZStack {
                if let local = localMouse {
                    Canvas { ctx, size in
                        let gradient = Gradient(stops: [
                            .init(color: .white.opacity(0.6), location: 0.0),
                            .init(color: .white.opacity(0.0), location: 1.0)
                        ])
                        let center = local
                        let radius = Self.highlightRadius
                        let circle = Path(
                            ellipseIn: CGRect(
                                x: center.x - radius,
                                y: center.y - radius,
                                width: radius * 2,
                                height: radius * 2
                            )
                        )
                        ctx.fill(
                            circle,
                            with: .radialGradient(
                                gradient,
                                center: center,
                                startRadius: 0,
                                endRadius: radius
                            )
                        )
                    }
                    .compositingGroup()
                    .blendMode(.sourceAtop)
                    .mask(
                        NotchEdgeHighlightShape(cornerRadius: silhouetteCornerRadius)
                            .stroke(lineWidth: 3)
                            .frame(
                                width: silhouetteSize.width,
                                height: silhouetteSize.height
                            )
                            .frame(
                                maxWidth: .infinity,
                                maxHeight: .infinity,
                                alignment: .top
                            )
                    )
                    .opacity(visible ? 1 : 0)
                    .animation(.easeOut(duration: visible ? 0.05 : 0.2), value: visible)
                    .animation(.easeOut(duration: 0.05), value: localMouse)
                }
            }
            .onReceive(EventMonitors.shared.mouseLocation) { global in
                let result = Self.computeHighlight(
                    globalMouse: global,
                    deviceNotchRect: deviceNotchRect,
                    leaveSlack: Self.leaveSlack,
                    interiorBand: Self.interiorBand
                )
                localMouse = result.localPoint
                visible = result.active
            }
        }
        .allowsHitTesting(false)
    }

    /// Pure helper exposed for testing. Returns the closed-bar-local
    /// highlight position and whether the highlight should be active. It is
    /// active when the global mouse is inside the closed-bar rect
    /// (icon + physical notch + emoji) expanded by `leaveSlack`, mirroring
    /// the hover hot zone driving the closed↔popping transition so the
    /// edge highlight tracks the user wherever the bar reacts to hover.
    /// The highlight is active only while the cursor is in the *border band*
    /// around the closed bar — a thin ring defined by `closedBar` expanded
    /// outward by `leaveSlack` and shrunk inward by `interiorBand`. Once the
    /// cursor sinks past `interiorBand` into the bar's interior it counts as
    /// "fully inside" and the glow is suppressed; outside `leaveSlack` the
    /// cursor has left the bar entirely.
    public static func computeHighlight(
        globalMouse: CGPoint,
        deviceNotchRect: CGRect,
        leaveSlack: CGFloat,
        interiorBand: CGFloat
    ) -> (localPoint: CGPoint, active: Bool) {
        let h = deviceNotchRect.height
        let closedBar = CGRect(
            x: deviceNotchRect.minX - h,
            y: deviceNotchRect.minY,
            width: deviceNotchRect.width + h * 2,
            height: h
        )
        let local = CGPoint(
            x: globalMouse.x - closedBar.minX,
            // NSEvent.mouseLocation is bottom-up in screen space, while the
            // Canvas/mask draw top-down inside the closed-bar silhouette.
            y: closedBar.maxY - globalMouse.y
        )
        let outer = closedBar.insetBy(dx: -leaveSlack, dy: -leaveSlack)
        let inner = closedBar.insetBy(dx: interiorBand, dy: interiorBand)
        let active = outer.contains(globalMouse) && !inner.contains(globalMouse)
        return (local, active)
    }
}

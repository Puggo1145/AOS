import SwiftUI

// MARK: - NotchView
//
// Top-level SwiftUI tree mounted into the NotchWindow. The silhouette and
// the inner content are bound to one morphing container so closed → opened
// reads as a single jelly expansion: the shape grows, the content reveals
// inside it (clipped), they share the same spring animation.
//
// Layers:
//   1. NotchShape silhouette (the morphing black container with shoulders)
//   2. Status content (closed bar OR opened panel), sized + clipped to the
//      same rounded rect as the silhouette so it reveals progressively as
//      the container grows.
//   3. EdgeHighlightOverlay (closed / popping only).
//
// Hover (popping) uses scaleEffect anchored at .top so the bar grows from
// its center sideways + downward (top-edge stays glued to the screen edge).

struct NotchView: View {
    let viewModel: NotchViewModel

    var body: some View {
        ZStack(alignment: .top) {
            // Layer 1: silhouette — animates size + corner radius via the
            // outer .animation modifier.
            NotchShape(
                status: viewModel.status,
                deviceNotchRect: viewModel.deviceNotchRect,
                panelSize: viewModel.notchOpenedSize
            )

            // Layer 2: content lives on a fixed, final-size canvas inside
            // the same morphing rounded rect. The silhouette's animated
            // clipping window reveals it from the notch center, avoiding
            // SwiftUI insertion movement that reads as a side slide.
            content
                .frame(
                    width: shapeWidth,
                    height: shapeHeight,
                    alignment: .top
                )
                .clipShape(
                    .rect(
                        bottomLeadingRadius: containerCornerRadius,
                        bottomTrailingRadius: containerCornerRadius
                    )
                )

            // Layer 3: edge highlight overlay (closed/popping only). The
            // overlay frame extends below the silhouette so the cursor can
            // still be tracked while in the leave-slack band — the mask
            // inside aligns the stroke to the silhouette itself.
            if viewModel.status != .opened {
                EdgeHighlightOverlay(
                    deviceNotchRect: viewModel.deviceNotchRect,
                    panelSize: viewModel.notchOpenedSize,
                    status: viewModel.status,
                    silhouetteSize: CGSize(width: shapeWidth, height: shapeHeight),
                    silhouetteCornerRadius: containerCornerRadius
                )
                .frame(
                    width: shapeWidth,
                    height: shapeHeight + 32
                )
            }
        }
        // Hover "pop" effect: anchor at .top so the visual growth fans out
        // sideways + downward from the screen-edge center, never upward.
        .scaleEffect(viewModel.status == .popping ? 1.04 : 1.0, anchor: .top)
        .offset(x: notchHorizontalOffset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(statusAnimation, value: viewModel.status)
        // Height changes as the agent loop activates / completes. Drive the
        // silhouette + content frame interpolation off the size value so the
        // bottom edge eases down (or back up) instead of snapping.
        .animation(.smooth(duration: 0.32, extraBounce: 0.05),
                   value: viewModel.notchOpenedSize.height)
    }

    /// Closing back to the device notch must not overshoot — a bouncy spring
    /// briefly contracts past the physical notch silhouette and exposes the
    /// real hardware cutout. Use a flat ease-out for `.closed`; keep the
    /// jelly spring for opening / popping.
    private var statusAnimation: Animation {
        switch viewModel.status {
        case .closed: return .smooth(duration: 0.38, extraBounce: 0)
        case .opened, .popping: return viewModel.animation
        }
    }

    @ViewBuilder
    private var content: some View {
        ZStack(alignment: .top) {
            if viewModel.status == .opened {
                openedContent
                    .animation(.smooth(duration: 0.32), value: viewModel.showSettings)
                    .animation(.smooth(duration: 0.32), value: viewModel.providerService.hasReadyProvider)
                    .animation(.smooth(duration: 0.32), value: viewModel.permissionsService.allGranted)
            }

            if viewModel.status != .opened {
                closedBar
                    .transition(.identity)
            }
        }
        .frame(
            width: contentCanvasSize.width,
            height: contentCanvasSize.height,
            alignment: .top
        )
    }

    /// Opened-state inner content. Switching among Onboard / Opened /
    /// Settings uses `.blurReplace` so the *contents* dissolve through a
    /// Gaussian blur cross-fade while the silhouette itself stays rock
    /// steady (the silhouette has its own animation driven by `status`).
    @ViewBuilder
    private var openedContent: some View {
        ZStack {
            if viewModel.showSettings {
                SettingsPanelView(
                    configService: viewModel.configService,
                    permissionsService: viewModel.permissionsService,
                    topSafeInset: viewModel.deviceNotchRect.height,
                    onClose: { viewModel.showSettings = false }
                )
                .frame(width: viewModel.notchOpenedSize.width,
                       height: viewModel.notchOpenedSize.height)
                .transition(.blurReplace)
            } else if !viewModel.configService.hasCompletedOnboarding,
                      !viewModel.permissionsService.allGranted {
                // First-run permission gate. Once `hasCompletedOnboarding`
                // flips, this branch never runs again — permission drops
                // post-onboarding surface as inline warnings on the
                // OpenedPanelView + a Permissions row in Settings.
                PermissionOnboardPanelView(
                    permissionsService: viewModel.permissionsService,
                    topSafeInset: viewModel.deviceNotchRect.height
                )
                .frame(width: viewModel.notchOpenedSize.width,
                       height: viewModel.notchOpenedSize.height)
                .transition(.blurReplace)
            } else if !viewModel.configService.hasCompletedOnboarding,
                      !viewModel.providerService.hasReadyProvider {
                // First-run provider sign-in. Same one-shot rule: post-
                // onboarding logout surfaces inline (disabled input +
                // banner) so users manage providers from Settings.
                OnboardPanelView(
                    providerService: viewModel.providerService,
                    topSafeInset: viewModel.deviceNotchRect.height
                )
                .frame(width: viewModel.notchOpenedSize.width,
                       height: viewModel.notchOpenedSize.height)
                .transition(.blurReplace)
            } else {
                OpenedPanelView(
                    viewModel: viewModel,
                    senseStore: viewModel.senseStore,
                    agentService: viewModel.agentService
                )
                .transition(.blurReplace)
            }
        }
        .task(id: shouldMarkOnboardingDone) {
            // Latch: when the Shell first sees both prerequisites
            // satisfied, persist `hasCompletedOnboarding=true` via RPC so
            // future sessions skip onboarding even if a permission or
            // provider drops. Idempotent — safe to fire on every change.
            if shouldMarkOnboardingDone {
                await viewModel.configService.markOnboardingCompleted()
            }
        }
    }

    /// Both onboard prerequisites first satisfied while config has
    /// loaded and the latch is still false — i.e., the moment to flip
    /// `hasCompletedOnboarding` for good.
    private var shouldMarkOnboardingDone: Bool {
        viewModel.configService.loaded
            && !viewModel.configService.hasCompletedOnboarding
            && viewModel.permissionsService.allGranted
            && viewModel.providerService.hasReadyProvider
    }

    private var closedBar: some View {
        ClosedBarView(
            senseStore: viewModel.senseStore,
            agentStatus: viewModel.agentService.status,
            deviceNotchRect: viewModel.deviceNotchRect
        )
        .frame(width: closedBarWidth, height: viewModel.deviceNotchRect.height)
    }

    private var contentCanvasSize: CGSize {
        CGSize(
            width: max(viewModel.notchOpenedSize.width, closedBarWidth),
            height: max(viewModel.notchOpenedSize.height, viewModel.deviceNotchRect.height)
        )
    }

    private var closedBarWidth: CGFloat {
        viewModel.deviceNotchRect.width + viewModel.deviceNotchRect.height * 2
    }

    private var shapeWidth: CGFloat {
        switch viewModel.status {
        case .opened: return viewModel.notchOpenedSize.width
        case .closed, .popping:
            return closedBarWidth
        }
    }

    private var shapeHeight: CGFloat {
        switch viewModel.status {
        case .opened: return viewModel.notchOpenedSize.height
        case .closed, .popping: return viewModel.deviceNotchRect.height
        }
    }

    /// Must match `NotchShape.notchCornerRadius` so layer-2 clipping aligns
    /// pixel-perfect with the silhouette's bottom curves.
    private var containerCornerRadius: CGFloat {
        switch viewModel.status {
        case .closed: return 8
        case .opened: return 32
        case .popping: return 8
        }
    }

    private var notchHorizontalOffset: CGFloat {
        let windowCenterX = viewModel.screenRect.width / 2
        let notchCenterX = viewModel.deviceNotchRect.midX - viewModel.screenRect.minX
        return notchCenterX - windowCenterX
    }
}

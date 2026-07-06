import SwiftUI

// MARK: - NotchView
//
// Top-level SwiftUI tree mounted into the NotchWindow. The silhouette and
// the inner content are bound to one morphing container so closed → opened
// reads as a single smooth expansion: the shape grows, the content reveals
// inside it (clipped), they share the same animation curve.
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

    private enum FloatingPanelCornerAnimationKey: Equatable {
        case attached
        case detached
        case edgeDock(NotchEdge)
    }

    private struct OpenedPanelAnimationKey: Equatable {
        let panelHeight: CGFloat
        let showSettings: Bool
        let showHistory: Bool
        let hasCompletedOnboarding: Bool
        let hasReadyProvider: Bool
        let onboardingPermissionsComplete: Bool
        let isAgentLoopActive: Bool
    }

    /// Reduce Motion gates the silhouette's height/tray easing so users who
    /// opted out of decorative animation get instant resizes instead of a
    /// 0.32s smooth interpolation. ThinkingView and the other motion-aware
    /// components honour the same setting; gating here keeps the outer
    /// container in lockstep with the inner content.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if viewModel.isAttachedTop {
            attachedTopBody
        } else {
            floatingPanelBody
        }
    }

    private var attachedTopBody: some View {
        ZStack(alignment: .top) {
            // Layer 0: drawer silhouette — a literal "drawer pulled out from
            // under the notch". Square top corners, rounded bottom matching
            // the main notch radius. Top extends UPWARD by `containerCornerRadius`
            // so it slides BEHIND the main notch's rounded bottom corners,
            // filling the curve area so there's no visible gap; the visible
            // top edge becomes the main notch's rounded bottom. Painted
            // slightly grayer than pure black (white overlay) so the drawer
            // band reads as a distinct surface even though it's continuous
            // with the main notch geometry.
            //
            // Must render BEFORE the main NotchShape so the silhouette covers
            // the drawer's hidden upper portion. A naïve `.offset(y: shapeHeight)`
            // alone leaves a notched gap at the corners where the main panel
            // curves inward but nothing fills the outer area.
            UnevenRoundedRectangle(
                bottomLeadingRadius: containerCornerRadius,
                bottomTrailingRadius: containerCornerRadius
            )
            .fill(Color.black)
            .overlay(
                UnevenRoundedRectangle(
                    bottomLeadingRadius: containerCornerRadius,
                    bottomTrailingRadius: containerCornerRadius
                )
                .fill(Color.white.opacity(0.06))
            )
            .frame(
                width: shapeWidth,
                height: trayHeight > 0 ? trayHeight + containerCornerRadius : 0
            )
            .offset(y: shapeHeight - containerCornerRadius)

            // Layer 1: main notch silhouette. Drawn AFTER the drawer so its
            // rounded bottom corners cover the drawer's square top, leaving
            // the drawer visible only as the band sliding out below — exactly
            // the "抽屉" effect the design calls for.
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

            // Layer 2.5: drawer rows. Sits on top of the drawer silhouette,
            // clipped to its rounded-bottom shape so row content can't bleed
            // past the curves at the bottom corners.
            openedTrayContent
                .clipShape(
                    .rect(
                        bottomLeadingRadius: containerCornerRadius,
                        bottomTrailingRadius: containerCornerRadius
                    )
                )
                .offset(y: shapeHeight)

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
        .animation(viewModel.animation, value: viewModel.status)
        // Height and opened-overlay swaps are keyed by the same derived
        // state for attached and detached. Detached is only a placement of
        // the opened notch, not a second animation model.
        .animation(reduceMotion ? nil : .notchHeight,
                   value: openedPanelAnimationKey)
        // Tray drawer slides in/out smoothly when notices appear / are
        // dismissed. Driving on `trayHeight` (a derived CGFloat) keeps the
        // background-silhouette growth and the content fade on the same
        // timeline.
        .animation(reduceMotion ? nil : .notchChrome,
                   value: trayHeight)
        .animation(reduceMotion ? nil : .notchChrome,
                   value: viewModel.tray.effectiveTrayExpanded)
    }

    private var floatingPanelBody: some View {
        ZStack(alignment: .top) {
            floatingPanelShape
                .fill(Color.black)
                .frame(
                    width: detachMorphPresentation.silhouetteSize.width,
                    height: detachMorphPresentation.silhouetteSize.height
                )
                .overlay(floatingPanelChromeOverlay)

            VStack(spacing: 0) {
                openedPanelContent
                    .clipShape(
                        .rect(
                            topLeadingRadius: detachMorphPresentation.contentClipCornerRadii.topLeading,
                            bottomLeadingRadius: trayHeight > 0 ? 0 : detachMorphPresentation.contentClipCornerRadii.bottomLeading,
                            bottomTrailingRadius: trayHeight > 0 ? 0 : detachMorphPresentation.contentClipCornerRadii.bottomTrailing,
                            topTrailingRadius: detachMorphPresentation.contentClipCornerRadii.topTrailing
                        )
                    )

                if trayHeight > 0 {
                    openedTrayContent
                }
            }
            .padding(.top, detachMorphPresentation.contentTopPadding)
            .clipShape(
                .rect(
                    topLeadingRadius: detachMorphPresentation.contentClipCornerRadii.topLeading,
                    bottomLeadingRadius: detachMorphPresentation.contentClipCornerRadii.bottomLeading,
                    bottomTrailingRadius: detachMorphPresentation.contentClipCornerRadii.bottomTrailing,
                    topTrailingRadius: detachMorphPresentation.contentClipCornerRadii.topTrailing
                )
            )
        }
        .frame(
            width: viewModel.detachedTotalSize.width,
            height: viewModel.detachedTotalSize.height,
            alignment: .top
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(reduceMotion ? nil : .smooth(duration: 0.32, extraBounce: 0),
                   value: viewModel.detachMorphPhase)
        .animation(reduceMotion ? nil : .smooth(duration: 0.36, extraBounce: 0),
                   value: floatingPanelCornerAnimationKey)
        .animation(reduceMotion ? nil : .notchHeight,
                   value: openedPanelAnimationKey)
        .animation(reduceMotion ? nil : .notchChrome,
                   value: trayHeight)
    }

    /// Tray drawer height. Zero outside the opened state; otherwise
    /// `notchTraySize.height` already accounts for "no notices" (returns
    /// 0) and the collapsed/expanded toggle.
    private var trayHeight: CGFloat {
        viewModel.status == .opened ? viewModel.notchTraySize.height : 0
    }

    private var floatingPanelShape: NotchSilhouetteShape {
        NotchSilhouetteShape(
            topLeadingRadius: detachMorphPresentation.shapeCornerRadii.topLeading,
            topTrailingRadius: detachMorphPresentation.shapeCornerRadii.topTrailing,
            bottomLeadingRadius: detachMorphPresentation.shapeCornerRadii.bottomLeading,
            bottomTrailingRadius: detachMorphPresentation.shapeCornerRadii.bottomTrailing,
            shoulderRadius: detachMorphPresentation.shoulderRadius
        )
    }

    private var floatingPanelCornerAnimationKey: FloatingPanelCornerAnimationKey {
        switch viewModel.placement {
        case .attachedTop:
            return .attached
        case .detached:
            guard case let .detached(frame) = viewModel.currentPlacement else {
                preconditionFailure("Detached placement must derive a detached current placement")
            }
            if let edge = NotchPlacementGeometry.touchingDockEdge(
                screenRect: viewModel.screenRect,
                frame: frame
            ) {
                return .edgeDock(edge)
            }
            return .detached
        case let .edgeDock(edge, _, _, _, _):
            return .edgeDock(edge)
        }
    }

    private var openedPanelAnimationKey: OpenedPanelAnimationKey {
        OpenedPanelAnimationKey(
            panelHeight: viewModel.notchOpenedSize.height,
            showSettings: viewModel.showSettings,
            showHistory: viewModel.showHistory,
            hasCompletedOnboarding: viewModel.configService.hasCompletedOnboarding,
            hasReadyProvider: viewModel.providerService.hasReadyProvider,
            onboardingPermissionsComplete: viewModel.permissionsService.onboardingPermissionsComplete,
            isAgentLoopActive: viewModel.isAgentLoopActive
        )
    }

    @ViewBuilder
    private var floatingPanelChromeOverlay: some View {
        if detachMorphPresentation.chromeOverlayOpacity > 0 {
            floatingPanelShape
                .fill(Color.white.opacity(detachMorphPresentation.chromeOverlayOpacity))
                .frame(
                    width: detachMorphPresentation.silhouetteSize.width,
                    height: detachMorphPresentation.silhouetteSize.height
                )
        }
    }

    private var detachMorphPresentation: DetachMorphPresentation {
        DetachMorphPresentation.make(
            phase: reduceMotion ? .idle : viewModel.detachMorphPhase,
            placement: viewModel.currentPlacement,
            screenRect: viewModel.screenRect,
            finalSize: viewModel.detachedTotalSize,
            sourceHeight: viewModel.notchOpenedTotalSize.height,
            sourceBottomCornerRadius: containerCornerRadius,
            targetCornerRadius: viewModel.detachedCornerRadius,
            targetTopPadding: viewModel.detachedTopPadding
        )
    }

    @ViewBuilder
    private var content: some View {
        ZStack(alignment: .top) {
            if viewModel.status == .opened {
                openedPanelContent
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

    private var openedPanelContent: some View {
        openedContent
            .frame(
                width: viewModel.notchOpenedSize.width,
                height: viewModel.notchOpenedSize.height,
                alignment: .top
            )
            .animation(reduceMotion ? nil : .notchHeight, value: openedPanelAnimationKey)
    }

    private var openedTrayContent: some View {
        SystemTrayView(viewModel: viewModel)
            .frame(
                width: viewModel.notchOpenedSize.width,
                height: trayHeight,
                alignment: .top
            )
    }

    /// Opened-state inner content. Switching among Onboard / Opened /
    /// Settings uses `.blurReplace` so the *contents* dissolve through a
    /// Gaussian blur cross-fade while the silhouette itself stays rock
    /// steady (the silhouette has its own animation driven by `status`).
    @ViewBuilder
    private var openedContent: some View {
        ZStack(alignment: .topLeading) {
            if viewModel.showHistory {
                SessionHistoryPanelView(
                    viewModel: viewModel,
                    topSafeInset: viewModel.deviceNotchRect.height,
                    onClose: { viewModel.showHistory = false }
                )
                .modifier(HistoryMeasurement(viewModel: viewModel))
                .transition(.blurReplace)
            } else if viewModel.showSettings {
                SettingsPanelView(
                    configService: viewModel.configService,
                    providerService: viewModel.providerService,
                    mcpService: viewModel.mcpService,
                    permissionsService: viewModel.permissionsService,
                    topSafeInset: viewModel.deviceNotchRect.height,
                    onClose: { viewModel.showSettings = false }
                )
                .modifier(SettingsMeasurement(viewModel: viewModel))
                .transition(.blurReplace)
            } else if !viewModel.configService.hasCompletedOnboarding,
                      !viewModel.permissionsService.onboardingPermissionsComplete {
                // First-run permission gate. Once `hasCompletedOnboarding`
                // flips, this branch never runs again — permission drops
                // post-onboarding surface as inline warnings on the
                // OpenedPanelView + a Permissions row in Settings.
                PermissionOnboardPanelView(
                    permissionsService: viewModel.permissionsService,
                    topSafeInset: viewModel.deviceNotchRect.height
                )
                .modifier(OnboardingMeasurement(viewModel: viewModel))
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
                .modifier(OnboardingMeasurement(viewModel: viewModel))
                .transition(.blurReplace)
            } else {
                OpenedPanelView(viewModel: viewModel)
                .transition(.blurReplace)
            }
        }
        .task(id: viewModel.shouldMarkOnboardingDone) {
            // Latch: when the Shell first sees both prerequisites
            // satisfied, persist `hasCompletedOnboarding=true` via RPC so
            // future sessions skip onboarding even if a permission or
            // provider drops. Idempotent — safe to fire on every change.
            await viewModel.markOnboardingCompletedIfNeeded()
        }
        .task(id: viewModel.providerReadyKey) {
            // First-auth selection bootstrap: if the user hasn't explicitly
            // chosen a provider yet, `effectiveSelection` falls back to the
            // catalog's first entry (e.g. codex) — which can leave the
            // composer pointed at an unauthenticated provider after the
            // user just authed a different one in onboarding. When the
            // currently-defaulted provider isn't ready but some other
            // provider is, persist a selection to the ready one. Only
            // fires while `selection == nil` so explicit user picks are
            // never overridden.
            await viewModel.reconcileSelectionIfNeeded()
        }
    }

    private var closedBar: some View {
        ClosedBarView(
            senseStore: viewModel.senseStore,
            agentStatus: viewModel.agentService.status,
            deviceNotchRect: viewModel.deviceNotchRect,
            activeToolName: viewModel.agentService.activeToolName
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

// MARK: - Onboarding measurement
//
// Width-pin + vertical fixedSize collapses the onboarding panel to its
// intrinsic height (the inner `.frame(maxHeight: .infinity)` + Spacer
// otherwise expand to fill any offered height). The measured value flows
// up to `viewModel.measurements.onboardingContentHeight`, which `notchOpenedSize` then
// uses so the silhouette hugs the cards. The tray drawer sits at
// `offset(y: shapeHeight)` below this — natural panel height means the
// drawer extends downward without ever clipping the cards.
private struct OnboardingMeasurement: ViewModifier {
    let viewModel: NotchViewModel

    func body(content: Content) -> some View {
        content
            .frame(width: viewModel.notchOpenedSize.width)
            .fixedSize(horizontal: false, vertical: true)
            // `onHeightChange` already rounds to integer points and dedupes
            // (see HeightReporting.swift for why — sub-pixel jitter from
            // SwiftUI's per-frame re-layout during the tray's expand
            // animation must not propagate into `onboardingContentHeight`,
            // since `notchOpenedSize.height` is animated and even a 0.5pt
            // drift would visibly nudge the panel taller every drawer
            // toggle). Real content changes are always >> 1pt and still
            // flow through.
            .onHeightChange { rounded in
                viewModel.measurements.onboardingContentHeight = rounded
            }
    }
}

// MARK: - Settings measurement
//
// Mirror of OnboardingMeasurement for the Settings panel. Width is pinned
// to the open-state panel width; vertical `fixedSize` collapses the inner
// VStack to its intrinsic height (Spacers and `maxHeight: .infinity`
// otherwise expand to fill any offered height). The measured value flows
// up to `viewModel.measurements.settingsContentHeight`, and `notchOpenedSize` clamps it
// into [compactMin, notchOpenedMaxHeight] — picker sub-pages whose lists
// exceed the ceiling let their inner ScrollView take over.
private struct SettingsMeasurement: ViewModifier {
    let viewModel: NotchViewModel

    func body(content: Content) -> some View {
        content
            .frame(width: viewModel.notchOpenedSize.width)
            .fixedSize(horizontal: false, vertical: true)
            // `onHeightChange` rounds (suppressing sub-pixel jitter from
            // per-frame relayout while sub-page transitions animate) and
            // drops non-positive readings, so `markSettingsMeasured` here
            // never actually sees 0 — same as before this modifier existed
            // locally (see HeightReporting.swift doc comment).
            .onHeightChange { rounded in
                viewModel.measurements.markSettingsMeasured(height: rounded)
            }
    }
}

// MARK: - History measurement
//
// Same shape as SettingsMeasurement. The history list owns an inner
// ScrollView, so vertical `fixedSize` collapses the panel to its intrinsic
// height (header + scroll content); `notchOpenedSize` clamps it into
// [compactMin, notchOpenedMaxHeight] so long lists scroll inside the panel.
private struct HistoryMeasurement: ViewModifier {
    let viewModel: NotchViewModel

    func body(content: Content) -> some View {
        content
            .frame(width: viewModel.notchOpenedSize.width)
            .fixedSize(horizontal: false, vertical: true)
            .onHeightChange { rounded in
                viewModel.measurements.markHistoryMeasured(height: rounded)
            }
    }
}

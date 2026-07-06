import RPCSchema
import SwiftUI

// MARK: - OpenedPanelView
//
// The opened notch panel. Composes three regions:
//
//   ┌──────────┐ ╲╱ ┌──────────┐  ← NotchHeaderStripsView (overlays top band)
//   │                            │
//   │   AgentConversationView    │  ← history + session error banners
//   │                            │
//   │   LiveComposerSection      │  ← pinned-bottom composer
//   └────────────────────────────┘
struct OpenedPanelView: View {
    let viewModel: NotchViewModel

    private let edgePadding: CGFloat = 16

    /// Hardware notch height — content inside this top band sits behind
    /// the cutout and must be reserved as a top safe inset.
    private var topSafeInset: CGFloat {
        viewModel.deviceNotchRect.height
    }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                AgentConversationView(
                    viewModel: viewModel,
                    agentService: viewModel.agentService
                )
                bottomSection
            }
            .padding(.top, topSafeInset)
            .padding(.horizontal, edgePadding)
            .padding(.bottom, edgePadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            NotchHeaderStripsView(viewModel: viewModel)
        }
        .frame(width: viewModel.notchOpenedSize.width,
               height: viewModel.notchOpenedSize.height)
        .animation(.notchChrome, value: viewModel.isAgentLoopActive)
    }

    @ViewBuilder
    private var bottomSection: some View {
        BottomSectionPager(
            viewModel: viewModel,
            request: viewModel.permissionApprovalService?.pendingRequest,
            allow: { viewModel.allowPendingPermission() },
            deny: { viewModel.denyPendingPermission() }
        )
    }
}

private struct BottomSectionPager: View {
    let viewModel: NotchViewModel
    let request: PermissionRequestApprovalParams?
    let allow: () -> Void
    let deny: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var composerHeight: CGFloat = 0
    @State private var approvalHeight: CGFloat = 0
    @State private var model = ApprovalPagerModel()

    private var pageWidth: CGFloat {
        viewModel.notchOpenedSize.width - 32
    }

    private var pageHeight: CGFloat {
        model.displayedRequest == nil ? composerHeight : max(composerHeight, approvalHeight)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            composerPage
                .offset(x: model.showingApproval ? -pageWidth : 0)
            approvalPage
                .offset(x: model.showingApproval ? 0 : pageWidth)
        }
        .frame(width: pageWidth, alignment: .topLeading)
        .clipped()
        .onChange(of: pageHeight) { _, h in
            viewModel.measurements.composerContentHeight = h
        }
        .onAppear {
            model.onAppear(request: request)
            viewModel.measurements.composerContentHeight = pageHeight
        }
        .onChange(of: request) { _, nextRequest in
            syncDisplayedRequest(nextRequest)
        }
    }

    private var composerPage: some View {
        LiveComposerSection(
            viewModel: viewModel,
            onHeightChange: { h in
                composerHeight = h
                viewModel.measurements.composerContentHeight = pageHeight
            }
        )
        .frame(width: pageWidth, alignment: .top)
        .accessibilityHidden(model.showingApproval)
        .allowsHitTesting(!model.showingApproval)
    }

    @ViewBuilder
    private var approvalPage: some View {
        if let displayedRequest = model.displayedRequest {
            PermissionApprovalSection(
                request: displayedRequest,
                allow: allow,
                deny: deny,
                onHeightChange: { h in
                    approvalHeight = h
                    viewModel.measurements.composerContentHeight = pageHeight
                }
            )
            .frame(width: pageWidth, alignment: .top)
            .accessibilityHidden(!model.showingApproval)
            .allowsHitTesting(model.showingApproval)
        }
    }

    /// Drives `ApprovalPagerModel`'s state machine from the view side:
    /// the model owns *what* displayedRequest/showingApproval should be,
    /// this owns *how* the transition is animated. Reduce Motion completes
    /// the dismissal synchronously; otherwise `withAnimation`'s
    /// `.logicallyComplete` completion callback clears the displayed
    /// request only once the slide-out has actually finished (replacing
    /// the old `Task.sleep(for: .milliseconds(280))` hack that guessed at
    /// `.notchChrome`'s duration).
    private func syncDisplayedRequest(_ nextRequest: PermissionRequestApprovalParams?) {
        if reduceMotion {
            if let token = model.beginSync(request: nextRequest) {
                approvalHeight = 0
                model.completeDismissal(token: token)
                viewModel.measurements.composerContentHeight = pageHeight
            }
            return
        }

        var dismissalToken: Int?
        withAnimation(.notchChrome, completionCriteria: .logicallyComplete) {
            dismissalToken = model.beginSync(request: nextRequest)
        } completion: {
            guard let dismissalToken else { return }
            model.completeDismissal(token: dismissalToken)
            approvalHeight = 0
            viewModel.measurements.composerContentHeight = pageHeight
        }
    }
}

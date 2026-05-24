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
        let service = viewModel.permissionApprovalService
        BottomSectionPager(
            viewModel: viewModel,
            request: service?.pendingRequest,
            allow: {
                guard let service else {
                    preconditionFailure("permission approval service is required for approval actions")
                }
                service.allowPendingRequest()
            },
            deny: {
                guard let service else {
                    preconditionFailure("permission approval service is required for approval actions")
                }
                service.denyPendingRequest()
            }
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
    @State private var displayedRequest: PermissionRequestApprovalParams?
    @State private var showingApproval: Bool = false
    @State private var dismissalTask: Task<Void, Never>?

    private var pageWidth: CGFloat {
        viewModel.notchOpenedSize.width - 32
    }

    private var pageHeight: CGFloat {
        displayedRequest == nil ? composerHeight : max(composerHeight, approvalHeight)
    }

    private var measuredPageHeight: CGFloat? {
        pageHeight > 0 ? pageHeight : nil
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            composerPage
                .offset(x: showingApproval ? -pageWidth : 0)
            approvalPage
                .offset(x: showingApproval ? 0 : pageWidth)
        }
        .frame(width: pageWidth, height: measuredPageHeight, alignment: .topLeading)
        .clipped()
        .onChange(of: pageHeight) { _, h in
            viewModel.composerContentHeight = h
        }
        .onAppear {
            if let request {
                displayedRequest = request
                showingApproval = true
            }
            viewModel.composerContentHeight = pageHeight
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
                viewModel.composerContentHeight = pageHeight
            }
        )
        .frame(width: pageWidth, height: measuredPageHeight, alignment: .top)
        .accessibilityHidden(showingApproval)
        .allowsHitTesting(!showingApproval)
    }

    @ViewBuilder
    private var approvalPage: some View {
        if let displayedRequest {
            PermissionApprovalSection(
                request: displayedRequest,
                allow: allow,
                deny: deny,
                onHeightChange: { h in
                    approvalHeight = h
                    viewModel.composerContentHeight = pageHeight
                }
            )
            .frame(width: pageWidth, height: measuredPageHeight, alignment: .top)
            .accessibilityHidden(!showingApproval)
            .allowsHitTesting(showingApproval)
        } else {
            Color.clear
                .frame(width: pageWidth, height: measuredPageHeight)
        }
    }

    private func syncDisplayedRequest(_ nextRequest: PermissionRequestApprovalParams?) {
        dismissalTask?.cancel()
        dismissalTask = nil

        if let nextRequest {
            displayedRequest = nextRequest
            runPageAnimation {
                showingApproval = true
            }
            return
        }

        runPageAnimation {
            showingApproval = false
        }
        let dismissedRequest = displayedRequest
        let task = Task { @MainActor in
            guard !reduceMotion else {
                guard displayedRequest == dismissedRequest, !showingApproval else { return }
                displayedRequest = nil
                approvalHeight = 0
                viewModel.composerContentHeight = pageHeight
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(280))
            } catch {
                return
            }
            guard displayedRequest == dismissedRequest, !showingApproval else { return }
            displayedRequest = nil
            approvalHeight = 0
            viewModel.composerContentHeight = pageHeight
        }
        dismissalTask = task
    }

    private func runPageAnimation(_ updates: @escaping () -> Void) {
        if reduceMotion {
            updates()
        } else {
            withAnimation(.notchChrome, updates)
        }
    }
}

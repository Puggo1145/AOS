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
                LiveComposerSection(
                    viewModel: viewModel
                )
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
}

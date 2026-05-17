import SwiftUI
import AOSOSSenseKit

// MARK: - ClosedBarView
//
// Per notch-ui.md "三态布局详细规格 → closed":
//   ┌────────────┬────────────────┬────────────┐
//   │  app icon  │  device notch  │  emoji txt │
//   │  (h × h)   │  (notchW × h)  │  (h × h)   │
//   └────────────┴────────────────┴────────────┘
// The middle is intentionally pure black so it visually merges with the
// physical notch silhouette.

struct ClosedBarView: View {
    let senseStore: SenseStore
    let agentStatus: AgentStatus
    let deviceNotchRect: CGRect
    /// Name of the most recent in-flight tool call (any family). When set,
    /// the right-side status slot swaps the resting/working emoji for the
    /// tool's SF Symbol — see `AgentStatusIndicator`. `nil` falls back to
    /// the emoji glyph.
    let activeToolName: String?

    var body: some View {
        let h = deviceNotchRect.height
        // No per-cell black backgrounds: the underlying NotchShape silhouette
        // covers the whole closed bar (closedBarWidth × h) with rounded-bottom
        // corners and concave shoulders. Drawing flat-black rectangles here
        // would override that shape and make the four corners look square.
        HStack(spacing: 0) {
            AppIconView(image: senseStore.context.app?.icon)
                .frame(width: h, height: h)
            Color.clear
                .frame(width: deviceNotchRect.width, height: h)
            AgentStatusIndicator(status: agentStatus, activeToolName: activeToolName)
                .frame(width: h, height: h)
        }
        .frame(width: deviceNotchRect.width + h * 2, height: h)
    }
}

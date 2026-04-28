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
    /// Non-nil while the agent is running a `computer_use_*` tool against
    /// some target app. The closed bar overlays a small pulsing icon of the
    /// target onto the right edge of the device-notch band — leaving the
    /// senseStore-frontmost icon on the left untouched (that one is the
    /// user's current foreground; the overlay is what AOS is doing in the
    /// background).
    let backgroundOp: BackgroundOperation?
    /// Name of the most recent in-flight tool call (any family). When set,
    /// the right-side status slot swaps the resting/working emoji for the
    /// tool's SF Symbol — see `AgentStatusIndicator`. `nil` falls back to
    /// the emoji glyph.
    let activeToolName: String?

    @State private var pulse: Bool = false

    var body: some View {
        let h = deviceNotchRect.height
        // No per-cell black backgrounds: the underlying NotchShape silhouette
        // covers the whole closed bar (closedBarWidth × h) with rounded-bottom
        // corners and concave shoulders. Drawing flat-black rectangles here
        // would override that shape and make the four corners look square.
        HStack(spacing: 0) {
            AppIconView(image: senseStore.context.app?.icon)
                .frame(width: h, height: h)
            // Black band covering the physical notch silhouette. We overlay
            // the background-op indicator inside this band (right-aligned) so
            // it floats just left of the agent-status emoji without crowding
            // the foreground app icon on the far left.
            ZStack(alignment: .trailing) {
                Color.clear
                if let op = backgroundOp {
                    BackgroundOpBadge(op: op, height: h, pulse: pulse)
                        .padding(.trailing, 4)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .frame(width: deviceNotchRect.width, height: h)
            AgentStatusIndicator(status: agentStatus, activeToolName: activeToolName)
                .frame(width: h, height: h)
        }
        .frame(width: deviceNotchRect.width + h * 2, height: h)
        .animation(.smooth(duration: 0.32, extraBounce: 0), value: backgroundOp)
        .onAppear { pulse = true }
    }
}

// MARK: - BackgroundOpBadge
//
// Tiny app icon (≈ 60% of the closed-bar height) with a slow opacity pulse
// to telegraph "live activity in the background." We deliberately use the
// running app's NSImage rather than a generic glyph so the user can identify
// at a glance which app the agent is operating — same recognition cue the
// foreground icon on the left provides.

private struct BackgroundOpBadge: View {
    let op: BackgroundOperation
    let height: CGFloat
    let pulse: Bool

    var body: some View {
        let size = max(12, height * 0.58)
        Group {
            if let icon = op.icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
            } else {
                // Fallback glyph when the target NSImage was not available
                // (process exited mid-call). Still surface activity.
                Image(systemName: "gearshape.2.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .frame(width: size, height: size)
        .opacity(pulse ? 0.55 : 1.0)
        .animation(
            .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
            value: pulse
        )
        .accessibilityLabel(Text(accessibilityLabel))
        .help(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        if let name = op.appName { return "\(op.verb) \(name)" }
        return op.verb
    }
}

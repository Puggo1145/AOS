import SwiftUI

// MARK: - ContextUsageRing
//
// Live composer's "how full is the context window" indicator. A thin circular
// ring + a "12.8K/256K" label, both fed by the most recent `ui.usage`
// notification. The sidecar emits one of those frames per LLM round (NOT per
// streamed token) so the ring updates as messages grow, not on every keystroke.
//
// Hover surfaces an elegant tooltip with the per-bucket breakdown (input,
// cache read, cache write, output, total) so a curious user can audit the
// numbers without leaving the notch.

struct ContextUsageRing: View {
    let usage: ContextUsageSnapshot

    @State private var isHovering: Bool = false
    @State private var showTooltip: Bool = false
    @State private var hoverTask: Task<Void, Never>?

    /// Strong ease-out (cubic-bezier(0.23, 1, 0.32, 1)) at 160ms — the
    /// curve recommended for popovers/tooltips. The standard SwiftUI
    /// `.smooth` and `.notchChrome` are closer to ease-in-out and feel
    /// sluggish on a 14pt chip.
    private static let tooltipShow: Animation =
        .timingCurve(0.23, 1, 0.32, 1, duration: 0.16)
    /// Exit is faster than entry (asymmetric): the system is *responding*,
    /// not soliciting attention, so it should snap away.
    private static let tooltipHide: Animation =
        .timingCurve(0.4, 0, 1, 1, duration: 0.11)
    /// Short hover delay before the tooltip appears. Prevents the chip
    /// from flickering open when the cursor merely passes over the ring
    /// on its way to the send button.
    private static let hoverDelayNanos: UInt64 = 220_000_000

    var body: some View {
        ring
            .contentShape(Rectangle())
            .onHover { hovering in handleHover(hovering) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(accessibilityDescription))
            .overlay(alignment: .bottomTrailing) {
                if showTooltip {
                    tooltip
                        .fixedSize()
                        // Float above the function row without pushing
                        // siblings. Offset upward so the tooltip doesn't
                        // cover the send button or clip against the
                        // composer's padding.
                        .offset(x: -8, y: -36)
                        // Anchored scale: the tooltip pops from its
                        // bottom-trailing corner, which is the edge
                        // closest to the ring trigger. Without an anchor
                        // the default centre-scale reads as if the chip
                        // appeared from nowhere.
                        .transition(
                            .scale(scale: 0.94, anchor: .bottomTrailing)
                                .combined(with: .opacity)
                        )
                        .allowsHitTesting(false)
                        .zIndex(1)
                }
            }
            .animation(.notchChrome, value: usage.fillRatio)
    }

    private func handleHover(_ hovering: Bool) {
        isHovering = hovering
        hoverTask?.cancel()
        if hovering {
            hoverTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: Self.hoverDelayNanos)
                guard !Task.isCancelled, isHovering else { return }
                withAnimation(Self.tooltipShow) { showTooltip = true }
            }
        } else {
            withAnimation(Self.tooltipHide) { showTooltip = false }
        }
    }

    private var ring: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.18), lineWidth: 2)
                .frame(width: 14, height: 14)
            Circle()
                .trim(from: 0, to: usage.fillRatio)
                .stroke(
                    ringColor,
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
                .frame(width: 14, height: 14)
                // Start the trim at 12 o'clock — the conventional reading for
                // a progress ring. Without this it starts at 3 o'clock.
                .rotationEffect(.degrees(-90))
        }
    }

    /// Color shifts as the window fills: passive white under 75%, amber
    /// 75–90%, red above 90%. The ring is a glanceable signal — only loud
    /// when the user actually risks an overflow.
    private var ringColor: Color {
        switch usage.fillRatio {
        case ..<0.75: return Color.white.opacity(0.85)
        case ..<0.90: return Color(red: 1.0, green: 0.78, blue: 0.35) // amber
        default:      return Color(red: 1.0, green: 0.45, blue: 0.42) // red
        }
    }

    private var tooltip: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(percentString) used")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
            Text("\(Self.formatTokens(usage.usedTokens)) / \(Self.formatTokens(usage.contextWindow)) used")
                .font(.system(size: 10.5, weight: .regular, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            // Glassy chip that reads on the black silhouette without
            // washing out the chrome behind it.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 4)
        )
    }

    private var percentString: String {
        let pct = usage.fillRatio * 100
        if pct < 10 {
            return String(format: "%.1f%%", pct)
        } else {
            return String(format: "%.0f%%", pct.rounded())
        }
    }

    private var accessibilityDescription: String {
        "Context usage: \(percentString), \(Self.formatTokens(usage.usedTokens)) of \(Self.formatTokens(usage.contextWindow))"
    }

    // MARK: - Formatting

    /// Compact label for the inline ring: matches the pattern "12.8K / 256K".
    /// One decimal under 100K, integer above so the chip stays narrow at large
    /// context windows.
    static func formatTokens(_ n: Int) -> String {
        if n < 1000 {
            return "\(n)"
        }
        let k = Double(n) / 1000.0
        if k < 100 {
            // 1K → 1.0K → trim to 1K; 12.83K → 12.8K
            let rounded = (k * 10).rounded() / 10
            if rounded.truncatingRemainder(dividingBy: 1) == 0 {
                return "\(Int(rounded))K"
            }
            return String(format: "%.1fK", rounded)
        }
        return "\(Int(k.rounded()))K"
    }
}

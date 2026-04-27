import SwiftUI

// MARK: - ThinkingView
//
// Per-turn reasoning-trace affordance. Two visual modes driven by the turn's
// `thinkingStartedAt` / `thinkingEndedAt` pair carried on `ConversationTurn`:
//
//   1. Streaming (started, no end yet): a *single-line* live tail of the
//      thinking text. To keep the per-frame work bounded as the trace grows
//      into the multi-KB range, we render only the trailing
//      `streamingTailLimit` characters as soft-wrapped multi-line text,
//      measure its natural height, and offset it upward inside a fixed
//      one-line clipped window so only the last visible row is on screen.
//      This makes both hard newlines AND soft wrapping push older rows up,
//      instead of truncating the first row with "…". The visible row
//      carries a left-to-right shimmer (suppressed under Reduce Motion).
//      The full trace is preserved on the model and shown verbatim in the
//      settled view.
//   2. Settled (end timestamp present): collapses to "Thought for X seconds"
//      with a chevron toggle. Expanded reveals the full trace inside a
//      content-hugging container capped at `expandedMaxHeight`.
//
// The thinking string itself is owned by `AgentService.ConversationTurn` and
// updated from `ui.thinking` notifications. The lifecycle (`startedAt` /
// `endedAt`) is driven exclusively by the explicit `kind: "delta" | "end"`
// channel — this view never infers either transition. It is purely
// presentational.

struct ThinkingView: View {
    let thinking: String
    let startedAt: Date?
    let endedAt: Date?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded: Bool = false
    @State private var measuredHeight: CGFloat = 0
    /// Natural height of the expanded trace text (including its padding).
    /// Drives the expanded slot's `frame(height:)` so short traces hug
    /// their content instead of always reserving `expandedMaxHeight`.
    @State private var expandedContentHeight: CGFloat = 0

    private static let fontSize: CGFloat = 12
    /// Tightly matches the rendered line height of the chosen monospaced
    /// font at `fontSize`. Used both as the clip window height and as the
    /// "one row" baseline when computing the upward scroll offset.
    private static let lineHeight: CGFloat = 16
    /// Cap on the expanded trace container. Past this the inner ScrollView
    /// takes over and the user scrolls inside the fixed-height slot.
    private static let expandedMaxHeight: CGFloat = 160
    /// Streaming view only renders the tail of the trace — only one row is
    /// visible through the clip, and TimelineView re-evaluates the body on
    /// every animation tick. Capping the rendered substring keeps the
    /// shimmer cheap as the full trace grows into the multi-KB range. The
    /// trailing slice keeps wrap-edge stability comfortable; the full trace
    /// is still preserved on the model and shown verbatim when expanded.
    private static let streamingTailLimit: Int = 800

    private var isStreaming: Bool { startedAt != nil && endedAt == nil }
    private var isSettled: Bool { startedAt != nil && endedAt != nil }

    var body: some View {
        if isStreaming {
            streamingTail
        } else if isSettled {
            settled
        } else {
            EmptyView()
        }
    }

    // MARK: Streaming tail

    /// Render the trailing `streamingTailLimit` characters of the thinking
    /// string as soft-wrapped, unlimited-line shimmering text and offset it
    /// upward by (measuredHeight - lineHeight) so only the last row is
    /// visible inside a 1-line clip. As the trace grows past one row the
    /// offset increases and older rows slide out the top — animated by
    /// `.animation(_:value:)` keyed on the measured height (suppressed
    /// under Reduce Motion).
    private var streamingTail: some View {
        let offsetY = -max(0, measuredHeight - Self.lineHeight)
        let tail = Self.tail(of: thinking, limit: Self.streamingTailLimit)
        return ShimmerText(
            text: tail.isEmpty ? " " : tail,
            fontSize: Self.fontSize,
            reduceMotion: reduceMotion
        )
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: ThinkingHeightKey.self, value: geo.size.height)
                }
            )
            .offset(y: offsetY)
            // Reduce Motion suppresses the upward-slide easing — the offset
            // still applies (so only the last row is visible), but it snaps
            // instead of animating.
            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: measuredHeight)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: Self.lineHeight, alignment: .topLeading)
            .clipped()
            .onPreferenceChange(ThinkingHeightKey.self) { h in
                measuredHeight = h
            }
    }

    /// Trailing slice of the thinking trace for streaming render. Uses
    /// `limitedBy:` to avoid an O(N) `count` walk per animation tick — when
    /// the trace is shorter than `limit` the offset clamps to `startIndex`
    /// and the whole string is returned.
    private static func tail(of s: String, limit: Int) -> String {
        guard limit > 0, !s.isEmpty else { return s }
        let start = s.index(s.endIndex, offsetBy: -limit, limitedBy: s.startIndex) ?? s.startIndex
        return String(s[start..<s.endIndex])
    }

    // MARK: Settled

    private var elapsedSeconds: Int {
        guard let s = startedAt, let e = endedAt else { return 0 }
        return max(1, Int(e.timeIntervalSince(s).rounded()))
    }

    private var settled: some View {
        let elapsedLabel = "Thought for \(elapsedSeconds) second\(elapsedSeconds == 1 ? "" : "s")"
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                if reduceMotion {
                    expanded.toggle()
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(elapsedLabel)
                        .font(.system(size: Self.fontSize, weight: .regular, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: expanded)
                }
            }
            .buttonStyle(.plain)
            // Preserve the visible elapsed time as the accessible name; the
            // expand/collapse affordance is the secondary action and goes in
            // the hint so VoiceOver users still hear "Thought for X seconds".
            .accessibilityLabel(Text(elapsedLabel))
            .accessibilityHint(Text(expanded ? "Hides reasoning trace" : "Shows reasoning trace"))

            // Single fixed container for the expanded trace. Collapsed it
            // animates its frame height to 0 and clips; expanded it grows
            // to `expandedMaxHeight`. Keeping the container in the tree
            // (rather than `if expanded { ... }` with a transition) means
            // the surrounding layout sees a continuous height interpolation
            // — the visual effect is "the content reveals from inside a
            // fixed slot" instead of a separate view sliding+fading in.
            ScrollView {
                Text(thinking)
                    .font(.system(size: Self.fontSize, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: ExpandedContentHeightKey.self,
                                value: geo.size.height
                            )
                        }
                    )
            }
            .frame(height: expanded ? min(expandedContentHeight, Self.expandedMaxHeight) : 0)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(expanded ? 0.04 : 0.0))
            )
            .clipped()
            .onPreferenceChange(ExpandedContentHeightKey.self) { h in
                expandedContentHeight = h
            }
        }
    }
}

// MARK: - ShimmerText
//
// Wrapping multi-line text with a left-to-right white→bright→white sweep on
// top of a dimmed base. The sweep band spans the full bounding box height,
// so when the parent only shows the last visible row through a clip+offset
// the shimmer still reads as a band travelling across that row.

private struct ShimmerText: View {
    let text: String
    let fontSize: CGFloat
    let reduceMotion: Bool

    var body: some View {
        // Reduce Motion gate: the moving band is purely decorative. Render a
        // static, slightly brighter copy of the text so the affordance still
        // reads as "live thinking" without a continuous animation. Skipping
        // TimelineView also avoids the per-frame body re-evaluation.
        if reduceMotion {
            Text(text)
                .font(.system(size: fontSize, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.75))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            animated
        }
    }

    private var animated: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let phase = (t.truncatingRemainder(dividingBy: 1.6)) / 1.6

            ZStack(alignment: .topLeading) {
                // Base: dim text always visible, full-width wrapping.
                Text(text)
                    .font(.system(size: fontSize, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.40))
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Overlay: brighter copy of the same text masked by a moving
                // narrow band. The mask's gradient is L→R across the full
                // bounding box; vertically the band extends across every
                // wrapped row, which is exactly what we want — the visible
                // row inherits the sweep at the right horizontal phase.
                Text(text)
                    .font(.system(size: fontSize, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.95))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .mask(
                        GeometryReader { geo in
                            let width = max(geo.size.width, 1)
                            let bandWidth = max(60, width * 0.35)
                            let travel = width + bandWidth
                            let x = -bandWidth + travel * phase
                            LinearGradient(
                                colors: [
                                    .white.opacity(0.0),
                                    .white,
                                    .white.opacity(0.0),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: bandWidth, height: geo.size.height)
                            .offset(x: x)
                        }
                    )
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Height preference

private struct ThinkingHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ExpandedContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

import SwiftUI

// MARK: - CompactBlockView
//
// Full-width divider block rendered inside the conversation history when
// a context-compact pass runs. The block has three visual zones in one
// row:
//
//   ── ── ──   compacting context   ── ── ──
//
// The two flanking lines hairlines that span to the panel edges; the
// center carries a label. While `status == .running`, a soft white→clear
// gradient sweeps left→right across the label so the user sees the
// summarization is in progress (idle blocks read static).
//
// Once the lifecycle reaches `.done`, the label flips to "Context
// compacted" (optionally with the folded turn count) and the shimmer
// stops. The block stays in history as a milestone.

struct CompactBlockView: View {
    let event: CompactEvent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            line
            label
            line
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
    }

    // MARK: - Pieces

    private var line: some View {
        Rectangle()
            .fill(Color.white.opacity(0.18))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }

    private var label: some View {
        Group {
            switch event.status {
            case .running:
                shimmeringLabel(text: "Compacting context")
            case .done:
                Text(doneLabel)
                    .notchFont(size: 11, weight: .medium)
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    /// "Compacting context" with a left→right shimmer sweep. The base
    /// glyphs are drawn at a muted alpha; a brighter overlay copy of
    /// the same glyphs is masked by a fixed-shape `clear → white →
    /// clear` band that we slide across the text via `.offset`.
    ///
    /// The previous implementation animated the gradient's stops in
    /// unit-space and clamped them to [0, 1] when the band was supposed
    /// to be off-screen. Clamping pinned the bright stop to the edge of
    /// the gradient, which read as "the highlight pops in from nowhere
    /// at the left, sweeps, then sticks to the right edge." Sliding a
    /// fixed-width band whose travel range is `[-bandWidth, textWidth]`
    /// fixes this — the band is fully off-screen at both endpoints, so
    /// entry and exit are smooth.
    ///
    /// `TimelineView(.animation)` (vs. `.repeatForever`) keeps the
    /// animation phase in lockstep with the display refresh and avoids
    /// the SwiftUI bug where a forever-repeat inside a ForEach gets
    /// stuck after parent state updates.
    @ViewBuilder
    private func shimmeringLabel(text: String) -> some View {
        let base = Text(text)
            .notchFont(size: 11, weight: .medium)
        if reduceMotion {
            base.foregroundStyle(.white.opacity(0.65))
        } else {
            base
                .foregroundStyle(.white.opacity(0.35))
                .overlay(
                    base
                        .foregroundStyle(.white)
                        .mask(shimmerMask)
                )
        }
    }

    private var shimmerMask: some View {
        TimelineView(.animation) { ctx in
            GeometryReader { proxy in
                let w = proxy.size.width
                let h = proxy.size.height
                // Band ~half the text width feels like a Mac-native
                // shimmer (Spotlight, Finder placeholders). Floor at
                // 40pt so very short labels still get a visible sweep.
                let bandWidth: CGFloat = max(40, w * 0.5)
                let period: Double = 1.6
                let t = ctx.date.timeIntervalSinceReferenceDate
                let phase = t.truncatingRemainder(dividingBy: period) / period
                // Travel range: band's leading edge moves from
                // `-bandWidth` (band is entirely past the left edge,
                // mask is fully clear) to `w` (band is entirely past
                // the right edge, mask is fully clear). Both endpoints
                // produce zero highlight, so the loop wrap is invisible.
                let totalTravel = w + bandWidth
                let x = CGFloat(phase) * totalTravel - bandWidth
                LinearGradient(
                    colors: [.clear, .white, .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: bandWidth, height: h)
                .offset(x: x)
            }
        }
    }

    // MARK: - Strings

    private var doneLabel: String {
        if let n = event.compactedTurnCount, n > 0 {
            return "Context compacted · \(n) turn\(n == 1 ? "" : "s") summarized"
        }
        return "Context compacted"
    }

    private var accessibilityText: String {
        switch event.status {
        case .running: return "Compacting context"
        case .done: return doneLabel
        }
    }
}

import SwiftUI

// MARK: - SystemTrayView
//
// The drawer that pokes out below the main panel when there are pending
// system notices, agent live-state rows, or any other registered tray
// items. Renders a generic `[TrayItem]` from `NotchViewModel.trayItems`;
// per-row content (icon / tint / message / trailing slot / tap behaviour)
// is fully described by the item itself, so adding a new row is a
// `registerTraySource` call somewhere — not an edit here.
//
// Visual contract: this view paints NO surface of its own — the parent
// NotchView paints a single black silhouette spanning main panel + tray as
// one shape, so the tray reads as a downward extension of the notch rather
// than a separate card. This view contributes only the rows.
//
// Animation contract: collapsed/expanded transitions must NOT swap view
// structure (no `if expanded { A } else { B }` Group switch), because the
// resulting `.opacity` + insertion would read as a side panel sliding in
// from the right. Instead we always render every row in one VStack; the
// parent caps the visible height via `.frame(height:)` + `.clipShape`, so
// rows reveal/conceal purely by the drawer's animated height change.
// The chevron lives inside the first row's HStack (same layout in both
// states) and only its glyph flips on toggle.

struct SystemTrayView: View {
    let viewModel: NotchViewModel

    private var items: [TrayItem] { viewModel.trayItems }
    private var hasMultiple: Bool { items.count > 1 }

    @ViewBuilder
    var body: some View {
        if items.isEmpty {
            EmptyView()
        } else {
            // ScrollView so the very rare case of >9 items stays usable
            // when the drawer hits its 240pt ceiling. Disabled when the
            // drawer is collapsed so accidental scrolls don't reveal
            // hidden rows past the clipped frame.
            ScrollView(.vertical, showsIndicators: false) {
                // Two-block layout (NOT one VStack with spacing). The first
                // row + its own vertical padding(10) defines the collapsed
                // height exactly, so when the parent clips to
                // `notchTrayCollapsedHeight` the additional rows start
                // immediately *at* the clip line — no spillover, no partial
                // second row peeking through. A single VStack with
                // spacing(6) would push the second row's first ~4pt into
                // the clip window.
                VStack(alignment: .leading, spacing: 0) {
                    // Pin first-block to EXACTLY the collapsed height. The
                    // row's intrinsic height varies a few points across
                    // layout passes (SF Symbol metrics, font baseline
                    // settling, first-frame vs measured), which used to
                    // cause an intermittent 1–4pt sliver of the second
                    // row to bleed through the clip line on first open.
                    HStack(spacing: 8) {
                        itemRow(items[0])
                        if hasMultiple { chevronButton }
                    }
                    .padding(.horizontal, 16)
                    // Slight bottom padding inside the centered frame nudges
                    // the row up by ~half its size, compensating for the
                    // perceived extension of the drawer band into the main
                    // notch's rounded-corner region above. Without this the
                    // row reads as bottom-heavy because eye-centering uses
                    // the full visual band including the curves, not just
                    // the flat region.
                    .padding(.bottom, 4)
                    .frame(height: viewModel.notchTrayCollapsedHeight)

                    if hasMultiple {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(items.dropFirst()) { itemRow($0) }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                    }
                }
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: TrayHeightKey.self,
                            value: geo.size.height
                        )
                    }
                )
            }
            .scrollDisabled(!viewModel.trayExpanded)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onPreferenceChange(TrayHeightKey.self) { h in
                viewModel.trayContentHeight = h
            }
        }
    }

    // MARK: - Rows

    private func itemRow(_ item: TrayItem) -> some View {
        // Row body and dismiss `×` are SIBLINGS, not nested. Nesting the
        // × inside a row Button has two failure modes:
        //   1. Action-less rows need `.disabled(true)` on the outer Button
        //      to avoid an inert tap region — but SwiftUI then applies a
        //      system-wide disabled tint to ALL contained views.
        //   2. Even when the outer Button is enabled, the nested × tap
        //      gets captured by the outer hit area first.
        // Splitting them solves both. The actionable row body is a real
        // `Button` (not `.onTapGesture`) so VoiceOver, Voice Control, and
        // keyboard activation all work; action-less rows render as plain
        // text with no hit region. The × is its own plain Button.
        return HStack(spacing: 8) {
            if let onTap = item.onTap {
                Button(action: onTap) {
                    rowContent(item)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(rowAccessibilityLabel(item)))
            } else {
                rowContent(item)
                    .accessibilityElement(children: .combine)
            }

            if item.dismissable {
                Button {
                    viewModel.dismissTrayItem(id: item.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss notice")
            }
        }
    }

    /// Visual content of an item row, shared between the actionable
    /// (Button-wrapped) and inert paths so both render identically.
    /// The trailing slot picks its font face from the trailing variant —
    /// `.action` is regular weight (CTA reads naturally next to the
    /// message), `.badge` is monospaced (digits don't jitter as the badge
    /// updates between renders).
    private func rowContent(_ item: TrayItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(item.tint)
                .frame(width: 14, alignment: .center)
            Text(item.message)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
            Spacer(minLength: 6)
            if let trailing = item.trailing {
                trailingLabel(trailing)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func trailingLabel(_ trailing: TrayItemTrailing) -> some View {
        switch trailing {
        case .action(let title):
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
        case .badge(let label):
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    /// VoiceOver label: "<message>, <trailing>" so the user hears both the
    /// problem and the activation outcome before deciding to press.
    private func rowAccessibilityLabel(_ item: TrayItem) -> String {
        if let trailing = item.trailing {
            return "\(item.message), \(trailing.label)"
        }
        return item.message
    }

    private var chevronButton: some View {
        Button {
            viewModel.toggleTrayExpanded()
        } label: {
            Image(systemName: viewModel.trayExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .notchForeground(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.notchPressable)
        .accessibilityLabel(viewModel.trayExpanded ? "Collapse notices" : "Expand notices")
    }
}

// MARK: - Height preference

private struct TrayHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

import SwiftUI
import AOSRPCSchema

// MARK: - ToolCallView
//
// Inline per-tool-invocation row inside a `turnRow`. Visually mirrors
// `ThinkingView`'s settled mode: a one-line collapsed header with a chevron
// rotation, expanding to a monospaced content slot inside a faint rounded
// background. The header text is `"using <tool>"` while the call is in
// `.calling`, switching to `"used <tool>"` once the result arrives — the
// same verb shift the user description called out.
//
// Per-tool semantics live in `ToolUIRegistry`, not here. This view does no
// JSON parsing; it asks the registry for a `ToolUIPresenter` and renders
// what the presenter returns. The fallback presenter handles unknown tools
// gracefully so a sidecar can ship a new tool without a Shell update.

struct ToolCallView: View {
    let record: ToolCallRecord
    var contentScale: ConversationContentScale = .normal

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded: Bool = false
    /// Natural height of the expanded body. Drives the slot's `frame(height:)`
    /// so short outputs hug their content instead of always reserving the
    /// max-height cap.
    @State private var contentHeight: CGFloat = 0

    /// Cap on the expanded body. Past this an inner ScrollView takes over
    /// and the user scrolls inside the fixed-height slot. Bash output can
    /// run to ~50KB; a hard cap keeps one tool from dominating the panel.
    private static let expandedMaxHeight: CGFloat = 200

    private var presenter: ToolUIPresenter {
        ToolUIRegistry.presenter(for: record.name)
    }

    private var isCalling: Bool { record.status == .calling }

    private var headerLabel: String {
        // The presenter owns its own grammar: file tools render in the
        // active/past form of their verb (`reading hosts` / `read hosts`),
        // bash falls back to the generic `using bash` / `used bash`. The
        // view just renders what the presenter returns.
        presenter.label(record.args, isCalling)
    }

    /// What the expanded slot shows. While calling we prefer the
    /// presenter's `callingBody` (e.g. bash → the command) and fall back
    /// to a generic "running…" so unknown-tool rows still feel alive.
    /// After result we render the presenter's `resultBody` — by default
    /// this is the wire's `outputText` verbatim.
    private var bodyText: String {
        if isCalling {
            return presenter.callingBody(record.args) ?? "running…"
        } else {
            return presenter.resultBody(record.args, record.outputText ?? "", record.isError ?? false)
        }
    }

    private var bodyForeground: Color {
        // Errored results use the same red treatment as the per-turn error
        // banner so the user can scan a turn and immediately see "this tool
        // call failed" without expanding it. We could also tint the header,
        // but keeping the header chrome neutral matches the thinking view's
        // visual weight — the body color is enough.
        if record.status == .completed, record.isError == true {
            return .red.opacity(0.85)
        }
        return .white.opacity(0.65)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if reduceMotion {
                    expanded.toggle()
                } else {
                    // Match the notch silhouette's height animation
                    // (`.smooth(0.32)` in NotchView) so the expansion eases
                    // in lockstep with the outer container growing — same
                    // contract ThinkingView documents above.
                    withAnimation(.notchHeight) {
                        expanded.toggle()
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: presenter.icon)
                        .notchFont(size: contentScale.toolIconSize, weight: contentScale.fontWeight)
                        .notchForeground(.secondary)
                    Text(headerLabel)
                        .notchFont(size: contentScale.toolFontSize, weight: contentScale.fontWeight, design: .monospaced)
                        .notchForeground(.secondary)
                    Image(systemName: "chevron.right")
                        .notchFont(size: contentScale.toolChevronSize, weight: .semibold)
                        .notchForeground(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .animation(reduceMotion ? nil : .notchHeight, value: expanded)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(headerLabel))
            .accessibilityHint(Text(expanded ? "Hides tool details" : "Shows tool details"))

            if expanded {
                ScrollView {
                    Text(bodyText)
                        .notchFont(size: contentScale.toolFontSize, weight: contentScale.fontWeight, design: .monospaced)
                        .foregroundStyle(bodyForeground)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: ToolCallContentHeightKey.self,
                                    value: geo.size.height
                                )
                            }
                        )
                }
                .frame(height: min(contentHeight, Self.expandedMaxHeight))
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.04))
                )
                .clipped()
                .onPreferenceChange(ToolCallContentHeightKey.self) { h in
                    contentHeight = h
                }
            }
        }
    }
}

private struct ToolCallContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

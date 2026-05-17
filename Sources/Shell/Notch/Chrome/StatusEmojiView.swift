import SwiftUI

// MARK: - StatusEmojiView
//
// AgentStatus → text-emoji mapping per notch-ui.md "AgentStatus → 颜文字映射".
// Three sizes:
//   - `.small`:  closed-bar variant, 16pt
//   - `.medium`: opened-panel variant, 32pt — sized to align with the
//                two-row "context + input" header.
//   - `.large`:  reserved for hero contexts, 64pt
// All glyphs are 2 chars wide so monospaced rendering keeps the slot a
// fixed pixel width across status transitions.
//
// `.working` is rendered as a `:/` ↔ `:\` heartbeat via TimelineView so the
// closed bar and the opened panel share the same animated thinking glyph.

struct StatusEmojiView: View {
    let status: AgentStatus
    let size: Size

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Size {
        case small, medium, large
    }

    private var fontSize: CGFloat {
        switch size {
        case .small: return 16
        case .medium: return 32
        case .large: return 64
        }
    }

    private var weight: Font.Weight {
        size == .small ? .medium : .bold
    }

    var body: some View {
        Group {
            if status == .working && !reduceMotion {
                TimelineView(.periodic(from: .now, by: 0.4)) { ctx in
                    let tick = Int(ctx.date.timeIntervalSinceReferenceDate / 0.4)
                    Text(tick.isMultiple(of: 2) ? ":/" : ":\\")
                }
            } else {
                Text(staticText)
            }
        }
        .font(.system(size: fontSize, weight: weight, design: .monospaced))
        .foregroundStyle(.white)
        .accessibilityLabel(Text("Agent status: \(accessibilityStatusText)"))
    }

    private var staticText: String {
        switch status {
        case .idle: return ":)"
        case .listening: return ":o"
        case .working: return ":/" // shown also when Reduce Motion is on
        case .done: return ":D"
        case .waiting: return ":?"
        case .error: return ":("
        }
    }

    /// Human-readable status text for VoiceOver. Avoid emitting the raw
    /// enum case (`AgentStatus.working`) which VO would read as
    /// "AgentStatus.working".
    private var accessibilityStatusText: String {
        switch status {
        case .idle: return "ready"
        case .listening: return "listening"
        case .working: return "thinking"
        case .done: return "done"
        case .waiting: return "waiting for tool"
        case .error: return "error"
        }
    }
}

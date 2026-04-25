import SwiftUI

// MARK: - StatusEmojiView
//
// AgentStatus → text-emoji mapping per notch-ui.md "AgentStatus → 颜文字映射".
// Three sizes:
//   - `.small`:  closed-bar variant, 16pt
//   - `.medium`: opened-panel variant, 32pt — sized to align with the
//                two-row "context + input" header.
//   - `.large`:  reserved for hero contexts, 64pt
// Always monospaced so the different glyph widths (`:)` vs `>_<`) don't
// shift surrounding layout.

struct StatusEmojiView: View {
    let status: AgentStatus
    let size: Size

    enum Size {
        case small, medium, large
    }

    private var text: String {
        switch status {
        case .idle: return ":)"
        case .listening: return ":o"
        case .thinking: return ":/"
        case .working: return ">_<"
        case .done: return ":D"
        case .waiting: return ":?"
        case .error: return ":("
        }
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
        Text(text)
            .font(.system(size: fontSize, weight: weight, design: .monospaced))
            .foregroundStyle(.white)
            .accessibilityLabel(Text("Agent status: \(status)"))
    }
}

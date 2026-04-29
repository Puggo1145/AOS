import SwiftUI

// MARK: - AgentStatusIndicator
//
// Right-slot occupant of the closed bar. Single responsibility: decide what
// the user should see in the "agent status" cell at any given moment.
//
//   - A tool call is in flight → render that tool's SF Symbol icon (resolved
//     through `ToolUIRegistry`, the same source of truth the opened panel's
//     tool rows use). The icon pulses softly so the cell reads as "live
//     activity" rather than a static label.
//   - Otherwise → defer to `StatusEmojiView`, which keeps the resting/working
//     emoji glyphs.
//
// The swap happens here so the closed bar doesn't have to know either the
// registry or the emoji vocabulary — both stay decoupled behind their own
// component. Crossfade via `.id(...)` keeps the transition smooth without
// introducing a separate animation driver.

struct AgentStatusIndicator: View {
    let status: AgentStatus
    /// Name of the in-flight tool call (any family). `nil` when no tool is
    /// currently running — the view falls back to the status emoji.
    let activeToolName: String?

    var body: some View {
        Group {
            if let name = activeToolName {
                let presenter = ToolUIRegistry.presenter(for: name)
                ToolIconBadge(
                    symbolName: presenter.icon,
                    toolName: name
                )
                .id(name)
                .transition(.opacity)
            } else {
                StatusEmojiView(status: status, size: .small)
                    .transition(.opacity)
            }
        }
        .animation(.notchChrome, value: activeToolName)
    }
}

// MARK: - ToolIconBadge
//
// Renders the SF Symbol returned by the tool's presenter. We deliberately do
// not echo `BackgroundOpBadge` here — that one shows the *target app's icon*
// for `computer_use_*` calls (a "what we're operating on" cue), while this
// shows the *tool's* glyph (a "what kind of action" cue). Both can be on
// screen at the same time without redundancy.

private struct ToolIconBadge: View {
    let symbolName: String
    /// The agent-facing tool name (e.g. "bash", "read"). Used for VoiceOver
    /// — without this we'd read the raw SF Symbol identifier, which is
    /// incomprehensible (e.g. "Using cursorarrow.click").
    let toolName: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        // 12pt keeps the glyph visibly smaller than the 16pt status emoji
        // next to it, matching the user's "tool < status" hierarchy.
        // 0.55 white opacity matches the conversation panel's secondary
        // text color (`ToolCallView`'s muted gray) so the closed-bar tool
        // cue reads as the same family as the inline tool rows.
        Image(systemName: symbolName)
            .font(.system(size: 12, weight: .medium))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.white.opacity(0.55))
            .opacity(reduceMotion ? 1.0 : (pulse ? 0.4 : 1.0))
            .animation(
                // Reduce Motion suppresses the perpetual pulse entirely.
                // `.default` would still animate (just with a default
                // curve), defeating the affordance.
                reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                value: pulse
            )
            .onAppear { pulse = !reduceMotion }
            .onDisappear { pulse = false }
            .onChange(of: reduceMotion) { _, newValue in
                pulse = !newValue
            }
            .accessibilityLabel(Text("Using \(toolName)"))
    }
}

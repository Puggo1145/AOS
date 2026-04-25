import SwiftUI
import AOSOSSenseKit
import AOSRPCSchema

// MARK: - AgentInputField
//
// Per notch-ui.md §"输入区". A transparent, borderless TextField anchored at
// the bottom of the opened panel. Two ways to submit:
//   - press Return inside the text field
//   - click the circular send button on the trailing edge
// Both routes call the same `submit` closure so behavior stays in sync.
//
// `inputFocused` is forwarded to the view-model so the ClosedBar status emoji
// can flip to `:o` (listening) while the user is composing — without polluting
// `AgentService.status`.

struct AgentInputField: View {
    let senseStore: SenseStore
    let agentService: AgentService
    @Binding var inputFocused: Bool

    @State private var text: String = ""
    @FocusState private var focused: Bool

    /// Disable the send button when the trimmed prompt is empty so the user
    /// can't fire an empty turn (the sidecar would 400). Keeping the button
    /// visible-but-dim (rather than hidden) prevents the input row width from
    /// shifting as the user types.
    private var canSubmit: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: 8) {
            // Custom-overlay placeholder. The default `TextField("…", text:)`
            // placeholder is rendered by AppKit's NSTextField and shifts up by
            // ~1pt the moment the field becomes first responder (the field
            // editor swaps in with a different baseline). Drawing the
            // placeholder ourselves in a ZStack keeps it pinned to the same
            // baseline as the typed text on every focus transition.
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text("What can I do for you?")
                        .foregroundStyle(.white.opacity(0.35))
                        .allowsHitTesting(false)
                }
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onChange(of: focused) { _, newValue in
                        inputFocused = newValue
                    }
                    .onSubmit { submit() }
            }
            .font(.system(size: 16))
            .foregroundStyle(.white)
            .tint(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(Text("Prompt input"))

            sendButton
        }
    }

    private var sendButton: some View {
        Button(action: submit) {
            Image(systemName: "arrow.up")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(canSubmit ? Color.black : Color.white.opacity(0.4))
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(canSubmit ? Color.white : Color.white.opacity(0.15))
                )
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit)
        .padding(.trailing, 6)
        .accessibilityLabel(Text("Send prompt"))
    }

    private func submit() {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        let cited = CitedContextProjection.project(from: senseStore.context)
        let promptCopy = prompt
        // The sidecar registers the turn and broadcasts
        // `conversation.turnStarted`; the panel re-renders from there. We
        // intentionally don't seed a local turn so the UI has a single source
        // of truth (the sidecar's Conversation, mirrored by AgentService).
        Task { await agentService.submit(prompt: promptCopy, citedContext: cited) }
        text = ""
    }
}

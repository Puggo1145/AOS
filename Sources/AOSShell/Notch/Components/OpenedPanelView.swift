import SwiftUI
import AppKit
import AOSOSSenseKit

// MARK: - OpenedPanelView
//
// Conversation panel. The input row is a permanent fixture at the bottom; the
// space above it is split into:
//
//   1. A vertical history of past turns. Each turn is rendered as a single
//      compressed header line ([app icon] · prompt) followed by an emoji-
//      prefixed reply block. The header is the *snapshot* taken at submit
//      time — once a turn enters the history it freezes and the live
//      SenseStore ticks no longer change it.
//   2. A live "next turn" composer just above the input: full chips of the
//      *current* SenseContext, so the user always sees what would be cited
//      if they pressed Return right now.
//
// Layout sketches (input always anchored at the bottom):
//
//   no turns yet:                 turns present:
//   ┌──────────────────┐          ┌─────────────────────────┐
//   │ (Spacer)         │          │ ScrollView{             │
//   │ live chips       │          │   [icon] · prompt 1     │
//   │ [TextField] ⬆    │          │   :D  reply 1           │
//   └──────────────────┘          │   [icon] · prompt 2     │
//                                 │   :O  reply 2 (stream)  │
//                                 │ }                       │
//                                 │ live chips              │
//                                 │ [TextField] ⬆           │
//                                 └─────────────────────────┘
//
// Each new submit appends to `agentService.turns` and the ScrollView is
// programmatically scrolled to the new turn so the user sees their freshly
// submitted prompt + the streaming reply without manual scrolling.

struct OpenedPanelView: View {
    let viewModel: NotchViewModel
    let senseStore: SenseStore
    let agentService: AgentService

    /// Top safe area equal to the physical notch height. The opened panel
    /// extends to the very top of the screen, so any content inside the
    /// `0..<deviceNotchRect.height` band sits behind the hardware cutout.
    private var topSafeInset: CGFloat {
        viewModel.deviceNotchRect.height
    }

    private var hasSession: Bool {
        viewModel.isAgentLoopActive
    }

    /// Single padding constant used on every inset where it isn't dictated by
    /// the hardware notch (top). Keeping leading / trailing / bottom equal
    /// keeps the panel reading as evenly framed.
    private let edgePadding: CGFloat = 16

    var body: some View {
        ZStack(alignment: .top) {
            mainContent
            headerStrips
        }
        .frame(width: viewModel.notchOpenedSize.width,
               height: viewModel.notchOpenedSize.height)
        .animation(.smooth(duration: 0.28), value: hasSession)
        .animation(.smooth(duration: 0.28), value: agentService.turns.count)
        .onChange(of: hasSession) { _, active in
            // Drop stale measurements when the conversation resets so the
            // panel collapses back to compact instead of inheriting the last
            // session's height.
            if !active {
                viewModel.historyContentHeight = 0
            }
        }
    }

    // MARK: - Header strips (left/right of the physical notch)

    /// The top band (height = physical notch height) is split by the hardware
    /// cutout into a left and right strip. Both strips are part of the panel
    /// silhouette (NotchShape paints them black so they merge with the
    /// notch) and host global controls — settings + "new conversation".
    private var headerStrips: some View {
        let stripWidth = max(0, (viewModel.notchOpenedSize.width - viewModel.deviceNotchRect.width) / 2)
        let bandHeight = topSafeInset
        let notchGap: CGFloat = 8
        return HStack(spacing: 0) {
            HStack {
                Spacer(minLength: 0)
                gearButton
                    .padding(.trailing, notchGap)
            }
            .frame(width: stripWidth, height: bandHeight)

            Spacer(minLength: 0)
                .frame(width: viewModel.deviceNotchRect.width, height: bandHeight)

            HStack {
                newConversationButton
                    .padding(.leading, notchGap)
                Spacer(minLength: 0)
            }
            .frame(width: stripWidth, height: bandHeight)
        }
    }

    private var gearButton: some View {
        Button {
            viewModel.showSettings = true
        } label: {
            headerIcon("gearshape.fill")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Settings"))
    }

    private var newConversationButton: some View {
        Button {
            Task { await agentService.resetSession() }
        } label: {
            headerIcon("plus")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("New conversation"))
    }

    private func headerIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(0.55))
            .frame(width: 22, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.06))
            )
    }

    // MARK: - Main content

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hasSession {
                history
            } else {
                Spacer(minLength: 0)
            }
            liveComposer
        }
        .padding(.top, topSafeInset)
        .padding(.horizontal, edgePadding)
        .padding(.bottom, edgePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Live chips of the current SenseContext + the input field. Travels
    /// together so the user reads "this is what I'd be sending right now".
    private var liveComposer: some View {
        VStack(alignment: .leading, spacing: 6) {
            ContextChipsView(senseStore: senseStore)
            AgentInputField(
                senseStore: senseStore,
                agentService: agentService,
                inputFocused: Binding(
                    get: { viewModel.inputFocused },
                    set: { viewModel.inputFocused = $0 }
                )
            )
        }
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: ComposerHeightKey.self, value: geo.size.height)
            }
        )
        .onPreferenceChange(ComposerHeightKey.self) { h in
            viewModel.composerContentHeight = h
        }
    }

    private var history: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(agentService.turns) { turn in
                    turnRow(turn)
                        .id(turn.id)
                        // New turns slide in from below — that's the
                        // direction they conceptually come from (the
                        // input row at the bottom).
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .opacity
                        ))
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            // Measured *inside* the ScrollView so we read the content's
            // natural (unconstrained) height; the parent ScrollView lets the
            // VStack be as tall as it wants. The viewmodel uses this to
            // grow the silhouette toward `notchOpenedMaxHeight`.
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: HistoryHeightKey.self, value: geo.size.height)
                }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Pin the scroll position to the bottom so newly submitted prompts
        // and streaming replies stay fully visible without manual scroll
        // management. Once the conversation exceeds `notchOpenedMaxHeight`,
        // the user can scroll up to read older turns.
        .defaultScrollAnchor(.bottom)
        .onPreferenceChange(HistoryHeightKey.self) { h in
            viewModel.historyContentHeight = h
        }
    }

    /// One historical turn = compressed header + reply block + (optional
    /// error banner). The header collapses chips down to just the app icon —
    /// the live composer above already names the current app, so repeating
    /// the name in every history row is redundant noise.
    private func turnRow(_ turn: ConversationTurn) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let icon = turn.context.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 14, height: 14)
                        .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 2 }
                }
                Text(turn.prompt)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            HStack(alignment: .top, spacing: 10) {
                Text(turnEmoji(turn))
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(width: 24, alignment: .leading)
                Text(turn.reply)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            if turn.status == .error, let msg = turn.errorMessage, !msg.isEmpty {
                Text(msg)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.red.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.red.opacity(0.12))
                    )
            }
        }
    }

    /// Per-turn emoji. Mirrors the previous session-region mapping, but reads
    /// the turn's own status (not the global `status`) so older completed
    /// turns keep `:D` even while a newer turn is mid-`:O` streaming.
    private func turnEmoji(_ turn: ConversationTurn) -> String {
        switch turn.status {
        case .error: return ":("
        case .thinking: return turn.reply.isEmpty ? ":/" : ":O"
        case .working: return ">_<"
        case .waiting: return ":?"
        case .listening: return ":o"
        case .done, .idle:
            return turn.reply.isEmpty ? ":|" : ":D"
        }
    }
}

/// Natural height of the history VStack inside the ScrollView. Reported up
/// to NotchViewModel so the silhouette grows alongside the content.
private struct HistoryHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Natural height of the composer (chips + input). Combined with the
/// history height to derive the panel's desired size.
private struct ComposerHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}


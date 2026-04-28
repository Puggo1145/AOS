import SwiftUI
import AppKit
import AOSOSSenseKit
import MarkdownUI

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
    let visualCapturePolicyStore: VisualCapturePolicyStore

    /// Last turn count observed by the history-height preference handler.
    /// Used to distinguish streaming growth (count unchanged → suppress the
    /// panel's height animation so the viewport stays in lockstep with the
    /// content) from new-turn insertion (count changed → keep the existing
    /// `.smooth` animation that lets the panel ease open).
    @State private var lastObservedTurnCount: Int = 0

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
            // Left strip: gear (settings) flush against the notch.
            HStack {
                Spacer(minLength: 0)
                gearButton
                    .padding(.trailing, notchGap)
            }
            .frame(width: stripWidth, height: bandHeight)

            Spacer(minLength: 0)
                .frame(width: viewModel.deviceNotchRect.width, height: bandHeight)

            // Right strip: "+" (new session) + history. "+" is closer to the
            // notch so the eye reads "create" before "browse" L-to-R.
            HStack(spacing: 6) {
                newConversationButton
                    .padding(.leading, notchGap)
                historyButton
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
            // "+" starts a fresh in-process session (per design: the old one
            // is preserved for the user to navigate back via history). The
            // sidecar's `session.create` auto-activates; SessionService drives
            // `SessionStore.adoptCreated` from the response so mirror+activeId
            // flip atomically before SwiftUI reads them.
            Task {
                do {
                    _ = try await viewModel.sessionService.create()
                } catch {
                    viewModel.agentService.sessionStore.setActionError(
                        SessionActionError(
                            kind: .create,
                            message: "Failed to start a new conversation: \(error.localizedDescription)",
                            sessionId: nil
                        )
                    )
                }
            }
        } label: {
            headerIcon("plus")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("New conversation"))
    }

    private var historyButton: some View {
        Button {
            // Refresh from sidecar before opening so turnCount/lastActivityAt
            // are up to date. Flip `showHistory` regardless of refresh
            // outcome — the panel renders the cached list and surfaces a
            // banner via `sessionStore.lastActionError` if refresh failed.
            Task {
                let store = viewModel.agentService.sessionStore
                do {
                    _ = try await store.refreshList()
                } catch {
                    store.setActionError(SessionActionError(
                        kind: .list,
                        message: "Failed to refresh sessions: \(error.localizedDescription)",
                        sessionId: nil
                    ))
                }
                viewModel.showHistory = true
            }
        } label: {
            headerIcon("clock.arrow.circlepath")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Conversation history"))
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
            }
            // Boot-time session.create failure. The composer below is also
            // disabled, but this banner is the precise reason — surfaces it
            // ahead of the input so the user reads "why" before "what's
            // greyed out".
            if let msg = agentService.sessionStore.bootError, !msg.isEmpty {
                Text(msg)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.red.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.red.opacity(0.12))
                    )
            }
            // Session-action failures (create / activate / list refresh)
            // surface here when no history panel is overlaid. Dismissable so
            // a stale banner doesn't linger after the user moves on.
            if let actionError = agentService.sessionStore.lastActionError {
                HStack(alignment: .top, spacing: 6) {
                    Text(actionError.message)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.red.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        agentService.sessionStore.setActionError(nil)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.red.opacity(0.12))
                )
            }
            // Submit-time errors that have no per-turn slot (e.g. the
            // outbound payload exceeded the RPC line cap). Displayed above
            // the composer so the user sees it before re-submitting.
            if let msg = agentService.lastErrorMessage, !msg.isEmpty {
                Text(msg)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.red.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.red.opacity(0.12))
                    )
            }
            liveComposer
        }
        .padding(.top, topSafeInset)
        .padding(.horizontal, edgePadding)
        .padding(.bottom, edgePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Single composer card per the redesign: chips, then the input, then
    /// a function row (model + effort menus on the left, send on the right).
    /// Renders as one bordered rounded rect so the user reads "this entire
    /// box is what I'd be sending right now".
    private var liveComposer: some View {
        ComposerCard(
            senseStore: senseStore,
            agentService: agentService,
            configService: viewModel.configService,
            policyStore: visualCapturePolicyStore,
            inputModel: viewModel.composerInputModel,
            inputFocused: Binding(
                get: { viewModel.inputFocused },
                set: { viewModel.inputFocused = $0 }
            )
        )
        // Disable typing + submission when the currently *selected* provider
        // isn't authenticated — otherwise the user could compose and send
        // against e.g. codex with no token, and the agent loop would just
        // bounce the request. Permission gaps don't disable the input here:
        // the user can still queue a prompt while granting access in Settings.
        // Also disabled when bootstrap session.create failed: there's no
        // active session to attach a turn to and submit would no-op.
        .disabled(!viewModel.composerSubmitEnabled)
        .opacity(viewModel.composerSubmitEnabled ? 1.0 : 0.55)
        // Pin the composer to its natural vertical size so the parent
        // VStack's `maxHeight: .infinity` (needed for history) can't
        // stretch it. Without this, the inner NSTextView would accept
        // the stretched offer, GeometryReader would report the inflated
        // height into `composerContentHeight`, and the panel would stay
        // tall after settings closes.
        .fixedSize(horizontal: false, vertical: true)
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
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(agentService.turns) { turn in
                    turnRow(turn)
                        .id(turn.id)
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
            // Per-token streaming grows the inner VStack one frame before
            // the parent's `notchOpenedSize.height` (and thus the ScrollView
            // viewport) catches up. NotchView animates that height change
            // over 0.32s; during the animation the content is taller than
            // the viewport, so `.defaultScrollAnchor(.bottom)` pins to the
            // bottom and the older content visually scrolls up, then slides
            // back down as the viewport finishes growing — the "上顶/回弹".
            //
            // Suppress the height animation while a turn is live (count
            // unchanged) so panel + viewport grow in the same frame as the
            // content. New-turn insertion changes the count, so its
            // preference update flows through with the normal `.smooth`
            // height animation intact and the panel still eases open.
            //
            // The signal is "last turn is in a non-terminal status" rather
            // than "reply.count grew since last fire". A single token can
            // produce multiple preference fires (sub-pixel relayout after
            // the parent frame catches up); a delta-based discriminator
            // that advances its baseline on the first fire would miss the
            // follow-up fires and let them through the animated path,
            // which is exactly the bounce. The status-based signal is
            // stable across fires for the duration of the streaming turn.
            //
            // Other intra-turn height changes (the user expands/collapses
            // a *settled* thinking trace on an older turn, an error
            // banner appears, the status emoji swaps) leave the last
            // turn in a terminal status (`.done` / `.error` / `.idle`)
            // so they fall through to the normal `.smooth(0.32)` path,
            // matching the silhouette's animation curve.
            //
            // Round h to integer points to suppress sub-pixel jitter from
            // SwiftUI's per-frame relayout — same pattern as
            // OnboardingMeasurement / SettingsMeasurement. Real content
            // changes are always >> 1pt and still flow through.
            let count = agentService.turns.count
            let isLastTurnLive: Bool = {
                guard let last = agentService.turns.last else { return false }
                switch last.status {
                case .working, .waiting: return true
                case .idle, .listening, .done, .error: return false
                }
            }()
            let isStreamingUpdate = count == lastObservedTurnCount && isLastTurnLive
            let rounded = h.rounded()
            if isStreamingUpdate {
                var txn = Transaction()
                txn.disablesAnimations = true
                withTransaction(txn) {
                    if viewModel.historyContentHeight != rounded {
                        viewModel.historyContentHeight = rounded
                    }
                }
            } else {
                if viewModel.historyContentHeight != rounded {
                    viewModel.historyContentHeight = rounded
                }
                lastObservedTurnCount = count
            }
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
                PromptWithChipsView(
                    prompt: turn.prompt,
                    clipboardLabels: turn.context.clipboardLabels
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(alignment: .top, spacing: 8) {
                turnEmojiView(turn)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 6) {
                    // Render segments in the order the sidecar emitted them
                    // so thinking, tool calls, and reply chunks interleave the
                    // way the model produced them — instead of being grouped
                    // into a fixed thinking → tools → reply layout. Segment
                    // ids are stable (UUID for thinking/reply, `toolCallId`
                    // for tool calls) so SwiftUI preserves each row's local
                    // state across redraws.
                    ForEach(turn.segments) { segment in
                        segmentView(segment, in: turn)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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

    @ViewBuilder
    private func segmentView(_ segment: TurnSegment, in turn: ConversationTurn) -> some View {
        switch segment {
        case .thinking(let s):
            ThinkingView(
                thinking: s.text,
                startedAt: s.startedAt,
                endedAt: s.endedAt,
                isCurrent: s.isOpenForAppend
            )
        case .toolCall(let id):
            if let record = turn.toolCalls.first(where: { $0.id == id }) {
                ToolCallView(record: record)
            }
        case .reply(let s):
            if !s.text.isEmpty {
                ReplyMarkdownView(text: s.text)
            }
        }
    }

    /// Per-turn emoji. Mirrors the previous session-region mapping, but reads
    /// the turn's own status (not the global `status`) so older completed
    /// turns keep `:D` even while a newer turn is mid-`:O` streaming. While a
    /// turn is in the "thinking, no tokens yet" state we render an animated
    /// `:/` ↔ `:\` flip via TimelineView so the user sees a heartbeat instead
    /// of a static glyph.
    @ViewBuilder
    private func turnEmojiView(_ turn: ConversationTurn) -> some View {
        if turn.status == .working && turn.reply.isEmpty {
            TimelineView(.periodic(from: .now, by: 0.4)) { ctx in
                let tick = Int(ctx.date.timeIntervalSinceReferenceDate / 0.4)
                Text(tick.isMultiple(of: 2) ? ":/" : ":\\")
            }
        } else {
            Text(turnEmoji(turn))
        }
    }


    private func turnEmoji(_ turn: ConversationTurn) -> String {
        switch turn.status {
        case .error: return ":("
        case .working: return turn.reply.isEmpty ? ":/" : ":O"
        case .waiting: return ":?"
        case .listening: return ":o"
        case .done, .idle:
            return turn.reply.isEmpty ? ":|" : ":D"
        }
    }
}

// MARK: - ReplyMarkdownView
//
// Equatable wrapper around MarkdownUI's `Markdown` so SwiftUI skips re-
// parsing when the reply text hasn't changed. Without this, every streaming
// token on the *last* turn re-evaluates `Markdown(s.text)` for every
// *visible* turn — O(visible × tokens) markdown parses per turn.
private struct ReplyMarkdownView: View, Equatable {
    let text: String

    var body: some View {
        Markdown(text)
            .markdownTheme(.aosNotchPanel)
            .markdownImageProvider(BlockedImageProvider())
            .markdownInlineImageProvider(BlockedInlineImageProvider())
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
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

// MARK: - Markdown theme
//
// Matches the rest of the panel: monospaced 13pt, white at 0.9 opacity.
// Code spans/blocks add a subtle background so they read as code without
// breaking the panel's dark visual register. Headings scale relative to the
// body so an `# H1` from the model still looks like a heading inside what is
// otherwise a compact, terminal-feeling surface.
extension Theme {
    static let aosNotchPanel: Theme = Theme()
        .text {
            FontFamily(.system(.monospaced))
            FontSize(13)
            ForegroundColor(.white.opacity(0.9))
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.95))
            BackgroundColor(.white.opacity(0.10))
        }
        .strong {
            FontWeight(.semibold)
        }
        .link {
            ForegroundColor(Color(red: 0.55, green: 0.78, blue: 1.0))
        }
        .heading1 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.4))
                }
                .markdownMargin(top: .em(0.6), bottom: .em(0.3))
        }
        .heading2 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.25))
                }
                .markdownMargin(top: .em(0.5), bottom: .em(0.25))
        }
        .heading3 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.1))
                }
                .markdownMargin(top: .em(0.4), bottom: .em(0.2))
        }
        .paragraph { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.18))
                .markdownMargin(top: .em(0), bottom: .em(0.5))
        }
        .codeBlock { configuration in
            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
                    .relativeLineSpacing(.em(0.2))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.95))
                    }
                    .padding(10)
            }
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.08))
            )
            .markdownMargin(top: .em(0.4), bottom: .em(0.5))
        }
        .blockquote { configuration in
            configuration.label
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.white.opacity(0.25))
                        .frame(width: 2)
                }
                .markdownMargin(top: .em(0.3), bottom: .em(0.5))
        }
}

// Image providers that render nothing. Reply text is untrusted LLM output;
// using MarkdownUI's default providers would fetch any URL the model emits in
// `![](…)`, turning the Notch UI into an outbound beacon (prompt-injection →
// IP/online-state/timing leak). Block both block-level and inline images.
private struct BlockedImageProvider: ImageProvider {
    func makeImage(url: URL?) -> some View { EmptyView() }
}

private struct BlockedInlineImageProvider: InlineImageProvider {
    private struct Blocked: Error {}
    func image(with url: URL, label: String) async throws -> Image {
        throw Blocked()
    }
}


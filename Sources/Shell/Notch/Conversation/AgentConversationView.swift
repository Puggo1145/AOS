import SwiftUI
import AppKit
import OSSenseKit

// MARK: - AgentConversationView
//
// The conversation surface above the composer: scrolling history of past
// turns plus any session-level error banners. Owns the auto-follow-bottom
// state machine — all scroll/sentinel measurement lives here so the
// parent panel only sees a single self-contained view.
//
//   ┌─────────────────────────┐
//   │ ScrollView{             │
//   │   [icon] · prompt 1     │
//   │   :D  reply 1           │
//   │   [icon] · prompt 2     │
//   │   :O  reply 2 (stream)  │
//   │ }                       │
//   │ [error banners…]        │
//   └─────────────────────────┘
struct AgentConversationView: View {
    let viewModel: NotchViewModel
    let agentService: AgentService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var followBottom: Bool = true
    @State private var viewportHeight: CGFloat = 0
    @State private var bottomSentinelMaxY: CGFloat = 0
    @State private var prevContentHeight: CGFloat = 0
    @State private var prevBottomSentinelMaxY: CGFloat = 0
    @State private var followEvalPending: Bool = false
    @State private var lastObservedTurnCount: Int = 0
    @AppStorage("notch-agent.conversationDisplayMode") private var displayModeRaw: String = ConversationDisplayMode.history.rawValue

    /// Symmetric ±4pt band around the viewport bottom: re-attach when
    /// the sentinel sits within this slack of the bottom; detach when a
    /// user-driven scroll moves it more than this past content growth.
    private let atBottomSlack: CGFloat = 4
    private let userDetachThreshold: CGFloat = 4

    private var hasSession: Bool {
        viewModel.isAgentLoopActive
    }

    private var displayMode: ConversationDisplayMode {
        ConversationDisplayMode(rawValue: displayModeRaw)!
    }

    private var contentScale: ConversationContentScale {
        displayMode == .compact ? .focused : .normal
    }

    /// Turn-only conversation feed. Compact lifecycle UI is rendered by the
    /// tray drawer below the composer, so transcript rows stay focused on
    /// user/agent conversation content.
    private var historyItems: [ConversationDisplayProjection.Item] {
        ConversationDisplayProjection.items(
            turns: agentService.turns,
            mode: displayMode
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hasSession {
                history
            }
            errorBanners
        }
        .onChange(of: hasSession) { _, active in
            if !active { resetScrollState() }
        }
    }

    private func resetScrollState() {
        viewModel.historyContentHeight = 0
        followBottom = true
        viewportHeight = 0
        bottomSentinelMaxY = 0
        prevContentHeight = 0
        prevBottomSentinelMaxY = 0
        followEvalPending = false
        lastObservedTurnCount = 0
    }

    // MARK: - Error banners

    @ViewBuilder
    private var errorBanners: some View {
        // Boot-time session.create failure: explains why the composer
        // below is disabled.
        if let msg = agentService.sessionStore.bootError, !msg.isEmpty {
            errorBanner(msg)
        }
        // Session-action failures (create / activate / list refresh).
        if let actionError = agentService.sessionStore.lastActionError {
            dismissibleErrorBanner(actionError)
        }
        // Submit-time errors that have no per-turn slot (e.g. payload
        // exceeded the RPC line cap).
        if let msg = agentService.lastErrorMessage, !msg.isEmpty {
            errorBanner(msg)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .notchFont(size: 12, weight: .medium)
            .foregroundStyle(.red.opacity(0.9))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.red.opacity(0.12))
            )
    }

    private func dismissibleErrorBanner(_ actionError: SessionActionError) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(actionError.message)
                .notchFont(size: 12, weight: .medium)
                .foregroundStyle(.red.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                agentService.sessionStore.setActionError(nil)
            } label: {
                Image(systemName: "xmark")
                    .notchFont(size: 10, weight: .semibold)
                    .notchForeground(.secondary)
            }
            .buttonStyle(.notchPressable)
            .accessibilityLabel("Dismiss error")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.red.opacity(0.12))
        )
    }

    // MARK: - History

    /// Conversation history. Plain VStack (no LazyVStack) so each row
    /// reports its real height; `scrollTo` then lands precisely and the
    /// natural-height preference up to the viewmodel is the truth.
    ///
    /// Scroll behaviour is gated on `followBottom` (auto-snap to bottom
    /// on growth), which the user toggles by scrolling up/down. Detect
    /// the toggle via a 1pt sentinel at the bottom of content reporting
    /// its `maxY` in the ScrollView's coordinate space — a sentinel is
    /// required because a `.background` GeometryReader on the VStack
    /// only refires on size changes, not on pure scroll moves.
    private var history: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Outer `spacing: 0` isolates the sentinel from the
                // inner 20pt turn spacing so the sentinel contributes
                // only its own 1pt to `historyContentHeight`.
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(historyItems) { item in
                            switch item {
                            case .turn(let turn):
                                turnRow(turn)
                                .id(item.id)
                                .transition(.asymmetric(
                                    insertion: .opacity,
                                    removal: .identity
                                ))
                            }
                        }
                    }
                    // Keyed on the turn count so a new turn triggers the
                    // insert transition, while streaming tokens inside an
                    // existing turn do not.
                    .animation(reduceMotion ? nil : .smooth(duration: 0.32), value: historyItems.count)

                    Color.clear
                        .frame(height: 1)
                        .id(historyBottomAnchor)
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: HistoryBottomMaxYKey.self,
                                    value: geo.frame(in: .named(historyViewportSpace)).maxY
                                )
                            }
                        )
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: HistoryHeightKey.self, value: geo.size.height)
                    }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .coordinateSpace(name: historyViewportSpace)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: HistoryViewportHeightKey.self, value: geo.size.height)
                }
            )
            .onAppear {
                lastObservedTurnCount = historyItems.count
                guard let lastID = historyItems.last?.id else { return }
                followBottom = true
                Task { @MainActor in
                    await Task.yield()
                    var txn = Transaction()
                    txn.disablesAnimations = true
                    withTransaction(txn) {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
            .onChange(of: displayMode) { _, _ in
                resetScrollState()
                lastObservedTurnCount = historyItems.count
                snapToBottom(proxy: proxy)
            }
            .onPreferenceChange(HistoryViewportHeightKey.self) { h in
                viewportHeight = h.rounded()
                scheduleFollowEval()
            }
            .onPreferenceChange(HistoryHeightKey.self) { h in
                handleHistoryHeightChange(h, proxy: proxy)
            }
            .onPreferenceChange(HistoryBottomMaxYKey.self) { y in
                bottomSentinelMaxY = y.rounded()
                scheduleFollowEval()
            }
        }
    }

    // MARK: - Auto-follow-bottom state machine

    private func handleHistoryHeightChange(_ rawHeight: CGFloat, proxy: ScrollViewProxy) {
        let rounded = rawHeight.rounded()
        guard viewModel.historyContentHeight != rounded else { return }
        let didGrow = rounded > viewModel.historyContentHeight
        let countNow = historyItems.count
        let countGrew = countNow > lastObservedTurnCount
        lastObservedTurnCount = countNow
        let availableViewport = viewModel.notchOpenedMaxHeight
            - viewModel.openedContentVerticalChrome
            - viewModel.composerContentHeight
        let wasOverflowing = viewModel.historyContentHeight > availableViewport
        viewModel.historyContentHeight = rounded
        let nowOverflowing = rounded > availableViewport
        // Skip when content still fits — the panel grows downward
        // naturally and a scrollTo would bottom-pin the ScrollView,
        // producing a per-line bounce against the `.notchHeight`
        // animation.
        //
        // Skip when growth isn't a new turn and the last turn is
        // settled — that's the user expanding a ThinkingView /
        // ToolCallView, snapping would push the row they just opened
        // out of view.
        guard didGrow, followBottom, nowOverflowing,
              countGrew || isLastTurnLive else { return }
        // Animate when a new turn appeared or content just crossed
        // the overflow threshold (one large translation either way).
        // Snap instantly for per-token streaming growth, otherwise
        // each token would bounce.
        if (countGrew || !wasOverflowing) && !reduceMotion {
            Task { @MainActor in
                await Task.yield()
                withAnimation(.smooth(duration: 0.32)) {
                    proxy.scrollTo(historyBottomAnchor, anchor: .bottom)
                }
            }
        } else {
            snapToBottom(proxy: proxy)
        }
    }

    /// Coalesce evaluation onto the next MainActor hop so the height
    /// and sentinel preferences for the same layout pass are both
    /// observed before judging — SwiftUI delivers the inner sentinel
    /// preference before the outer height, and without batching the
    /// evaluator sees a stale content height.
    private func scheduleFollowEval() {
        guard !followEvalPending else { return }
        followEvalPending = true
        Task { @MainActor in
            await Task.yield()
            followEvalPending = false
            evaluateFollowState()
        }
    }

    /// `userDelta = Δsentinel − Δcontent` isolates user-driven scroll
    /// from layout-driven sentinel motion: detach when it crosses
    /// `userDetachThreshold` upward, re-attach when the sentinel sits
    /// within `atBottomSlack` of the viewport bottom.
    private func evaluateFollowState() {
        guard viewportHeight > 0 else { return }
        let currentContentHeight = viewModel.historyContentHeight
        let dy = bottomSentinelMaxY - prevBottomSentinelMaxY
        let dh = currentContentHeight - prevContentHeight
        // `max(0, dh)` so a content shrink doesn't masquerade as a fake
        // user scroll.
        let userDelta = dy - max(0, dh)

        if followBottom && userDelta > userDetachThreshold {
            followBottom = false
        }

        let isAtBottom = bottomSentinelMaxY <= viewportHeight + atBottomSlack
        if isAtBottom && !followBottom {
            followBottom = true
        }

        prevContentHeight = currentContentHeight
        prevBottomSentinelMaxY = bottomSentinelMaxY
    }

    /// True while the last turn is still producing output (thinking,
    /// awaiting a tool result, or streaming tokens). Used to
    /// distinguish live growth from a user-driven row expansion.
    private var isLastTurnLive: Bool {
        guard let last = agentService.turns.last else { return false }
        switch last.status {
        case .working, .waiting, .listening:
            return true
        case .done, .idle, .error:
            return false
        }
    }

    private func snapToBottom(proxy: ScrollViewProxy) {
        Task { @MainActor in
            await Task.yield()
            var txn = Transaction()
            txn.disablesAnimations = true
            withTransaction(txn) {
                proxy.scrollTo(historyBottomAnchor, anchor: .bottom)
            }
        }
    }

    // MARK: - Turn rendering

    /// One turn row in the history feed. Compact mode is a projection of this
    /// row: same prompt/status/error structure, but with only the latest agent
    /// segment visible.
    private func turnRow(_ turn: ConversationTurn) -> some View {
        // O(1) segment → tool-call resolution; matters on tool-heavy turns
        // because every streaming token redraws every visible row.
        let toolCallById: [String: ToolCallRecord] = Dictionary(
            uniqueKeysWithValues: turn.toolCalls.map { ($0.id, $0) }
        )
        let plan = TurnDisplayPlanner.rowPlan(for: turn, mode: displayMode)
        let isCompact = displayMode == .compact

        return VStack(alignment: .leading, spacing: isCompact ? 8 : 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if !isCompact, let icon = turn.context.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 14, height: 14)
                        .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 2 }
                }
                PromptWithChipsView(
                    prompt: plan.prompt,
                    clipboardLabels: plan.clipboardLabels
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if plan.shouldShowAgentStatus {
                HStack(alignment: isCompact ? .firstTextBaseline : .top, spacing: 8) {
                    turnEmojiView(turn)
                        .notchFont(
                            size: isCompact ? contentScale.agentEmojiFontSize : 13,
                            weight: .regular,
                            design: .monospaced
                        )
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 6) {
                        // Segments render in emission order so thinking / tool
                        // calls / reply chunks interleave as the model produced
                        // them. Compact mode receives the same plan, narrowed
                        // to its latest segment by `TurnDisplayPlanner`.
                        ForEach(plan.agentMessages) { segment in
                            if isCompact {
                                CompactAgentMessageSwitcher(
                                    message: segment,
                                    toolCallById: toolCallById,
                                    contentScale: contentScale
                                )
                            } else {
                                displaySegmentView(segment, toolCallById: toolCallById)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if turn.status == .error, let msg = turn.errorMessage, !msg.isEmpty {
                Text(msg)
                    .notchFont(size: isCompact ? 13 : 12, weight: .medium)
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
        .fontWeight(isCompact ? contentScale.fontWeight : nil)
        .padding(.vertical, isCompact ? 12 : 0)
        .padding(.trailing, isCompact ? 4 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func displaySegmentView(
        _ segment: TurnDisplaySegment,
        toolCallById: [String: ToolCallRecord]
    ) -> some View {
        switch segment {
        case .segment(let segment):
            segmentView(segment, toolCallById: toolCallById)
        case .toolRun(let run):
            ToolCallRunSummaryView(
                run: run,
                toolCallById: toolCallById,
                contentScale: contentScale
            )
        }
    }

    @ViewBuilder
    private func segmentView(
        _ segment: TurnSegment,
        toolCallById: [String: ToolCallRecord]
    ) -> some View {
        switch segment {
        case .thinking(let s):
            ThinkingView(
                thinking: s.text,
                startedAt: s.startedAt,
                endedAt: s.endedAt,
                isCurrent: s.isOpenForAppend,
                contentScale: contentScale
            )
        case .toolCall(let id):
            if let record = toolCallById[id] {
                ToolCallView(record: record, contentScale: contentScale)
            }
        case .reply(let s):
            if !s.text.isEmpty {
                ReplyMarkdownView(text: s.text, theme: contentScale.replyTheme)
            }
        }
    }

    /// Per-turn emoji driven by the turn's own status. While the turn
    /// is thinking with no tokens yet, animate a `:/` ↔ `:\` heartbeat.
    @ViewBuilder
    private func turnEmojiView(_ turn: ConversationTurn) -> some View {
        if turn.status == .working && turn.reply.isEmpty && !reduceMotion {
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

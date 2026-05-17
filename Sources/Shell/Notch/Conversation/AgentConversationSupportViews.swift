import SwiftUI

let historyBottomAnchor = "history.bottom"
let historyViewportSpace = "history.viewport"

struct CompactAgentMessageSwitcher: View {
    let message: TurnDisplaySegment
    let toolCallById: [String: ToolCallRecord]
    let contentScale: ConversationContentScale

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var switchState = CompactAgentMessageSwitchState()
    @State private var blurRadius: CGFloat = 0
    @State private var switchTask: Task<Void, Never>?

    var body: some View {
        let renderedMessage = switchState.displayedMessage ?? message
        compactMessageView(renderedMessage)
            .id(renderedMessage.compactRenderID)
            .blur(radius: blurRadius)
            .opacity(blurRadius > 0 ? 0.72 : 1)
            .onAppear {
                switchState.appear(message)
            }
            .onChange(of: message) { _, newMessage in
                handleMessageChange(newMessage)
            }
            .onDisappear {
                switchTask?.cancel()
                switchState.cancelTransition()
            }
    }

    private func handleMessageChange(_ newMessage: TurnDisplaySegment) {
        switch switchState.receive(newMessage, reduceMotion: reduceMotion) {
        case .displayImmediately:
            switchTask?.cancel()
            blurRadius = 0
        case .updatePendingTarget:
            break
        case .startTransition:
            switchToPendingMessage()
        }
    }

    private func switchToPendingMessage() {
        switchTask?.cancel()
        switchTask = Task { @MainActor in
            withAnimation(.easeOut(duration: 0.10)) {
                blurRadius = 14
            }
            try? await Task.sleep(for: .milliseconds(105))
            guard !Task.isCancelled else { return }
            switchState.finishTransition()
            withAnimation(.easeOut(duration: 0.18)) {
                blurRadius = 0
            }
        }
    }

    @ViewBuilder
    private func compactMessageView(_ segment: TurnDisplaySegment) -> some View {
        switch segment {
        case .segment(let segment):
            compactTurnSegmentView(segment)
        case .toolRun(let run):
            ToolCallRunSummaryView(
                run: run,
                toolCallById: toolCallById,
                contentScale: contentScale
            )
        }
    }

    @ViewBuilder
    private func compactTurnSegmentView(_ segment: TurnSegment) -> some View {
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
}

extension TurnDisplaySegment {
    /// Stable SwiftUI identity for compact rendering. Streaming text changes
    /// must update the existing child view so measured state inside
    /// `ThinkingView` is preserved while new rows push old rows upward.
    var compactRenderID: String {
        switch self {
        case .segment(let segment):
            return segment.id
        case .toolRun(let run):
            return run.id
        }
    }
}

enum CompactAgentMessageSwitchDecision: Equatable {
    case displayImmediately
    case startTransition
    case updatePendingTarget
}

struct CompactAgentMessageSwitchState {
    private(set) var displayedMessage: TurnDisplaySegment?
    private(set) var pendingMessage: TurnDisplaySegment?
    private(set) var switchingTargetID: String?

    mutating func appear(_ message: TurnDisplaySegment) {
        if displayedMessage == nil {
            displayedMessage = message
        }
    }

    mutating func receive(
        _ newMessage: TurnDisplaySegment,
        reduceMotion: Bool
    ) -> CompactAgentMessageSwitchDecision {
        if reduceMotion || displayedMessage?.id == newMessage.id {
            displayedMessage = newMessage
            pendingMessage = nil
            switchingTargetID = nil
            return .displayImmediately
        }

        if switchingTargetID == newMessage.id {
            pendingMessage = newMessage
            return .updatePendingTarget
        }

        pendingMessage = newMessage
        switchingTargetID = newMessage.id
        return .startTransition
    }

    mutating func finishTransition() {
        guard let pendingMessage else { return }
        displayedMessage = pendingMessage
        self.pendingMessage = nil
        switchingTargetID = nil
    }

    mutating func cancelTransition() {
        pendingMessage = nil
        switchingTargetID = nil
    }
}

struct ToolCallRunSummaryView: View {
    let run: ToolCallRunSegment
    let toolCallById: [String: ToolCallRecord]
    let contentScale: ConversationContentScale

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    private var records: [ToolCallRecord] {
        run.toolCallIds.compactMap { toolCallById[$0] }
    }

    private var summary: String {
        ToolCallRunSummary.text(for: records)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if reduceMotion {
                    expanded.toggle()
                } else {
                    withAnimation(.notchHeight) {
                        expanded.toggle()
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                        .notchFont(size: contentScale.toolIconSize, weight: contentScale.fontWeight)
                        .notchForeground(.secondary)
                    Text(summary)
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
            .accessibilityLabel(Text(summary))
            .accessibilityHint(Text(expanded ? "Hides tool call details" : "Shows tool call details"))

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(run.segments) { segment in
                        switch segment {
                        case .thinking(let thinking):
                            ThinkingView(
                                thinking: thinking.text,
                                startedAt: thinking.startedAt,
                                endedAt: thinking.endedAt,
                                isCurrent: thinking.isOpenForAppend,
                                contentScale: contentScale
                            )
                        case .toolCall(let id):
                            if let record = toolCallById[id] {
                                ToolCallView(record: record, contentScale: contentScale)
                            }
                        case .reply:
                            EmptyView()
                        }
                    }
                }
                .padding(.leading, 17)
            }
        }
    }
}

struct HistoryHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct HistoryViewportHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct HistoryBottomMaxYKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

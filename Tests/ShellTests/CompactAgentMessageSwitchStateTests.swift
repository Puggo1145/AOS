import Testing
@testable import Shell

@Suite("Compact agent message switch state")
struct CompactAgentMessageSwitchStateTests {
    @Test("streaming updates for pending target do not restart blur transition")
    func streamingUpdatesForPendingTargetDoNotRestartBlurTransition() {
        let thinking = TurnDisplaySegment.segment(.thinking(ThinkingSegment(
            text: "thinking",
            startedAt: .now
        )))
        let partial = TurnDisplaySegment.segment(.reply(ReplySegment(
            id: "reply",
            text: "Hi there! I see you're in Cursor's terminal. How can I"
        )))
        let complete = TurnDisplaySegment.segment(.reply(ReplySegment(
            id: "reply",
            text: "Hi there! I see you're in Cursor's terminal. How can I help you today?"
        )))

        var state = CompactAgentMessageSwitchState()
        state.appear(thinking)

        #expect(state.receive(partial, reduceMotion: false) == .startTransition)
        #expect(state.receive(complete, reduceMotion: false) == .updatePendingTarget)

        state.finishTransition()

        #expect(state.displayedMessage == complete)
    }

    @Test("same displayed message id updates immediately")
    func sameDisplayedMessageIdUpdatesImmediately() {
        let partial = TurnDisplaySegment.segment(.reply(ReplySegment(
            id: "reply",
            text: "How can I"
        )))
        let complete = TurnDisplaySegment.segment(.reply(ReplySegment(
            id: "reply",
            text: "How can I help you today?"
        )))

        var state = CompactAgentMessageSwitchState()
        state.appear(partial)

        #expect(state.receive(complete, reduceMotion: false) == .displayImmediately)

        #expect(state.displayedMessage == complete)
        #expect(state.pendingMessage == nil)
        #expect(state.switchingTargetID == nil)
    }

    @Test("render identity changes when streamed reply text grows")
    func renderIdentityChangesWhenStreamedReplyTextGrows() {
        let partial = TurnDisplaySegment.segment(.reply(ReplySegment(
            id: "reply",
            text: "Hi! 👋 How can I"
        )))
        let complete = TurnDisplaySegment.segment(.reply(ReplySegment(
            id: "reply",
            text: "Hi! 👋 How can I help you today?"
        )))

        #expect(partial.id == complete.id)
        #expect(partial.compactRenderID != complete.compactRenderID)
    }
}

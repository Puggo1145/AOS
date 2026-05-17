import Foundation
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

    @Test("render identity remains stable when streamed reply text grows")
    func renderIdentityRemainsStableWhenStreamedReplyTextGrows() {
        let partial = TurnDisplaySegment.segment(.reply(ReplySegment(
            id: "reply",
            text: "Hi! 👋 How can I"
        )))
        let complete = TurnDisplaySegment.segment(.reply(ReplySegment(
            id: "reply",
            text: "Hi! 👋 How can I help you today?"
        )))

        #expect(partial.id == complete.id)
        #expect(partial.compactRenderID == complete.compactRenderID)
    }

    @Test("render identity remains stable when streamed thinking text grows")
    func renderIdentityRemainsStableWhenStreamedThinkingTextGrows() {
        let startedAt = Date()
        let partial = TurnDisplaySegment.segment(.thinking(ThinkingSegment(
            id: "thinking",
            text: "checking the active app",
            startedAt: startedAt
        )))
        let complete = TurnDisplaySegment.segment(.thinking(ThinkingSegment(
            id: "thinking",
            text: "checking the active app and current window contents",
            startedAt: startedAt
        )))

        #expect(partial.id == complete.id)
        #expect(partial.compactRenderID == complete.compactRenderID)
    }
}

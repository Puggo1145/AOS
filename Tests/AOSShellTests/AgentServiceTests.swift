import Testing
import Foundation
@testable import AOSShell
@testable import AOSRPCSchema

// MARK: - AgentServiceTests
//
// AgentService is a passive mirror of the sidecar's Conversation. These
// tests drive its `internal` notification handlers directly and assert that:
//   - `conversation.turnStarted` materializes a turn in `turns`
//   - `ui.token` deltas land on the matching turn's reply
//   - `ui.status` / `ui.error` patch the matching turn's status + global
//     status emoji, and the global status auto-reverts after the per-revert
//     delay while the turn itself is preserved
//   - `conversation.reset` wipes everything

@MainActor
@Suite("AgentService mirror")
struct AgentServiceTests {

    /// Build a real RPCClient over a closed pipe pair so init() succeeds —
    /// no RPC traffic actually flows in these tests; we exercise handlers
    /// and the test seams directly.
    private func makeService() -> AgentService {
        let inbound = Pipe()
        let outbound = Pipe()
        let rpc = RPCClient(
            inbound: inbound.fileHandleForReading,
            outbound: outbound.fileHandleForWriting
        )
        let session = SessionService(rpc: rpc)
        let store = SessionStore(rpc: rpc, sessionService: session)
        // Pre-adopt a bootstrap session id so the active-mirror projection
        // (`s.status`, `s.turns`, ...) works without driving session.* RPCs.
        store.adoptCreated(SessionListItem(
            id: "S",
            title: "test",
            createdAt: 0,
            turnCount: 0,
            lastActivityAt: 0
        ))
        session.sessionStore = store
        return AgentService(rpc: rpc, sessionStore: store)
    }

    @Test("tokens for unknown turn id are dropped")
    func tokensDroppedForStaleTurn() {
        let s = makeService()
        s.handleToken(UITokenParams(sessionId: "S", turnId: "T1", delta: "hi"))
        #expect(s.turns.isEmpty)
    }

    @Test("conversation.turnStarted appends a turn and flips status to thinking")
    func turnStartedAppends() {
        let s = makeService()
        s._testTurnStarted(id: "T1", prompt: "hi")
        #expect(s.turns.count == 1)
        #expect(s.turns[0].id == "T1")
        #expect(s.turns[0].prompt == "hi")
        #expect(s.currentTurn == "T1")
        #expect(s.status == .thinking)
    }

    @Test("ui.status maps to AgentStatus and updates the matching turn")
    func statusMapping() async throws {
        let s = makeService()
        s._testTurnStarted(id: "T1")
        s.handleStatus(UIStatusParams(sessionId: "S", turnId: "T1", status: .thinking))
        #expect(s.status == .thinking)
        #expect(s.turns.last?.status == .thinking)
        // tool_calling is debounced (~250ms) so a fast tool round doesn't
        // produce a visible `X(` flicker between two `:/` states. After the
        // debounce window elapses without a superseding status, the working
        // glyph lands.
        s.handleStatus(UIStatusParams(sessionId: "S", turnId: "T1", status: .toolCalling))
        #expect(s.status == .thinking)
        #expect(s.turns.last?.status == .thinking)
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(s.status == .working)
        #expect(s.turns.last?.status == .working)
        s.handleStatus(UIStatusParams(sessionId: "S", turnId: "T1", status: .waitingInput))
        #expect(s.status == .waiting)
        #expect(s.turns.last?.status == .waiting)
    }

    @Test("fast tool_calling → thinking does not flicker .working into the UI")
    func toolCallingDebounceCancelled() async throws {
        let s = makeService()
        s._testTurnStarted(id: "T1")
        s.handleStatus(UIStatusParams(sessionId: "S", turnId: "T1", status: .toolCalling))
        // Superseding status arrives well within the 250ms debounce window —
        // matches the "fast local tool" path on the sidecar (tool_calling and
        // thinking emit back-to-back with only millisecond-scale work between).
        try await Task.sleep(nanoseconds: 50_000_000)
        s.handleStatus(UIStatusParams(sessionId: "S", turnId: "T1", status: .thinking))
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(s.status == .thinking)
        #expect(s.turns.last?.status == .thinking)
    }

    @Test("done auto-reverts global status to idle within ~1.5s but keeps the turn")
    func doneRevert() async throws {
        let s = makeService()
        s._testTurnStarted(id: "T2")
        s.handleStatus(UIStatusParams(sessionId: "S", turnId: "T2", status: .done))
        #expect(s.status == .done)
        #expect(s.turns.last?.status == .done)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        // Global status reverts so the closed-bar emoji returns to its
        // resting glyph; the turn's per-turn `status` and `currentTurn` are
        // intentionally retained — the panel keeps the last reply visible
        // until the user fires a new prompt or hits "+" reset.
        #expect(s.status == .idle)
        #expect(s.turns.last?.status == .done)
        #expect(s.currentTurn == "T2")
    }

    @Test("error stamps the turn and auto-reverts global status to idle within ~2.5s")
    func errorRevert() async throws {
        let s = makeService()
        s._testTurnStarted(id: "T3")
        s.handleError(UIErrorParams(sessionId: "S", turnId: "T3", code: -32003, message: "no auth"))
        #expect(s.status == .error)
        #expect(s.turns.last?.errorMessage == "no auth")
        #expect(s.turns.last?.status == .error)
        try await Task.sleep(nanoseconds: 2_500_000_000)
        #expect(s.status == .idle)
        // Per-turn error message persists so the history row keeps its
        // banner.
        #expect(s.turns.last?.errorMessage == "no auth")
    }

    @Test("tokens for the current turn append to its reply")
    func tokensAppend() {
        let s = makeService()
        s._testTurnStarted(id: "T4")
        s.handleToken(UITokenParams(sessionId: "S", turnId: "T4", delta: "Hel"))
        s.handleToken(UITokenParams(sessionId: "S", turnId: "T4", delta: "lo"))
        #expect(s.turns.last?.reply == "Hello")
        // tokens for an unknown turn id drop on the floor; the current
        // turn's reply is unchanged.
        s.handleToken(UITokenParams(sessionId: "S", turnId: "Tstale", delta: "X"))
        #expect(s.turns.last?.reply == "Hello")
    }

    @Test("multiple turns each retain their own reply")
    func multiTurnHistory() {
        let s = makeService()
        s._testTurnStarted(id: "T1", prompt: "first")
        s.handleToken(UITokenParams(sessionId: "S", turnId: "T1", delta: "one"))
        s._testTurnStarted(id: "T2", prompt: "second")
        s.handleToken(UITokenParams(sessionId: "S", turnId: "T2", delta: "two"))
        #expect(s.turns.count == 2)
        #expect(s.turns[0].reply == "one")
        #expect(s.turns[1].reply == "two")
    }

    @Test("conversation.reset wipes turns and resets status")
    func conversationReset() {
        let s = makeService()
        s._testTurnStarted(id: "T1", prompt: "first")
        s.handleToken(UITokenParams(sessionId: "S", turnId: "T1", delta: "one"))
        #expect(s.turns.count == 1)
        s.handleConversationReset(ConversationResetParams(sessionId: "S"))
        #expect(s.turns.isEmpty)
        #expect(s.currentTurn == nil)
        #expect(s.status == .idle)
    }

    @Test("stale status after reset is ignored")
    func staleStatusAfterResetIgnored() {
        let s = makeService()
        s._testTurnStarted(id: "T1")
        s.handleConversationReset(ConversationResetParams(sessionId: "S"))
        s.handleStatus(UIStatusParams(sessionId: "S", turnId: "T1", status: .done))
        #expect(s.status == .idle)
        #expect(s.turns.isEmpty)
    }

    @Test("stale error after reset is ignored")
    func staleErrorAfterResetIgnored() {
        let s = makeService()
        s._testTurnStarted(id: "T1")
        s.handleConversationReset(ConversationResetParams(sessionId: "S"))
        s.handleError(UIErrorParams(sessionId: "S", turnId: "T1", code: -32000, message: "late"))
        #expect(s.status == .idle)
        #expect(s.turns.isEmpty)
    }

    // MARK: - Thinking lifecycle
    //
    // The `ui.thinking` channel carries explicit lifecycle events: `.delta`
    // chunks accumulate the trace and stamp `thinkingStartedAt` on first
    // arrival; `.end` stamps `thinkingEndedAt`. The Shell never infers either
    // transition from neighboring channels (`ui.token`, `ui.status`,
    // `ui.error`) — the sidecar owns the timing.

    @Test("first ui.thinking delta stamps startedAt and accumulates the trace")
    func thinkingDeltaAccumulates() {
        let s = makeService()
        s._testTurnStarted(id: "TH1")
        s.handleThinking(UIThinkingParams(sessionId: "S", turnId: "TH1", kind: .delta, delta: "Considering "))
        s.handleThinking(UIThinkingParams(sessionId: "S", turnId: "TH1", kind: .delta, delta: "the request…"))
        #expect(s.turns.last?.thinking == "Considering the request…")
        #expect(s.turns.last?.thinkingStartedAt != nil)
        #expect(s.turns.last?.thinkingEndedAt == nil)
    }

    @Test("ui.thinking end stamps thinkingEndedAt exactly once")
    func thinkingEndStamps() {
        let s = makeService()
        s._testTurnStarted(id: "TH2")
        s.handleThinking(UIThinkingParams(sessionId: "S", turnId: "TH2", kind: .delta, delta: "x"))
        let firstStart = s.turns.last?.thinkingStartedAt
        s.handleThinking(UIThinkingParams(sessionId: "S", turnId: "TH2", kind: .end))
        let firstEnd = s.turns.last?.thinkingEndedAt
        #expect(firstEnd != nil)
        // A second end must not move the stamp — the lifecycle is a
        // one-shot transition, not a re-trigger.
        s.handleThinking(UIThinkingParams(sessionId: "S", turnId: "TH2", kind: .end))
        #expect(s.turns.last?.thinkingEndedAt == firstEnd)
        #expect(s.turns.last?.thinkingStartedAt == firstStart)
    }

    @Test("ui.token does NOT close thinking — only an explicit end does")
    func tokenDoesNotCloseThinking() {
        let s = makeService()
        s._testTurnStarted(id: "TH3")
        s.handleThinking(UIThinkingParams(sessionId: "S", turnId: "TH3", kind: .delta, delta: "trace"))
        s.handleToken(UITokenParams(sessionId: "S", turnId: "TH3", delta: "reply"))
        // Reply accumulates as expected, but thinking remains open until the
        // sidecar emits `.end`.
        #expect(s.turns.last?.reply == "reply")
        #expect(s.turns.last?.thinkingEndedAt == nil)
    }

    @Test("ui.status .done does NOT close thinking — only an explicit end does")
    func statusDoneDoesNotCloseThinking() {
        let s = makeService()
        s._testTurnStarted(id: "TH4")
        s.handleThinking(UIThinkingParams(sessionId: "S", turnId: "TH4", kind: .delta, delta: "trace"))
        s.handleStatus(UIStatusParams(sessionId: "S", turnId: "TH4", status: .done))
        #expect(s.turns.last?.thinkingEndedAt == nil)
    }

    @Test("stale ui.thinking after reset is ignored")
    func staleThinkingAfterResetIgnored() {
        let s = makeService()
        s._testTurnStarted(id: "TH5")
        s.handleConversationReset(ConversationResetParams(sessionId: "S"))
        s.handleThinking(UIThinkingParams(sessionId: "S", turnId: "TH5", kind: .delta, delta: "late"))
        s.handleThinking(UIThinkingParams(sessionId: "S", turnId: "TH5", kind: .end))
        #expect(s.turns.isEmpty)
    }

    @Test("payload-too-large message names both the actual size and the limit")
    func payloadTooLargeMessageShape() {
        let msg = AgentService.formatPayloadTooLargeMessage(
            bytes: 3 * 1024 * 1024,
            limit: 2 * 1024 * 1024
        )
        // Surfaces both numbers so the user knows how far over the cap they
        // are and what the cap is — vague "too large" copy would force them
        // to guess how much to remove.
        #expect(msg.contains("3.00"))
        #expect(msg.contains("2 MiB"))
    }

    @Test("submit with oversize payload sets lastErrorMessage and surfaces .error")
    func submitOversizeSurfacesUserMessage() async {
        let s = makeService()
        // 3 MiB prompt forces the outbound size guard in RPCClient.request
        // to throw before any byte hits the pipe — exercises the full
        // submit catch path end-to-end (no synthetic error injection).
        let huge = String(repeating: "x", count: 3 * 1024 * 1024)
        await s.submit(prompt: huge, citedContext: CitedContext())
        #expect(s.status == .error)
        #expect(s.lastErrorMessage != nil)
        #expect(s.turns.isEmpty)  // no synthetic turn invented
    }

    @Test("conversation.reset clears lastErrorMessage so the banner disappears")
    func resetClearsLastErrorMessage() async {
        let s = makeService()
        let huge = String(repeating: "x", count: 3 * 1024 * 1024)
        await s.submit(prompt: huge, citedContext: CitedContext())
        #expect(s.lastErrorMessage != nil)
        s.handleConversationReset(ConversationResetParams(sessionId: "S"))
        #expect(s.lastErrorMessage == nil)
    }
}

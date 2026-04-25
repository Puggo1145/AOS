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
        return AgentService(rpc: rpc)
    }

    @Test("tokens for unknown turn id are dropped")
    func tokensDroppedForStaleTurn() {
        let s = makeService()
        s.handleToken(UITokenParams(turnId: "T1", delta: "hi"))
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
    func statusMapping() {
        let s = makeService()
        s._testTurnStarted(id: "T1")
        s.handleStatus(UIStatusParams(turnId: "T1", status: .thinking))
        #expect(s.status == .thinking)
        #expect(s.turns.last?.status == .thinking)
        s.handleStatus(UIStatusParams(turnId: "T1", status: .toolCalling))
        #expect(s.status == .working)
        #expect(s.turns.last?.status == .working)
        s.handleStatus(UIStatusParams(turnId: "T1", status: .waitingInput))
        #expect(s.status == .waiting)
        #expect(s.turns.last?.status == .waiting)
    }

    @Test("done auto-reverts global status to idle within ~1.5s but keeps the turn")
    func doneRevert() async throws {
        let s = makeService()
        s._testTurnStarted(id: "T2")
        s.handleStatus(UIStatusParams(turnId: "T2", status: .done))
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
        s.handleError(UIErrorParams(turnId: "T3", code: -32003, message: "no auth"))
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
        s.handleToken(UITokenParams(turnId: "T4", delta: "Hel"))
        s.handleToken(UITokenParams(turnId: "T4", delta: "lo"))
        #expect(s.turns.last?.reply == "Hello")
        // tokens for an unknown turn id drop on the floor; the current
        // turn's reply is unchanged.
        s.handleToken(UITokenParams(turnId: "Tstale", delta: "X"))
        #expect(s.turns.last?.reply == "Hello")
    }

    @Test("multiple turns each retain their own reply")
    func multiTurnHistory() {
        let s = makeService()
        s._testTurnStarted(id: "T1", prompt: "first")
        s.handleToken(UITokenParams(turnId: "T1", delta: "one"))
        s._testTurnStarted(id: "T2", prompt: "second")
        s.handleToken(UITokenParams(turnId: "T2", delta: "two"))
        #expect(s.turns.count == 2)
        #expect(s.turns[0].reply == "one")
        #expect(s.turns[1].reply == "two")
    }

    @Test("conversation.reset wipes turns and resets status")
    func conversationReset() {
        let s = makeService()
        s._testTurnStarted(id: "T1", prompt: "first")
        s.handleToken(UITokenParams(turnId: "T1", delta: "one"))
        #expect(s.turns.count == 1)
        s.handleConversationReset()
        #expect(s.turns.isEmpty)
        #expect(s.currentTurn == nil)
        #expect(s.status == .idle)
    }

    @Test("stale status after reset is ignored")
    func staleStatusAfterResetIgnored() {
        let s = makeService()
        s._testTurnStarted(id: "T1")
        s.handleConversationReset()
        s.handleStatus(UIStatusParams(turnId: "T1", status: .done))
        #expect(s.status == .idle)
        #expect(s.turns.isEmpty)
    }

    @Test("stale error after reset is ignored")
    func staleErrorAfterResetIgnored() {
        let s = makeService()
        s._testTurnStarted(id: "T1")
        s.handleConversationReset()
        s.handleError(UIErrorParams(turnId: "T1", code: -32000, message: "late"))
        #expect(s.status == .idle)
        #expect(s.turns.isEmpty)
    }
}

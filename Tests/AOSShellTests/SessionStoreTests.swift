import Testing
import Foundation
@testable import AOSShell
@testable import AOSRPCSchema

// MARK: - SessionStoreTests
//
// Cover the SessionStore + ConversationMirror contract that AgentServiceTests
// can't reach because it only exercises a single active mirror:
//
//   1. ui.* notifications routed to an inactive session must NOT pollute the
//      active session's projection (turns / status / lastErrorMessage).
//   2. activate snapshot merge preserves the per-mirror "thinking" fields
//      that are wire-absent (thinking trace + start/end timestamps).
//   3. handleActivated is audit-only — it must NOT flip activeId; that's
//      driven exclusively by the activate response via applyActivate.
//   4. lastActionError surfaces refresh failures via setActionError so UI
//      banners are not swallowed.

@MainActor
@Suite("SessionStore multi-mirror contract")
struct SessionStoreTests {

    /// Build a SessionStore over a closed pipe pair — the rpc client never
    /// makes a live request in these tests; we drive handlers directly.
    private func makeStore() -> (SessionStore, AgentService) {
        let inbound = Pipe()
        let outbound = Pipe()
        let rpc = RPCClient(
            inbound: inbound.fileHandleForReading,
            outbound: outbound.fileHandleForWriting
        )
        let session = SessionService(rpc: rpc)
        let store = SessionStore(rpc: rpc, sessionService: session)
        session.sessionStore = store
        let agent = AgentService(rpc: rpc, sessionStore: store)
        return (store, agent)
    }

    private func turnStarted(_ id: String, sessionId: String, prompt: String = "") -> ConversationTurnStartedParams {
        ConversationTurnStartedParams(
            sessionId: sessionId,
            turn: ConversationTurnWire(
                id: id,
                prompt: prompt,
                citedContext: CitedContext(),
                reply: "",
                status: .working,
                startedAt: 0
            )
        )
    }

    @Test("ui.token for an inactive session does NOT touch the active mirror")
    func inactiveSessionDoesNotPolluteActive() {
        let (store, agent) = makeStore()
        // A is active, B is a background session.
        store.adoptCreated(SessionListItem(
            id: "A", title: "A", createdAt: 0, turnCount: 0, lastActivityAt: 0
        ))
        // Establish a live turn on each.
        agent.handleTurnStarted(turnStarted("Ta", sessionId: "A"))
        agent.handleTurnStarted(turnStarted("Tb", sessionId: "B"))
        // Both mirrors should have their respective turns; only A's projects.
        #expect(agent.turns.count == 1)
        #expect(agent.turns.first?.id == "Ta")

        // Token for B must land on B's mirror, not bleed into A.
        agent.handleToken(UITokenParams(sessionId: "B", turnId: "Tb", delta: "leak"))
        #expect(agent.turns.first?.reply == "")  // active (A) untouched
        #expect(store.mirrors["B"]?.turns.first?.reply == "leak")
    }

    @Test("ui.status .working on inactive session leaves active status unchanged")
    func inactiveStatusDoesNotMoveActiveStatus() async throws {
        let (store, agent) = makeStore()
        store.adoptCreated(SessionListItem(
            id: "A", title: "A", createdAt: 0, turnCount: 0, lastActivityAt: 0
        ))
        agent.handleTurnStarted(turnStarted("Ta", sessionId: "A"))
        agent.handleTurnStarted(turnStarted("Tb", sessionId: "B"))
        // A is .working from its turnStarted; flipping B's status to waiting
        // must not leak into the active projection. Turn status is set
        // immediately; the display `status` is debounced (~250ms).
        agent.handleStatus(UIStatusParams(sessionId: "B", turnId: "Tb", status: .waiting))
        // B's turn has the semantic state immediately.
        #expect(store.mirrors["B"]?.turns.first?.status == .waiting)
        // Wait past the debounce window so the display projection lands too.
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(agent.status == .working)
        #expect(store.mirrors["B"]?.status == .waiting)
    }

    @Test("ui.error on inactive session leaves active error message unchanged")
    func inactiveErrorDoesNotLeakLastErrorMessage() {
        let (store, agent) = makeStore()
        store.adoptCreated(SessionListItem(
            id: "A", title: "A", createdAt: 0, turnCount: 0, lastActivityAt: 0
        ))
        agent.handleTurnStarted(turnStarted("Ta", sessionId: "A"))
        agent.handleTurnStarted(turnStarted("Tb", sessionId: "B"))
        agent.handleError(UIErrorParams(sessionId: "B", turnId: "Tb", code: -32000, message: "B-failed"))
        #expect(agent.lastErrorMessage == nil)
        #expect(store.mirrors["B"]?.turns.first?.errorMessage == "B-failed")
    }

    @Test("activate snapshot preserves per-mirror thinking fields")
    func activateSnapshotPreservesThinking() {
        let (store, agent) = makeStore()
        // Adopt session A and run a turn that accumulates thinking + ends.
        store.adoptCreated(SessionListItem(
            id: "A", title: "A", createdAt: 0, turnCount: 0, lastActivityAt: 0
        ))
        agent.handleTurnStarted(turnStarted("T1", sessionId: "A", prompt: "hi"))
        agent.handleThinking(UIThinkingParams(sessionId: "A", turnId: "T1", kind: .delta, delta: "trace"))
        agent.handleThinking(UIThinkingParams(sessionId: "A", turnId: "T1", kind: .end))
        let beforeStart = store.mirrors["A"]?.turns.first?.thinkingStartedAt
        let beforeEnd = store.mirrors["A"]?.turns.first?.thinkingEndedAt
        let beforeThinking = store.mirrors["A"]?.turns.first?.thinking
        #expect(beforeStart != nil)
        #expect(beforeEnd != nil)
        #expect(beforeThinking == "trace")

        // Switch to B and back — the activate response carries a snapshot
        // of A's turns, but `thinking*` fields are wire-absent. The merge
        // contract says they MUST be preserved on the existing mirror.
        store.adoptCreated(SessionListItem(
            id: "B", title: "B", createdAt: 0, turnCount: 0, lastActivityAt: 0
        ))
        // Build a wire snapshot for A as the sidecar would on activate.
        let snapshot: [ConversationTurnWire] = [
            ConversationTurnWire(
                id: "T1",
                prompt: "hi",
                citedContext: CitedContext(),
                reply: "",
                status: .done,
                startedAt: 0
            )
        ]
        store.applyActivate(sessionId: "A", snapshot: snapshot)
        let after = store.mirrors["A"]?.turns.first
        // Sidecar-authoritative status came from the wire (.done).
        #expect(after?.status == .done)
        // Mirror-only thinking fields were preserved across the merge.
        #expect(after?.thinkingStartedAt == beforeStart)
        #expect(after?.thinkingEndedAt == beforeEnd)
        #expect(after?.thinking == "trace")
    }

    @Test("applyActivate flips activeId atomically with the merge")
    func applyActivateFlipsActiveId() {
        let (store, _) = makeStore()
        store.adoptCreated(SessionListItem(
            id: "A", title: "A", createdAt: 0, turnCount: 0, lastActivityAt: 0
        ))
        #expect(store.activeId == "A")
        let snapshot: [ConversationTurnWire] = [
            ConversationTurnWire(
                id: "Tb1",
                prompt: "from B",
                citedContext: CitedContext(),
                reply: "previous",
                status: .done,
                startedAt: 0
            )
        ]
        store.applyActivate(sessionId: "B", snapshot: snapshot)
        #expect(store.activeId == "B")
        // The merged turn is observable on the (now active) mirror.
        #expect(store.activeMirror?.turns.first?.reply == "previous")
    }

    @Test("handleActivated notification does NOT flip activeId (audit-only)")
    func handleActivatedIsAuditOnly() {
        let (store, _) = makeStore()
        store.adoptCreated(SessionListItem(
            id: "A", title: "A", createdAt: 0, turnCount: 0, lastActivityAt: 0
        ))
        #expect(store.activeId == "A")
        // Sidecar emits session.activated for B before the activate response
        // lands. With the new contract the notification only ensures the
        // mirror exists; the activeId flip is owned by applyActivate.
        store.handleActivated(SessionActivatedNotificationParams(sessionId: "B"))
        #expect(store.activeId == "A")
        #expect(store.mirrors["B"] != nil)
    }

    @Test("lastActionError surfaces and clears via setActionError")
    func lastActionErrorRoundTrip() {
        let (store, _) = makeStore()
        #expect(store.lastActionError == nil)
        store.setActionError(SessionActionError(
            kind: .activate,
            message: "broken",
            sessionId: "X"
        ))
        #expect(store.lastActionError?.kind == .activate)
        #expect(store.lastActionError?.message == "broken")
        store.setActionError(nil)
        #expect(store.lastActionError == nil)
    }

    @Test("applyListResult does NOT touch activeId even when sidecar disagrees")
    func refreshSuccessLeavesActiveIdAlone() {
        let (store, _) = makeStore()
        store.adoptCreated(SessionListItem(
            id: "A", title: "A", createdAt: 0, turnCount: 0, lastActivityAt: 0
        ))
        #expect(store.activeId == "A")
        // Sidecar reports a different activeId (e.g. listChanged interleaves
        // with an in-flight activate response). Per the single-source
        // contract, only activate/create responses may flip activeId; refresh
        // must leave it alone or we reintroduce the very race we removed.
        let result = SessionListResult(
            activeId: "B",
            sessions: [
                SessionListItem(id: "A", title: "A", createdAt: 0, turnCount: 0, lastActivityAt: 0),
                SessionListItem(id: "B", title: "B", createdAt: 1, turnCount: 0, lastActivityAt: 1)
            ]
        )
        store.applyListResult(result)
        #expect(store.activeId == "A")
        // List is updated and the previously-unknown B has a mirror so
        // ui.* routing under id B has a target.
        #expect(store.list.map(\.id) == ["A", "B"])
        #expect(store.mirrors["B"] != nil)
    }

    @Test("applyListResult clears a stale lastActionError on success")
    func refreshSuccessClearsActionError() {
        let (store, _) = makeStore()
        store.setActionError(SessionActionError(
            kind: .list,
            message: "previous failure",
            sessionId: nil
        ))
        #expect(store.lastActionError != nil)
        // The next successful action — including a list refresh — must clear
        // the banner. Otherwise a stale error lingers after the user has
        // already recovered.
        store.applyListResult(SessionListResult(activeId: nil, sessions: []))
        #expect(store.lastActionError == nil)
    }

    @Test("adoptCreated does not duplicate an already-listed session")
    func adoptCreatedDoesNotDuplicate() {
        let (store, _) = makeStore()
        let item = SessionListItem(
            id: "A", title: "A", createdAt: 0, turnCount: 0, lastActivityAt: 0
        )
        store.adoptCreated(item)
        // A second adopt (e.g. test driving create twice) replaces in place
        // rather than appending — duplicates would render twice in History.
        store.adoptCreated(SessionListItem(
            id: "A", title: "A renamed", createdAt: 0, turnCount: 1, lastActivityAt: 5
        ))
        #expect(store.list.count == 1)
        #expect(store.list.first?.title == "A renamed")
        #expect(store.list.first?.turnCount == 1)
    }
}

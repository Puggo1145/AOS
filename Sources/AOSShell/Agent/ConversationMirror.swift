import Foundation
import AOSRPCSchema

// MARK: - ConversationMirror
//
// Per-session mirror of the sidecar's conversation. Each instance corresponds
// to one `sessionId`; the `SessionStore` owns the `[SessionId: ConversationMirror]`
// dictionary and routes inbound `ui.*` / `conversation.*` notifications by the
// `sessionId` field on each frame.
//
// Per docs/designs/session-management.md "Snapshot merge 契约":
//   - sidecar-authoritative fields (reply / status / errorMessage / errorCode /
//     citedContext / startedAt) are overwritten by `session.activate` snapshots
//   - mirror-only display fields (`thinking` / `thinkingStartedAt` /
//     `thinkingEndedAt`) are NOT carried on the wire and must be preserved
//     across activate transitions
//
// Revert tasks live here, not on `SessionStore`, so an inactive session's
// `done`/`error` revert can still flip its own per-turn glyph without
// touching the global UI.

@MainActor
@Observable
public final class ConversationMirror {
    public let sessionId: String
    public var turns: [ConversationTurn] = []
    public var currentTurn: String?
    public var status: AgentStatus = .idle
    public var lastErrorMessage: String?

    private var doneRevertTask: Task<Void, Never>?
    private var errorRevertTask: Task<Void, Never>?

    public init(sessionId: String) {
        self.sessionId = sessionId
    }

    // MARK: - Notification application

    public func applyTurnStarted(_ p: ConversationTurnStartedParams) {
        let snapshot = ContextSnapshot.from(citedContext: p.turn.citedContext)
        let local = ConversationTurn(
            id: p.turn.id,
            prompt: p.turn.prompt,
            context: snapshot,
            reply: p.turn.reply,
            status: AgentStatus.from(turnStatus: p.turn.status),
            errorMessage: p.turn.errorMessage
        )
        if let existing = turns.firstIndex(where: { $0.id == local.id }) {
            turns[existing] = local
        } else {
            turns.append(local)
        }
        currentTurn = p.turn.id
        status = .thinking
        cancelReverts()
    }

    public func applyConversationReset() {
        currentTurn = nil
        turns = []
        status = .idle
        lastErrorMessage = nil
        cancelReverts()
    }

    public func applyToken(_ p: UITokenParams) {
        guard let idx = turns.lastIndex(where: { $0.id == p.turnId }) else { return }
        turns[idx].reply.append(p.delta)
    }

    public func applyThinking(_ p: UIThinkingParams) {
        guard let idx = turns.lastIndex(where: { $0.id == p.turnId }) else { return }
        switch p.kind {
        case .delta:
            if turns[idx].thinkingStartedAt == nil {
                turns[idx].thinkingStartedAt = Date()
            }
            // Wire decoder rejects `.delta` without a delta string, so the
            // force-unwrap matches the Codable contract — see UI.swift.
            turns[idx].thinking.append(p.delta!)
        case .end:
            if turns[idx].thinkingStartedAt != nil && turns[idx].thinkingEndedAt == nil {
                turns[idx].thinkingEndedAt = Date()
            }
        }
    }

    public func applyToolCall(_ p: UIToolCallParams) {
        guard let idx = turns.lastIndex(where: { $0.id == p.turnId }) else { return }
        switch p.phase {
        case .called:
            // Wire decoder rejects `.called` without `args`, so the
            // force-unwrap matches the Codable contract — see UI.swift.
            let record = ToolCallRecord(
                id: p.toolCallId,
                name: p.toolName,
                args: p.args!,
                status: .calling,
                isError: nil,
                outputText: nil
            )
            // Idempotent on duplicate `.called` for the same id (shouldn't
            // happen in practice; the sidecar emits exactly once per call).
            if let existing = turns[idx].toolCalls.firstIndex(where: { $0.id == p.toolCallId }) {
                turns[idx].toolCalls[existing] = record
            } else {
                turns[idx].toolCalls.append(record)
            }
        case .result:
            // `.result` for an unknown id can happen if a `conversation.reset`
            // races with an in-flight tool call — drop silently rather than
            // synthesizing a record without args.
            guard let recIdx = turns[idx].toolCalls.firstIndex(where: { $0.id == p.toolCallId }) else {
                return
            }
            turns[idx].toolCalls[recIdx].status = .completed
            turns[idx].toolCalls[recIdx].isError = p.isError
            turns[idx].toolCalls[recIdx].outputText = p.outputText
        case .rejected:
            // Argument validation failed in the sidecar — the handler never
            // ran, so there is no prior `.called` record to update. Synthesize
            // a completed isError record from this single frame so the user
            // can see what the model tried to call and why it was refused.
            // Wire decoder rejects `.rejected` without `args`/`errorMessage`,
            // so the force-unwraps match the Codable contract — see UI.swift.
            let record = ToolCallRecord(
                id: p.toolCallId,
                name: p.toolName,
                args: p.args!,
                status: .completed,
                isError: true,
                outputText: p.errorMessage!
            )
            // Idempotent on the (rare) duplicate emit.
            if let existing = turns[idx].toolCalls.firstIndex(where: { $0.id == p.toolCallId }) {
                turns[idx].toolCalls[existing] = record
            } else {
                turns[idx].toolCalls.append(record)
            }
        }
    }

    public func applyStatus(_ p: UIStatusParams) {
        guard let idx = turns.lastIndex(where: { $0.id == p.turnId }) else { return }
        let mapped = AgentStatus.from(uiStatus: p.status)
        turns[idx].status = mapped
        status = mapped
        switch p.status {
        case .done: scheduleDoneRevert()
        default: cancelReverts()
        }
    }

    public func applyError(_ p: UIErrorParams) {
        guard let idx = turns.lastIndex(where: { $0.id == p.turnId }) else { return }
        turns[idx].status = .error
        turns[idx].errorMessage = p.message
        status = .error
        scheduleErrorRevert()
    }

    /// Stamp a submit-time error that occurred before any turn was registered
    /// (e.g. payload too large). The `lastErrorMessage` banner is what the
    /// open-panel reads when there is no per-turn slot to attach it to.
    public func setSubmitError(_ message: String?) {
        lastErrorMessage = message
        if message != nil {
            status = .error
            scheduleErrorRevert()
        }
    }

    public func clearSubmitError() {
        lastErrorMessage = nil
    }

    // MARK: - Snapshot merge
    //
    // Called from `session.activate`. Per the design contract:
    //   - For each wire turn: replace sidecar-authoritative fields; keep the
    //     mirror's `thinking` / `thinkingStartedAt` / `thinkingEndedAt` if a
    //     turn with the same id was already on this mirror.
    //   - Wire-absent turns currently in the mirror are dropped — the sidecar
    //     is the source of truth for which turns exist on a session.
    //
    // First-activate path (mirror is empty) reduces to "build fresh ConversationTurn
    // entries from the wire snapshot" naturally.
    public func mergeActivateSnapshot(_ snapshot: [ConversationTurnWire]) {
        var merged: [ConversationTurn] = []
        merged.reserveCapacity(snapshot.count)
        for wire in snapshot {
            let context = ContextSnapshot.from(citedContext: wire.citedContext)
            let existing = turns.first(where: { $0.id == wire.id })
            var t = ConversationTurn(
                id: wire.id,
                prompt: wire.prompt,
                context: context,
                reply: wire.reply,
                status: AgentStatus.from(turnStatus: wire.status),
                errorMessage: wire.errorMessage
            )
            if let existing {
                // Mirror-only display fields are wire-absent — preserve them.
                t.thinking = existing.thinking
                t.thinkingStartedAt = existing.thinkingStartedAt
                t.thinkingEndedAt = existing.thinkingEndedAt
            }
            merged.append(t)
        }
        turns = merged
        // Sidecar drives `currentTurn` via `conversation.turnStarted`; on first
        // activate of a session that already has in-flight turns we surface the
        // last non-terminal one so the closed-bar emoji is meaningful.
        currentTurn = merged.last(where: {
            $0.status == .thinking || $0.status == .working || $0.status == .waiting
        })?.id
        // Resting glyph is the safer default; status will flip on the next
        // notification if a turn is genuinely live.
        status = currentTurn == nil ? .idle : .thinking
        cancelReverts()
    }

    // MARK: - Revert timers

    private func scheduleDoneRevert() {
        doneRevertTask?.cancel()
        doneRevertTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            await MainActor.run { self.status = .idle }
        }
    }

    private func scheduleErrorRevert() {
        errorRevertTask?.cancel()
        errorRevertTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self else { return }
            await MainActor.run { self.status = .idle }
        }
    }

    private func cancelReverts() {
        doneRevertTask?.cancel()
        errorRevertTask?.cancel()
        doneRevertTask = nil
        errorRevertTask = nil
    }
}

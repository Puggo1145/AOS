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
    /// Debounce for `.waiting` transitions. The sidecar emits
    /// `ui.status waiting` before each tool round and `working` again
    /// after the round completes; for fast tools (local file ops, small
    /// subprocesses) this window is milliseconds and the waiting glyph would
    /// flash visibly between two `:/` states. We delay applying `.waiting`
    /// so only tools that actually take time produce the visible swap.
    private var waitingDebounceTask: Task<Void, Never>?
    private static let waitingDebounceNanos: UInt64 = 250_000_000

    public init(sessionId: String) {
        self.sessionId = sessionId
    }

    // MARK: - Notification application

    public func applyTurnStarted(_ p: ConversationTurnStartedParams) {
        let snapshot = ContextSnapshot.from(citedContext: p.turn.citedContext)
        var local = ConversationTurn(
            id: p.turn.id,
            prompt: p.turn.prompt,
            context: snapshot,
            reply: p.turn.reply,
            status: AgentStatus.from(turnStatus: p.turn.status),
            errorMessage: p.turn.errorMessage
        )
        if !local.reply.isEmpty {
            local.segments.append(.reply(ReplySegment(text: local.reply)))
        }
        if let existing = turns.firstIndex(where: { $0.id == local.id }) {
            turns[existing] = local
        } else {
            turns.append(local)
        }
        currentTurn = p.turn.id
        status = .working
        cancelReverts()
        cancelWaitingDebounce()
    }

    public func applyConversationReset() {
        currentTurn = nil
        turns = []
        status = .idle
        lastErrorMessage = nil
        cancelReverts()
        cancelWaitingDebounce()
    }

    public func applyToken(_ p: UITokenParams) {
        guard let idx = turns.lastIndex(where: { $0.id == p.turnId }) else { return }
        turns[idx].reply.append(p.delta)
        // Reply tokens mark any open thinking segment as no longer accepting
        // appends (a later thinking burst opens a new segment), but DO NOT
        // stamp `endedAt` — the explicit `ui.thinking.end` lifecycle is the
        // sole authority for that. See ThinkingSegment.isOpenForAppend.
        markCurrentThinkingNotAppendable(in: &turns[idx])
        appendReplyDelta(&turns[idx], delta: p.delta)
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
            let delta = p.delta!
            turns[idx].thinking.append(delta)
            appendThinkingDelta(&turns[idx], delta: delta)
        case .end:
            if turns[idx].thinkingStartedAt != nil && turns[idx].thinkingEndedAt == nil {
                turns[idx].thinkingEndedAt = Date()
            }
            endCurrentThinking(in: &turns[idx])
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
            // A tool call ends both the current thinking burst (the model has
            // chosen its action) and the current reply burst (subsequent text
            // belongs to a fresh segment after the tool result).
            // Tool call landing is the same signal as a reply token: the
            // current thinking segment stops accepting deltas, but its
            // `endedAt` waits for the explicit lifecycle frame.
            markCurrentThinkingNotAppendable(in: &turns[idx])
            appendToolCallSegment(&turns[idx], id: p.toolCallId)
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
            // Tool call landing is the same signal as a reply token: the
            // current thinking segment stops accepting deltas, but its
            // `endedAt` waits for the explicit lifecycle frame.
            markCurrentThinkingNotAppendable(in: &turns[idx])
            appendToolCallSegment(&turns[idx], id: p.toolCallId)
        }
    }

    // MARK: - Segment helpers

    private func appendThinkingDelta(_ turn: inout ConversationTurn, delta: String) {
        // Extend the current segment only if it's still open for appends. A
        // segment with `isOpenForAppend == false` was retired by an
        // intervening reply/tool, even if its `endedAt` is still nil pending
        // the explicit `.end` frame.
        if case .thinking(var seg) = turn.segments.last, seg.isOpenForAppend {
            seg.text.append(delta)
            turn.segments[turn.segments.count - 1] = .thinking(seg)
        } else {
            let seg = ThinkingSegment(text: delta, startedAt: Date())
            turn.segments.append(.thinking(seg))
        }
    }

    private func appendReplyDelta(_ turn: inout ConversationTurn, delta: String) {
        if case .reply(var seg) = turn.segments.last {
            seg.text.append(delta)
            turn.segments[turn.segments.count - 1] = .reply(seg)
        } else {
            turn.segments.append(.reply(ReplySegment(text: delta)))
        }
    }

    private func appendToolCallSegment(_ turn: inout ConversationTurn, id: String) {
        // Idempotent: skip if the same tool call id is already segmented
        // (matches the dedupe on `toolCalls`).
        if turn.segments.contains(where: {
            if case .toolCall(let existing) = $0, existing == id { return true }
            return false
        }) { return }
        turn.segments.append(.toolCall(id: id))
    }

    /// Reply / tool arrival: the current thinking burst is no longer the
    /// active one (any further `.delta` opens a new segment), but its
    /// lifecycle `endedAt` belongs to the explicit `.end` frame.
    private func markCurrentThinkingNotAppendable(in turn: inout ConversationTurn) {
        for i in stride(from: turn.segments.count - 1, through: 0, by: -1) {
            if case .thinking(var seg) = turn.segments[i] {
                if seg.isOpenForAppend {
                    seg.isOpenForAppend = false
                    turn.segments[i] = .thinking(seg)
                }
                return
            }
        }
    }

    /// Explicit `ui.thinking.end`: stamp `endedAt` on the most recent
    /// thinking segment that's still missing one. Also flips
    /// `isOpenForAppend` defensively for the case where `.end` arrives
    /// before any reply/tool would have done it.
    private func endCurrentThinking(in turn: inout ConversationTurn) {
        for i in stride(from: turn.segments.count - 1, through: 0, by: -1) {
            if case .thinking(var seg) = turn.segments[i] {
                if seg.endedAt == nil {
                    seg.endedAt = Date()
                }
                seg.isOpenForAppend = false
                turn.segments[i] = .thinking(seg)
                return
            }
        }
    }

    public func applyStatus(_ p: UIStatusParams) {
        guard let idx = turns.lastIndex(where: { $0.id == p.turnId }) else { return }
        let mapped = AgentStatus.from(uiStatus: p.status)
        cancelWaitingDebounce()
        // Semantic state is always applied immediately — the turn record
        // must reflect the sidecar's authoritative status at all times.
        turns[idx].status = mapped
        if mapped == .waiting {
            // Display projection is debounced: fast tools emit waiting →
            // working back-to-back; showing `:?` for milliseconds is flicker.
            scheduleWaitingDebounce()
            cancelReverts()
            return
        }
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
        cancelWaitingDebounce()
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
                t.toolCalls = existing.toolCalls
                t.segments = existing.segments
                // The wire `reply` is authoritative: if it has grown beyond
                // what our last reply segment captured, append the delta into
                // the existing reply segment so render order is preserved.
                let mirroredReplyLength = existing.segments.reduce(0) { acc, seg in
                    if case .reply(let r) = seg { return acc + r.text.count }
                    return acc
                }
                if t.reply.count > mirroredReplyLength {
                    let delta = String(t.reply.suffix(t.reply.count - mirroredReplyLength))
                    appendReplyDelta(&t, delta: delta)
                }
            } else if !t.reply.isEmpty {
                // First-activate path: no segment history — surface the
                // accumulated reply as one segment.
                t.segments.append(.reply(ReplySegment(text: t.reply)))
            }
            merged.append(t)
        }
        turns = merged
        // Sidecar drives `currentTurn` via `conversation.turnStarted`; on first
        // activate of a session that already has in-flight turns we surface the
        // last non-terminal one so the closed-bar emoji is meaningful.
        let liveTurn = merged.last(where: {
            $0.status == .working || $0.status == .waiting
        })
        currentTurn = liveTurn?.id
        status = liveTurn?.status ?? .idle
        cancelReverts()
        cancelWaitingDebounce()
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

    private func scheduleWaitingDebounce() {
        waitingDebounceTask?.cancel()
        waitingDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.waitingDebounceNanos)
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                self.status = .waiting
            }
        }
    }

    private func cancelWaitingDebounce() {
        waitingDebounceTask?.cancel()
        waitingDebounceTask = nil
    }
}

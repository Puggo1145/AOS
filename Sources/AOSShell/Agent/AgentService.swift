import Foundation
import AppKit
import AOSRPCSchema

// MARK: - AgentStatus
//
// View-facing status enum mirrors `AOSRPCSchema.TurnStatus` plus a couple of
// view-local synthetic states (`idle`, `listening`). `listening` is NOT
// pushed by the sidecar — it's a view-local override that the panel applies
// when the input field is focused (per notch-ui.md "AgentStatus → 颜文字映射").

public enum AgentStatus: Sendable, Equatable {
    case idle
    case listening
    case thinking
    case working
    case done
    case waiting
    case error

    // MARK: - Centralized wire ↔ view mapping
    //
    // The Shell carries three status enums that all describe the same agent:
    //   - `AOSRPCSchema.UIStatus`   — `ui.status` notification payload
    //   - `AOSRPCSchema.TurnStatus` — per-turn state inside a `ConversationTurnWire`
    //   - `AgentService.AgentStatus` — the view-facing status (adds idle / listening)
    //
    // Mapping was previously duplicated in two places inside `AgentService`. We
    // centralize both projections here so any future status name change has a
    // single edit site and the mapping rules stay in one file.

    /// Project a sidecar `ui.status` value to the view-facing enum. The wire
    /// vocabulary is smaller — `idle` / `listening` / `error` are view-local
    /// states the sidecar never emits.
    public static func from(uiStatus: UIStatus) -> AgentStatus {
        switch uiStatus {
        case .thinking:     return .thinking
        case .toolCalling:  return .working
        case .waitingInput: return .waiting
        case .done:         return .done
        }
    }

    /// Project a sidecar `TurnStatus` (snapshot inside `ConversationTurnWire`)
    /// to the view-facing enum. `cancelled` collapses to `.idle` because the
    /// view does not have a dedicated cancelled glyph — the closed-bar emoji
    /// goes back to its resting state.
    public static func from(turnStatus: TurnStatus) -> AgentStatus {
        switch turnStatus {
        case .thinking: return .thinking
        case .working:  return .working
        case .waiting:  return .waiting
        case .done:     return .done
        case .error:    return .error
        case .cancelled: return .idle
        }
    }
}

// MARK: - ConversationTurn (Shell display projection)
//
// Sidecar is the single source of truth for the conversation: it owns the
// `Conversation` store and the LLM-facing message history, broadcasts
// `conversation.turnStarted` / `ui.token` / `ui.status` / `ui.error` /
// `conversation.reset`. AgentService maintains a local mirror only for
// rendering; every mutation here is driven by an inbound notification.
//
// `context` is decoded once from the wire `CitedContext.app.iconPNG` so the
// panel can draw an `NSImage` without re-decoding base64 on each redraw.

@MainActor
public struct ConversationTurn: Identifiable {
    public let id: String
    public let prompt: String
    public let context: ContextSnapshot
    public var reply: String
    public var status: AgentStatus
    public var errorMessage: String?
    /// Accumulated reasoning trace streamed via `ui.thinking`. Empty when
    /// the model is non-reasoning or has not yet emitted any thinking.
    public var thinking: String = ""
    /// Wall-clock instant the first `ui.thinking` delta arrived. `nil`
    /// until then. Used together with `thinkingEndedAt` to compute the
    /// "thought for X seconds" label.
    public var thinkingStartedAt: Date?
    /// Wall-clock instant thinking finished — set when the first reply
    /// token arrives, or when the turn reaches a terminal status while
    /// thinking is still open. `nil` while thinking is in progress.
    public var thinkingEndedAt: Date?
}

/// Display-side snapshot of the citedContext attached to a turn. The icon is
/// reconstituted from the wire's base64 PNG so the UI can render it as an
/// NSImage; behavior summaries are passed through as-is.
@MainActor
public struct ContextSnapshot {
    public let appName: String?
    public let appIcon: NSImage?
    public let behaviorSummaries: [String]
    /// Per-clipboard short label, indexed to match `[[clipboard:N]]`
    /// markers in the prompt. The history row uses these to render an
    /// inline chip badge in place of the raw marker.
    public let clipboardLabels: [String]

    public init(
        appName: String?,
        appIcon: NSImage?,
        behaviorSummaries: [String],
        clipboardLabels: [String] = []
    ) {
        self.appName = appName
        self.appIcon = appIcon
        self.behaviorSummaries = behaviorSummaries
        self.clipboardLabels = clipboardLabels
    }

    /// Build from the wire `CitedContext`. Decodes `app.iconPNG` (base64) into
    /// an NSImage if present; otherwise leaves `appIcon` nil and the panel
    /// falls back to its no-icon layout.
    public static func from(citedContext: CitedContext) -> ContextSnapshot {
        let icon: NSImage?
        if let b64 = citedContext.app?.iconPNG, let data = Data(base64Encoded: b64) {
            icon = NSImage(data: data)
        } else {
            icon = nil
        }
        let clipLabels: [String] = citedContext.clipboards?.map(clipboardLabel(for:)) ?? []
        return ContextSnapshot(
            appName: citedContext.app?.name,
            appIcon: icon,
            behaviorSummaries: citedContext.behaviors?.map { $0.displaySummary } ?? [],
            clipboardLabels: clipLabels
        )
    }
}

/// Mirror of the input-side chip label so the live composer and the
/// history row read the same. Kept here (not in ChipInputView) because
/// ContextSnapshot is the wire-decoded shape that drives display.
private func clipboardLabel(for clip: CitedClipboard) -> String {
    switch clip {
    case .text(let s):
        return "Pasted \(s.count) chars"
    case .filePaths(let paths):
        return paths.count == 1 ? "Pasted file" : "Pasted \(paths.count) files"
    case .image:
        return "Pasted image"
    }
}

// MARK: - AgentService
//
// Thin observable mirror of the sidecar's Conversation. Per the architectural
// correction: the conversation history (turns + LLM-facing messages) is
// owned exclusively by the sidecar's `agent/conversation.ts`. This class
// does not allocate turn ids, does not append turns on submit, and does not
// derive LLM-relevant state. It only:
//
//   - `submit(prompt:citedContext:)` → fires `agent.submit` over RPC.
//   - `cancel()` → fires `agent.cancel`.
//   - `resetSession()` → fires `agent.reset` (sidecar will broadcast
//     `conversation.reset` on success, which clears the mirror).
//   - subscribes to `conversation.turnStarted`, `ui.token`, `ui.status`,
//     `ui.error`, `conversation.reset` and reflects them into `turns`.
//
// Status reverts:
//   - `done` and `error` flip the global `status` back to `idle` after a
//     short delay so the closed-bar emoji returns to its resting glyph. The
//     per-turn `status` and the `turns` array are intentionally untouched —
//     the panel keeps the last reply visible until a new prompt is submitted
//     or the user hits "+" reset (which calls `agent.reset`).

@MainActor
@Observable
public final class AgentService {
    public private(set) var turns: [ConversationTurn] = []
    public private(set) var currentTurn: String?
    public private(set) var status: AgentStatus = .idle
    /// Set when a submit-time failure occurs *before* a turn exists — for
    /// example an outbound payload that exceeds the RPC line cap. Cleared on
    /// the next successful submit or `resetSession()`. The Notch panel reads
    /// this to surface a user-visible banner since there is no per-turn slot
    /// to attach the message to in this case.
    public private(set) var lastErrorMessage: String?

    private let rpc: RPCClient
    private var doneRevertTask: Task<Void, Never>?
    private var errorRevertTask: Task<Void, Never>?

    public init(rpc: RPCClient) {
        self.rpc = rpc
        registerHandlers()
    }

    private func registerHandlers() {
        rpc.registerNotificationHandler(method: RPCMethod.conversationTurnStarted) {
            [weak self] (params: ConversationTurnStartedParams) in
            await self?.handleTurnStarted(params)
        }
        rpc.registerNotificationHandler(method: RPCMethod.conversationReset) {
            [weak self] (_: ConversationResetParams) in
            await self?.handleConversationReset()
        }
        rpc.registerNotificationHandler(method: RPCMethod.uiToken) { [weak self] (params: UITokenParams) in
            await self?.handleToken(params)
        }
        rpc.registerNotificationHandler(method: RPCMethod.uiThinking) { [weak self] (params: UIThinkingParams) in
            await self?.handleThinking(params)
        }
        rpc.registerNotificationHandler(method: RPCMethod.uiStatus) { [weak self] (params: UIStatusParams) in
            await self?.handleStatus(params)
        }
        rpc.registerNotificationHandler(method: RPCMethod.uiError) { [weak self] (params: UIErrorParams) in
            await self?.handleError(params)
        }
    }

    // MARK: - Public API

    public func submit(prompt: String, citedContext: CitedContext) async {
        let turnId = UUID().uuidString
        do {
            _ = try await rpc.request(
                method: RPCMethod.agentSubmit,
                params: AgentSubmitParams(
                    turnId: turnId,
                    prompt: prompt,
                    citedContext: citedContext
                ),
                as: AgentSubmitResult.self
            )
            lastErrorMessage = nil
            // ack only — the turn appears in `turns` once the sidecar
            // broadcasts `conversation.turnStarted`.
        } catch let RPCClientError.outboundPayloadTooLarge(_, bytes, limit) {
            // The composed prompt + cited context exceeded the NDJSON line
            // cap. The request was rejected before any byte hit the wire, so
            // the sidecar transport is unaffected. Surface a precise message
            // so the user knows to remove pasted content rather than retry
            // blindly.
            lastErrorMessage = Self.formatPayloadTooLargeMessage(bytes: bytes, limit: limit)
            status = .error
            scheduleErrorRevert()
        } catch {
            // Transport / handler-level failure before the sidecar ever
            // registered the turn. Surface as a global error indicator
            // without inventing a synthetic turn (the sidecar wouldn't
            // know about it, so a turn here would diverge from history).
            lastErrorMessage = nil
            status = .error
            scheduleErrorRevert()
        }
    }

    internal static func formatPayloadTooLargeMessage(bytes: Int, limit: Int) -> String {
        let mib = Double(bytes) / (1024.0 * 1024.0)
        let limitMib = Double(limit) / (1024.0 * 1024.0)
        return String(
            format: "Context payload is %.2f MiB, exceeding the %.0f MiB transport limit. Remove some pasted content or shorten the selected text and try again.",
            mib, limitMib
        )
    }

    /// Wipe the conversation. Delegates to the sidecar; the resulting
    /// `conversation.reset` notification clears `turns` locally. Optimistic
    /// local clearing is intentionally avoided — keeping a single source of
    /// truth means the UI updates only when the sidecar confirms.
    public func resetSession() async {
        _ = try? await rpc.request(
            method: RPCMethod.agentReset,
            params: AgentResetParams(),
            as: AgentResetResult.self
        )
    }

    public func cancel() async {
        guard let turnId = currentTurn else { return }
        _ = try? await rpc.request(
            method: RPCMethod.agentCancel,
            params: AgentCancelParams(turnId: turnId),
            as: AgentCancelResult.self
        )
    }

    // MARK: - Notification handlers

    /// Visible to tests via `@testable import` so synthetic notifications can
    /// drive the state machine without a real RPCClient.
    internal func handleTurnStarted(_ p: ConversationTurnStartedParams) {
        let snapshot = ContextSnapshot.from(citedContext: p.turn.citedContext)
        let local = ConversationTurn(
            id: p.turn.id,
            prompt: p.turn.prompt,
            context: snapshot,
            reply: p.turn.reply,
            status: AgentStatus.from(turnStatus: p.turn.status),
            errorMessage: p.turn.errorMessage
        )
        // Defensive: if the sidecar reuses an id (it won't in normal flow),
        // replace rather than duplicate.
        if let existing = turns.firstIndex(where: { $0.id == local.id }) {
            turns[existing] = local
        } else {
            turns.append(local)
        }
        currentTurn = p.turn.id
        status = .thinking
        cancelReverts()
    }

    internal func handleConversationReset() {
        currentTurn = nil
        turns = []
        status = .idle
        lastErrorMessage = nil
        cancelReverts()
    }

    internal func handleToken(_ p: UITokenParams) {
        guard let idx = turns.lastIndex(where: { $0.id == p.turnId }) else { return }
        turns[idx].reply.append(p.delta)
    }

    /// Tagged dispatch on the `ui.thinking` lifecycle. `.delta` accumulates
    /// the trace and stamps `thinkingStartedAt` on first arrival; `.end`
    /// stamps `thinkingEndedAt` exactly once. The Shell never infers either
    /// transition from neighboring channels — the sidecar owns the timing.
    internal func handleThinking(_ p: UIThinkingParams) {
        guard let idx = turns.lastIndex(where: { $0.id == p.turnId }) else { return }
        switch p.kind {
        case .delta:
            // `UIThinkingParams`'s decoder rejects `.delta` without a delta
            // string, so the force-unwrap here is the wire contract — a nil
            // would have failed at decode and never reached this handler.
            if turns[idx].thinkingStartedAt == nil {
                turns[idx].thinkingStartedAt = Date()
            }
            turns[idx].thinking.append(p.delta!)
        case .end:
            if turns[idx].thinkingStartedAt != nil && turns[idx].thinkingEndedAt == nil {
                turns[idx].thinkingEndedAt = Date()
            }
        }
    }

    internal func handleStatus(_ p: UIStatusParams) {
        guard let idx = turns.lastIndex(where: { $0.id == p.turnId }) else { return }
        let mapped = AgentStatus.from(uiStatus: p.status)
        turns[idx].status = mapped
        status = mapped
        switch p.status {
        case .done: scheduleDoneRevert()
        default: cancelReverts()
        }
    }

    internal func handleError(_ p: UIErrorParams) {
        guard let idx = turns.lastIndex(where: { $0.id == p.turnId }) else { return }
        turns[idx].status = .error
        turns[idx].errorMessage = p.message
        status = .error
        scheduleErrorRevert()
    }

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

    // MARK: - Test seams
    //
    // Tests can no longer "set the current turn" without first telling the
    // service a turn started — that's the sidecar's job in production. These
    // helpers thinly wrap the production notification handlers so tests don't
    // have to construct `CitedContext` boilerplate by hand.

    internal func _testTurnStarted(id: String, prompt: String = "") {
        handleTurnStarted(ConversationTurnStartedParams(
            turn: ConversationTurnWire(
                id: id,
                prompt: prompt,
                citedContext: CitedContext(),
                reply: "",
                status: .thinking,
                startedAt: 0
            )
        ))
    }
}

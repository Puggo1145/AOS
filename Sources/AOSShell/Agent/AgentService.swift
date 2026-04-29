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
        case .working:  return .working
        case .waiting:  return .waiting
        case .done:     return .done
        }
    }

    /// Project a sidecar `TurnStatus` (snapshot inside `ConversationTurnWire`)
    /// to the view-facing enum. `cancelled` collapses to `.idle` because the
    /// view does not have a dedicated cancelled glyph — the closed-bar emoji
    /// goes back to its resting state.
    public static func from(turnStatus: TurnStatus) -> AgentStatus {
        switch turnStatus {
        case .working:   return .working
        case .waiting:   return .waiting
        case .done:      return .done
        case .error:     return .error
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
    /// Tool calls observed on this turn, in emit order. Each record starts
    /// in `.calling` on `ui.toolCall { phase: "called" }` and transitions to
    /// `.completed` on the matching `phase: "result"` frame. Empty when the
    /// turn made no tool calls.
    public var toolCalls: [ToolCallRecord] = []
    /// Ordered render script for the turn body. Captures the actual emit
    /// sequence of `ui.thinking` / `ui.token` / `ui.toolCall` notifications so
    /// the panel renders thinking, tool calls, and reply text in the order the
    /// model produced them — rather than the fixed thinking → tools → reply
    /// grouping that loses interleaving (e.g. "think → tool → think → reply →
    /// tool → reply"). The aggregate `thinking` / `reply` / `toolCalls` fields
    /// above are kept in sync with the segments and remain the source for
    /// streaming-detection heuristics and emoji selection.
    public var segments: [TurnSegment] = []
}

/// One ordered slot in `ConversationTurn.segments`. Thinking and reply each
/// own their own text so the same turn can carry multiple non-contiguous
/// thinking or reply chunks separated by tool calls.
public enum TurnSegment: Identifiable, Equatable {
    case thinking(ThinkingSegment)
    case toolCall(id: String)
    case reply(ReplySegment)

    public var id: String {
        switch self {
        case .thinking(let s): return "think:\(s.id)"
        case .toolCall(let id): return "tool:\(id)"
        case .reply(let s): return "reply:\(s.id)"
        }
    }
}

/// One contiguous run of `ui.thinking` deltas. A turn may have several when
/// reasoning resumes after a tool result.
public struct ThinkingSegment: Identifiable, Equatable, Sendable {
    public let id: String
    public var text: String
    public var startedAt: Date
    public var endedAt: Date?
    /// Two concepts deliberately split:
    ///   - `isOpenForAppend`: subsequent `ui.thinking.delta` frames extend
    ///     this segment vs. start a new one. Flipped to false as soon as a
    ///     reply token or tool call lands, so a later thinking burst becomes
    ///     its own segment in render order.
    ///   - `endedAt`: the explicit `ui.thinking.end` lifecycle stamp, used by
    ///     the UI to compute "Thought for X seconds". Driven exclusively by
    ///     the `.end` frame — never inferred from reply/tool arrival.
    /// Conflating these would settle the UI and record elapsed time off the
    /// first reply/tool frame instead of the actual lifecycle end.
    public var isOpenForAppend: Bool

    public init(
        id: String = UUID().uuidString,
        text: String = "",
        startedAt: Date,
        endedAt: Date? = nil,
        isOpenForAppend: Bool = true
    ) {
        self.id = id
        self.text = text
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.isOpenForAppend = isOpenForAppend
    }
}

/// One contiguous run of `ui.token` deltas. A turn may have several when the
/// model emits visible text, makes a tool call, then emits more text.
public struct ReplySegment: Identifiable, Equatable, Sendable {
    public let id: String
    public var text: String

    public init(id: String = UUID().uuidString, text: String = "") {
        self.id = id
        self.text = text
    }
}

/// Per-tool-invocation record mirrored from the sidecar's `ui.toolCall`
/// lifecycle. Lives on the owning `ConversationTurn`. The Shell UI is not
/// yet wired to render these — the data is captured here so the renderer
/// can read it without re-plumbing the wire.
public struct ToolCallRecord: Identifiable, Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case calling
        case completed
    }

    /// `toolCallId` from the wire — stable across `.called` → `.result`.
    public let id: String
    public let name: String
    public let args: JSONValue
    public var status: Status
    /// Set on `.result`. `nil` while the call is still in `.calling`.
    public var isError: Bool?
    /// One-shot text rendering of the tool's output content. Set on `.result`.
    public var outputText: String?
}

/// Per-session snapshot of the most recent `ui.usage` frame. The composer's
/// context-usage ring reads this directly. "Used context" for ring/percentage
/// purposes is `inputTokens + cacheReadTokens + cacheWriteTokens + outputTokens`
/// — the byte-equivalent of what the next round will re-send. The discrete
/// fields stay around so the hover tooltip can break out the cache portion.
public struct ContextUsageSnapshot: Sendable, Equatable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int
    public let totalTokens: Int
    public let contextWindow: Int
    public let modelId: String

    public init(
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        totalTokens: Int,
        contextWindow: Int,
        modelId: String
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.totalTokens = totalTokens
        self.contextWindow = contextWindow
        self.modelId = modelId
    }

    /// Sum that the composer ring renders. Includes cache hits — they still
    /// occupy the prompt the model receives, so they count toward the
    /// window's fill regardless of how cheaply they were billed.
    public var usedTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens
    }

    /// Clamped 0…1 fill ratio for the ring. Capped so a usage frame that
    /// briefly overshoots (e.g. a provider that double-counts) doesn't blow
    /// the geometry out.
    public var fillRatio: Double {
        guard contextWindow > 0 else { return 0 }
        let raw = Double(usedTokens) / Double(contextWindow)
        return min(max(raw, 0), 1)
    }
}

/// "正在后台操作 X" indicator payload read by the Notch closed bar. Resolved
/// from the in-flight `computer_use_*` tool call's `args.pid` via
/// `NSRunningApplication`. We carry the icon (NSImage) and a one-word verb
/// derived from the tool name so the indicator can render a glyph + label
/// without re-doing the lookup on every redraw. Both fields are best-effort:
/// if the target process exited mid-call we still surface the verb so the
/// user knows *something* is happening, just without the icon.
@MainActor
public struct BackgroundOperation: @MainActor Equatable {
    public let appName: String?
    public let icon: NSImage?
    /// Short present-continuous verb derived from the tool name. Used by the
    /// closed-bar indicator's accessibility label and tooltip.
    public let verb: String

    public init(appName: String?, icon: NSImage?, verb: String) {
        self.appName = appName
        self.icon = icon
        self.verb = verb
    }

    /// `NSImage` is not `Equatable` in a way SwiftUI's diff trusts — fall
    /// back to identity equality plus name/verb so two snapshots of the same
    /// in-flight call don't trigger spurious view rebuilds.
    public static func == (lhs: BackgroundOperation, rhs: BackgroundOperation) -> Bool {
        lhs.appName == rhs.appName && lhs.verb == rhs.verb && lhs.icon === rhs.icon
    }

    public static func resolve(toolName: String, args: JSONValue) -> BackgroundOperation? {
        let pid = Self.extractPid(args: args)
        let app: NSRunningApplication?
        if let pid, pid > 0 {
            app = NSRunningApplication(processIdentifier: pid)
        } else {
            app = nil
        }
        // No pid (computer_use_list_apps / computer_use_doctor) doesn't have a
        // target app, but those calls are also typically too short to surface
        // in the indicator. Skip them rather than render a nameless badge.
        guard app != nil else { return nil }
        return BackgroundOperation(
            appName: app?.localizedName,
            icon: app?.icon,
            verb: Self.verb(for: toolName)
        )
    }

    private static func extractPid(args: JSONValue) -> pid_t? {
        guard case let .object(obj) = args, let raw = obj["pid"] else { return nil }
        switch raw {
        case .int(let i): return pid_t(i)
        case .double(let d): return pid_t(d)
        default: return nil
        }
    }

    private static func verb(for tool: String) -> String {
        switch tool {
        case "computer_use_click_element", "computer_use_click_at": return "正在后台点击"
        case "computer_use_drag": return "正在后台拖动"
        case "computer_use_type_text": return "正在后台输入"
        case "computer_use_press_key": return "正在后台按键"
        case "computer_use_scroll": return "正在后台滚动"
        case "computer_use_get_app_state": return "正在读取界面"
        case "computer_use_list_windows": return "正在枚举窗口"
        default: return "正在后台操作"
        }
    }
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
    /// Per-session mirror registry. The active mirror's fields project onto
    /// `turns / currentTurn / status / lastErrorMessage` so every existing UI
    /// consumer keeps working without changes.
    public let sessionStore: SessionStore

    /// Active session view-projections. Reading any of these from SwiftUI
    /// transitively observes the active mirror's properties via @Observable —
    /// switching `sessionStore.activeId` re-runs the dependent views.
    public var turns: [ConversationTurn] {
        sessionStore.activeMirror?.turns ?? []
    }
    public var currentTurn: String? {
        sessionStore.activeMirror?.currentTurn
    }
    public var status: AgentStatus {
        sessionStore.activeMirror?.status ?? .idle
    }
    public var lastErrorMessage: String? {
        sessionStore.activeMirror?.lastErrorMessage
    }
    /// Most recent context-usage frame for the active session. `nil` until
    /// the first LLM round of any turn lands; cleared on `agent.reset`.
    public var latestUsage: ContextUsageSnapshot? {
        sessionStore.activeMirror?.latestUsage
    }

    public var currentSessionId: String? { sessionStore.activeId }

    /// In-flight Computer Use target — the app the agent is operating in the
    /// background right now. Drives the Notch closed-bar's "正在后台操作 X"
    /// indicator. Resolved by walking the active mirror's `currentTurn` for
    /// any tool call still in `.calling` whose name is a `computer_use_*`.
    /// `nil` when no such call is active. We pick the LAST in-flight call so
    /// concurrent tool fan-out (rare but possible) shows the most recent
    /// target.
    public var activeBackgroundOperation: BackgroundOperation? {
        guard let mirror = sessionStore.activeMirror,
              let turnId = mirror.currentTurn,
              let turn = mirror.turns.last(where: { $0.id == turnId })
        else { return nil }
        let inflight = turn.toolCalls.last(where: {
            $0.status == .calling && $0.name.hasPrefix("computer_use_")
        })
        guard let inflight else { return nil }
        return BackgroundOperation.resolve(toolName: inflight.name, args: inflight.args)
    }

    /// Name of the most recent in-flight tool call on the active turn, across
    /// every tool family. Drives the closed-bar status slot's live tool-icon
    /// swap (see `AgentStatusIndicator`). `nil` when no tool is currently in
    /// `.calling`. Last-wins on concurrent fan-out, matching
    /// `activeBackgroundOperation`.
    public var activeToolName: String? {
        guard let mirror = sessionStore.activeMirror,
              let turnId = mirror.currentTurn,
              let turn = mirror.turns.last(where: { $0.id == turnId })
        else { return nil }
        return turn.toolCalls.last(where: { $0.status == .calling })?.name
    }

    private let rpc: RPCClient

    public init(rpc: RPCClient, sessionStore: SessionStore) {
        self.rpc = rpc
        self.sessionStore = sessionStore
        registerHandlers()
    }

    private func registerHandlers() {
        rpc.registerNotificationHandler(method: RPCMethod.conversationTurnStarted) {
            [weak self] (params: ConversationTurnStartedParams) in
            await self?.handleTurnStarted(params)
        }
        rpc.registerNotificationHandler(method: RPCMethod.conversationReset) {
            [weak self] (params: ConversationResetParams) in
            await self?.handleConversationReset(params)
        }
        rpc.registerNotificationHandler(method: RPCMethod.uiToken) { [weak self] (params: UITokenParams) in
            await self?.handleToken(params)
        }
        rpc.registerNotificationHandler(method: RPCMethod.uiThinking) { [weak self] (params: UIThinkingParams) in
            await self?.handleThinking(params)
        }
        rpc.registerNotificationHandler(method: RPCMethod.uiToolCall) { [weak self] (params: UIToolCallParams) in
            await self?.handleToolCall(params)
        }
        rpc.registerNotificationHandler(method: RPCMethod.uiStatus) { [weak self] (params: UIStatusParams) in
            await self?.handleStatus(params)
        }
        rpc.registerNotificationHandler(method: RPCMethod.uiError) { [weak self] (params: UIErrorParams) in
            await self?.handleError(params)
        }
        rpc.registerNotificationHandler(method: RPCMethod.uiUsage) { [weak self] (params: UIUsageParams) in
            await self?.handleUsage(params)
        }
    }

    // MARK: - Public API

    public func submit(prompt: String, citedContext: CitedContext) async {
        guard let sessionId = currentSessionId, let mirror = sessionStore.activeMirror else {
            // Fail loudly: no active session means bootstrap `session.create`
            // failed (or hasn't landed yet) and no agent loop is reachable.
            // Surface a banner via the store's action-error channel so the
            // composer stops looking like it accepted the submit. The UI also
            // reads `sessionStore.bootError` and disables the input upstream;
            // this is the defensive lower-bound in case a submit somehow
            // races past that gate.
            sessionStore.lastActionError = SessionActionError(
                kind: .create,
                message: sessionStore.bootError
                    ?? "No active session. Restart AOS or wait for session bootstrap to complete.",
                sessionId: nil
            )
            return
        }
        let turnId = UUID().uuidString
        do {
            _ = try await rpc.request(
                method: RPCMethod.agentSubmit,
                params: AgentSubmitParams(
                    sessionId: sessionId,
                    turnId: turnId,
                    prompt: prompt,
                    citedContext: citedContext
                ),
                as: AgentSubmitResult.self
            )
            mirror.clearSubmitError()
            // ack only — the turn appears in `turns` once the sidecar
            // broadcasts `conversation.turnStarted`.
        } catch let RPCClientError.outboundPayloadTooLarge(_, bytes, limit) {
            // The composed prompt + cited context exceeded the NDJSON line
            // cap. The request was rejected before any byte hit the wire, so
            // the sidecar transport is unaffected. Surface a precise message
            // so the user knows to remove pasted content rather than retry
            // blindly.
            mirror.setSubmitError(Self.formatPayloadTooLargeMessage(bytes: bytes, limit: limit))
        } catch {
            // Transport / handler-level failure before the sidecar ever
            // registered the turn. Surface a visible message rather than
            // a silent banner clear — the user otherwise sees their
            // submit just disappear and has no clue whether to retry.
            mirror.setSubmitError(Self.formatSubmitFailureMessage(error: error))
        }
    }

    internal static func formatSubmitFailureMessage(error: Error) -> String {
        if let rpc = error as? RPCClientError {
            switch rpc {
            case .timeout(let method):
                return "Send timed out (\(method)). Check the agent connection and try again."
            case .connectionClosed:
                return "Lost the agent connection before the message was sent. Restart AOS and try again."
            case .server(let inner):
                return "Send failed: \(inner.message)"
            case .protocolMajorMismatch(let remote, let local):
                return "Send failed: protocol version mismatch (sidecar \(remote) vs shell \(local))."
            case .payloadTooLarge:
                return "Send failed: response payload exceeded the transport cap."
            case .outboundPayloadTooLarge(_, let bytes, let limit):
                return formatPayloadTooLargeMessage(bytes: bytes, limit: limit)
            case .malformed(let detail):
                return "Send failed: malformed response from sidecar (\(detail))."
            }
        }
        return "Send failed: \(error.localizedDescription)"
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
        guard let sessionId = currentSessionId else { return }
        _ = try? await rpc.request(
            method: RPCMethod.agentReset,
            params: AgentResetParams(sessionId: sessionId),
            as: AgentResetResult.self
        )
    }

    public func cancel() async {
        guard let sessionId = currentSessionId, let turnId = currentTurn else { return }
        _ = try? await rpc.request(
            method: RPCMethod.agentCancel,
            params: AgentCancelParams(sessionId: sessionId, turnId: turnId),
            as: AgentCancelResult.self
        )
    }

    // MARK: - Notification handlers
    //
    // Each handler routes by `sessionId` to the matching mirror in
    // `sessionStore`. Inactive sessions still apply updates locally — the
    // mirror is independent of which one is currently displayed — but the
    // global `status` projection only reflects the active mirror.

    /// Visible to tests via `@testable import` so synthetic notifications can
    /// drive the state machine without a real RPCClient.
    internal func handleTurnStarted(_ p: ConversationTurnStartedParams) {
        sessionStore.mirror(for: p.sessionId).applyTurnStarted(p)
    }

    internal func handleConversationReset(_ p: ConversationResetParams) {
        sessionStore.mirrors[p.sessionId]?.applyConversationReset()
    }

    internal func handleToken(_ p: UITokenParams) {
        sessionStore.mirror(for: p.sessionId).applyToken(p)
    }

    internal func handleThinking(_ p: UIThinkingParams) {
        sessionStore.mirror(for: p.sessionId).applyThinking(p)
    }

    internal func handleToolCall(_ p: UIToolCallParams) {
        sessionStore.mirror(for: p.sessionId).applyToolCall(p)
    }

    internal func handleStatus(_ p: UIStatusParams) {
        sessionStore.mirror(for: p.sessionId).applyStatus(p)
    }

    internal func handleError(_ p: UIErrorParams) {
        sessionStore.mirror(for: p.sessionId).applyError(p)
    }

    internal func handleUsage(_ p: UIUsageParams) {
        sessionStore.mirror(for: p.sessionId).applyUsage(p)
    }

    // MARK: - Test seams
    //
    // Tests can no longer "set the current turn" without first telling the
    // service a turn started — that's the sidecar's job in production. These
    // helpers thinly wrap the production notification handlers so tests don't
    // have to construct `CitedContext` boilerplate by hand.

    internal func _testTurnStarted(id: String, prompt: String = "", sessionId: String = "S") {
        handleTurnStarted(ConversationTurnStartedParams(
            sessionId: sessionId,
            turn: ConversationTurnWire(
                id: id,
                prompt: prompt,
                citedContext: CitedContext(),
                reply: "",
                status: .working,
                startedAt: 0
            )
        ))
    }
}

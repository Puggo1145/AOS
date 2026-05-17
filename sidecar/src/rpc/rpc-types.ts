// AOS Shell ↔ Bun Sidecar JSON-RPC schema (TypeScript side).
//
// This file is hand-maintained to mirror `Sources/AOSRPCSchema/*.swift` field
// for field. Source of truth is the Swift Codable types per
// docs/designs/rpc-protocol.md §"Schema 单一信源". Drift is caught by the
// `tests/rpc-fixtures/*.json` byte-equal conformance tests on both sides.

// ---------------------------------------------------------------------------
// Protocol version
// ---------------------------------------------------------------------------

/// Bumped per docs/designs/rpc-protocol.md §"版本协商":
/// MAJOR mismatch ⇒ Shell rejects handshake; MINOR/PATCH ⇒ warn + accept.
export const AOS_PROTOCOL_VERSION = "2.0.0" as const;

// ---------------------------------------------------------------------------
// JSON-RPC envelopes
// ---------------------------------------------------------------------------

export type RPCId = number | string;

export interface RPCRequest<P> {
  jsonrpc: "2.0";
  id: RPCId;
  method: string;
  params: P;
}

export interface RPCResponse<R> {
  jsonrpc: "2.0";
  id: RPCId;
  result: R;
}

export interface RPCErrorResponse {
  jsonrpc: "2.0";
  id: RPCId;
  error: RPCError;
}

export interface RPCNotification<P> {
  jsonrpc: "2.0";
  method: string;
  params: P;
}

// ---------------------------------------------------------------------------
// Error model — per docs/designs/rpc-protocol.md §"错误模型"
// ---------------------------------------------------------------------------

export interface RPCError {
  code: number;
  message: string;
  data?: JSONValue;
}

export const RPCErrorCode = {
  // Standard JSON-RPC
  parseError: -32700,
  invalidRequest: -32600,
  methodNotFound: -32601,
  invalidParams: -32602,
  internalError: -32603,
  // AOS application generic segment
  unhandshaked: -32000,
  payloadTooLarge: -32001,
  timeout: -32002,
  permissionDenied: -32003,
  // auth.* (provider OAuth login) — per onboarding plan
  loginInProgress: -32200,
  loginCancelled: -32201,
  loginTimeout: -32202,
  unknownProvider: -32203,
  loginNotConfigured: -32204,
  // agent.* segment — agent-loop-level failures
  agentContextOverflow: -32300,
  agentConfigInvalid: -32301,
  // session.* segment
  unknownSession: -32400,
  /// Reserved: emitted when an RPC implicitly needs an active session and
  /// none exists. Currently every session-aware call carries an explicit
  /// `sessionId`, so this code is unused on the wire today.
  noActiveSession: -32401,
} as const;

export type RPCErrorCodeName = keyof typeof RPCErrorCode;

// ---------------------------------------------------------------------------
// JSON value (recursive)
// ---------------------------------------------------------------------------

export type JSONValue =
  | null
  | boolean
  | number
  | string
  | JSONValue[]
  | { [k: string]: JSONValue };

// ---------------------------------------------------------------------------
// Method name constants
// ---------------------------------------------------------------------------

export const RPCMethod = {
  rpcHello: "rpc.hello",
  rpcPing: "rpc.ping",
  agentSubmit: "agent.submit",
  agentCancel: "agent.cancel",
  agentReset: "agent.reset",
  agentCompact: "agent.compact",
  conversationTurnStarted: "conversation.turnStarted",
  conversationReset: "conversation.reset",
  uiToken: "ui.token",
  uiThinking: "ui.thinking",
  uiToolCall: "ui.toolCall",
  uiStatus: "ui.status",
  uiError: "ui.error",
  uiUsage: "ui.usage",
  uiTodo: "ui.todo",
  uiCompact: "ui.compact",
  providerStatus: "provider.status",
  providerStartLogin: "provider.startLogin",
  providerCancelLogin: "provider.cancelLogin",
  providerLoginStatus: "provider.loginStatus",
  providerStatusChanged: "provider.statusChanged",
  providerSetApiKey: "provider.setApiKey",
  providerClearApiKey: "provider.clearApiKey",
  providerLogout: "provider.logout",
  configGet: "config.get",
  configSet: "config.set",
  configSetEffort: "config.setEffort",
  configMarkOnboardingCompleted: "config.markOnboardingCompleted",
  computerUseListApps: "computerUse.listApps",
  computerUseListWindows: "computerUse.listWindows",
  computerUseGetAppState: "computerUse.getAppState",
  computerUseStartAppSession: "computerUse.startAppSession",
  computerUseStopAppSession: "computerUse.stopAppSession",
  computerUsePostMouseEvent: "computerUse.postMouseEvent",
  computerUsePostKeyboardEvent: "computerUse.postKeyboardEvent",
  computerUsePostEventToAXElement: "computerUse.postEventToAXElement",
  devContextGet: "dev.context.get",
  devContextChanged: "dev.context.changed",
  sessionCreate: "session.create",
  sessionList: "session.list",
  sessionActivate: "session.activate",
  sessionCreated: "session.created",
  sessionActivated: "session.activated",
  sessionListChanged: "session.listChanged",
} as const;

// ---------------------------------------------------------------------------
// rpc.hello / rpc.ping
// ---------------------------------------------------------------------------

export interface ClientInfo {
  name: string;
  version: string;
}

export interface ServerInfo {
  name: string;
  version: string;
}

export interface HelloParams {
  protocolVersion: string;
  clientInfo: ClientInfo;
}

export interface HelloResult {
  protocolVersion: string;
  serverInfo: ServerInfo;
}

/// `rpc.ping` is a payload-less request: params and result both serialize as `{}`.
export type PingParams = Record<string, never>;
export type PingResult = Record<string, never>;

// ---------------------------------------------------------------------------
// agent.* — Shell → Bun
// ---------------------------------------------------------------------------

export interface AgentSubmitParams {
  sessionId: string;
  turnId: string;
  prompt: string;
  citedContext: CitedContext;
}

export interface AgentSubmitResult {
  accepted: boolean;
}

export interface AgentCancelParams {
  sessionId: string;
  turnId: string;
}

export interface AgentCancelResult {
  cancelled: boolean;
}

/// `agent.reset` clears one session's conversation. Cancels that session's
/// in-flight turn (if any). Sidecar emits `conversation.reset { sessionId }`
/// after the wipe so observers can drop the mirror for that session, and
/// `session.listChanged` so the history list reflects the zeroed turnCount.
export interface AgentResetParams {
  sessionId: string;
}

export interface AgentResetResult {
  ok: boolean;
}

/// `agent.compact` is the manual context-compact entry. Layer 3 of the
/// compact stack (vs. auto-path Layer 2 which fires from runTurn entry):
/// the user explicitly asks "summarize my history right now". Bypasses
/// the auto-compact breaker — manual is intent-driven, not automatic, so
/// past auto failures don't gate it. Rejected when a turn is in flight
/// (would race the running runTurn's own LLM stream); the user should
/// cancel or wait.
///
/// Sidecar emits the same `ui.compact { started → done | failed }`
/// lifecycle as the auto path. `turnId` on those frames is empty for
/// the manual case — there is no "next turn" the marker should
/// visually precede; the Shell renders it at the tail of history.
export interface AgentCompactParams {
  sessionId: string;
}

export interface AgentCompactResult {
  ok: boolean;
  /// Number of turns folded into the summary on success. Omitted when
  /// the call short-circuits (no prior history to compact).
  compactedTurnCount?: number;
}

// ---------------------------------------------------------------------------
// computerUse.* — Sidecar → Shell
// ---------------------------------------------------------------------------

export type ComputerUseAppListMode = "running" | "all";
export type ComputerUseCaptureMode = "vision" | "ax";

export interface ComputerUsePoint {
  x: number;
  y: number;
}

export interface ComputerUseBounds {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface ComputerUseAppInfo {
  pid?: number;
  bundleId?: string;
  name: string;
  path?: string;
  running: boolean;
  active: boolean;
  identity: string;
}

export interface ComputerUseWindowInfo {
  windowId: number;
  pid: number;
  owner: string;
  title: string;
  bounds: ComputerUseBounds;
  zIndex: number;
  isOnScreen: boolean;
  layer: number;
}

export interface ComputerUsePixelSize {
  width: number;
  height: number;
}

export interface ComputerUseCoordinateSpace {
  windowFrame: ComputerUseBounds;
  windowBounds: ComputerUseBounds;
  pixelSize: ComputerUsePixelSize;
}

export interface ComputerUseScreenshot {
  imagePath: string;
  format: string;
  width: number;
  height: number;
  scaleFactor: number;
  coordinateSpace: ComputerUseCoordinateSpace;
  originalWidth?: number;
  originalHeight?: number;
}

export interface ComputerUseListAppsParams {
  mode: ComputerUseAppListMode;
}

export interface ComputerUseListAppsResult {
  apps: ComputerUseAppInfo[];
}

export interface ComputerUseListWindowsParams {
  pid: number;
}

export interface ComputerUseListWindowsResult {
  windows: ComputerUseWindowInfo[];
}

export interface ComputerUseGetAppStateParams {
  windowId: number;
  captureMode: ComputerUseCaptureMode;
}

export interface ComputerUseGetAppStateResult {
  pid: number;
  stateId: string;
  treeMarkdown: string;
  elementCount: number;
  screenshot?: ComputerUseScreenshot;
  bundleId?: string;
  appName?: string;
}

export interface ComputerUseStartAppSessionParams {
  pid: number;
  windowId: number;
}

export interface ComputerUseStopAppSessionParams {
  pid: number;
}

export interface ComputerUseAppSessionResult {
  pid: number;
}

export interface ComputerUseStopAppSessionResult {
  stopped: boolean;
  pid?: number;
}

export type ComputerUseMouseButton = "left" | "right";

export type ComputerUseMouseEvent =
  | { kind: "click"; button: ComputerUseMouseButton; point: ComputerUsePoint; count?: number }
  | { kind: "drag"; button: ComputerUseMouseButton; from: ComputerUsePoint; to: ComputerUsePoint };

export interface ComputerUsePostMouseEventParams {
  windowId: number;
  stateId: string;
  event: ComputerUseMouseEvent;
}

export interface ComputerUsePostMouseEventResult {
  pid: number;
  windowId: number;
  event: ComputerUseMouseEvent;
}

export type ComputerUseKeyboardModifier = "command" | "shift" | "option" | "control" | "function";

export type ComputerUseKeyboardEvent =
  | { kind: "text"; text: string; delayMilliseconds?: number }
  | { kind: "keyPress"; key: string; modifiers?: ComputerUseKeyboardModifier[]; count?: number }
  | { kind: "hotkey"; modifiers: ComputerUseKeyboardModifier[]; key: string };

export interface ComputerUsePostKeyboardEventParams {
  windowId: number;
  event: ComputerUseKeyboardEvent;
}

export interface ComputerUsePostKeyboardEventResult {
  pid: number;
  windowId: number;
  event: ComputerUseKeyboardEvent;
}

export type ComputerUseAXElementAction =
  | "press"
  | "showMenu"
  | "pick"
  | "confirm"
  | "cancel"
  | "open"
  | "increment"
  | "decrement"
  | "scrollToVisible";

export type ComputerUseAXScrollDirection = "up" | "down" | "left" | "right";

export type ComputerUseAXElementEvent =
  | { kind: "action"; action: ComputerUseAXElementAction }
  | { kind: "setValue"; value: string }
  | { kind: "setSelectedText"; value: string }
  | { kind: "focus" }
  | { kind: "scroll"; direction: ComputerUseAXScrollDirection; pages: number };

export interface ComputerUsePostEventToAXElementParams {
  windowId: number;
  stateId: string;
  elementIndex: number;
  event: ComputerUseAXElementEvent;
}

export interface ComputerUsePostEventToAXElementResult {
  pid: number;
  windowId: number;
  stateId: string;
  elementIndex: number;
  event: ComputerUseAXElementEvent;
}

// ---------------------------------------------------------------------------
// conversation.* — Sidecar → Shell (notifications)
//
// The sidecar owns the canonical conversation state (turns array, LLM
// history). Shell mirrors it 1:1 from these notifications:
//   - `conversation.turnStarted { turn }` fires once per `agent.submit` once
//     the turn has been registered in the sidecar's Conversation. `turn`
//     carries the snapshot the sidecar persisted (id, prompt, citedContext,
//     initial empty reply, status: working).
//   - `conversation.reset` fires after `agent.reset` clears the store.
//   - reply token deltas continue to flow over the existing `ui.token`
//     notification so tight streaming doesn't pay a serialization cost on
//     every character.
//   - per-turn status changes flow over `ui.status` / `ui.error` (existing).
// ---------------------------------------------------------------------------

export type TurnStatus =
  | "working"
  | "waiting"
  | "done"
  | "error"
  | "cancelled";

export interface ConversationTurnWire {
  id: string;
  prompt: string;
  citedContext: CitedContext;
  reply: string;
  status: TurnStatus;
  errorMessage?: string;
  errorCode?: number;
  /// Milliseconds since epoch.
  startedAt: number;
}

export interface ConversationTurnStartedParams {
  sessionId: string;
  turn: ConversationTurnWire;
}

export interface ConversationResetParams {
  sessionId: string;
}

// ---------------------------------------------------------------------------
// CitedContext — wire-only projection of Shell's SenseContext
// ---------------------------------------------------------------------------

export interface CitedContext {
  app?: CitedApp;
  window?: CitedWindow;
  behaviors?: BehaviorEnvelope[];
  visual?: CitedVisual;
  /// Zero or more clipboard payloads, one per paste the user performed
  /// into the composer this turn. Order is paste order. Omitted when
  /// no pastes occurred; an empty array is invalid.
  clipboards?: CitedClipboard[];
}

export interface CitedApp {
  bundleId: string;
  name: string;
  pid: number;
  /// Base64-encoded PNG. Optional.
  iconPNG?: string;
}

export interface CitedWindow {
  title: string;
  /// CGWindowID hint. May be stale if the window is recreated or moved.
  windowId?: number;
}

export interface BehaviorEnvelope {
  kind: string;
  citationKey: string;
  displaySummary: string;
  /// Opaque per-producer JSON; sidecar usually passes through unchanged.
  /// `general.textSelection` is rendered specially in the LLM prompt so
  /// the model sees a marked text context instead of a raw JSON blob.
  /// For `general.currentInput`, Shell includes `{ value?, target }`. `value`
  /// may be omitted when `general.textSelection` already carries exact
  /// selected content for the same editable control, avoiding a duplicate
  /// full AXValue read.
  payload: JSONValue;
}

export interface CitedVisualSize {
  width: number;
  height: number;
}

export interface CitedVisual {
  /// Base64-encoded PNG, ≤ 400KB after encoding.
  frame: string;
  frameSize: CitedVisualSize;
  /// ISO-8601 UTC timestamp.
  capturedAt: string;
}

// CitedClipboard — discriminated union, mirrors Swift's Codable encoding.
export type CitedClipboard =
  | { kind: "text"; content: string }
  | { kind: "filePaths"; paths: string[] }
  | { kind: "image"; metadata: CitedClipboardImageMetadata };

export interface CitedClipboardImageMetadata {
  width: number;
  height: number;
  type: string;
}

// ---------------------------------------------------------------------------
// ui.* — Bun → Shell notifications
// ---------------------------------------------------------------------------

export interface UITokenParams {
  sessionId: string;
  turnId: string;
  delta: string;
}

/// `ui.thinking` carries reasoning-trace lifecycle events streamed by
/// reasoning-capable models. Tagged union by `kind`:
///   - `"delta"` — incremental reasoning text in `delta`.
///   - `"end"`   — end of the current reasoning block; no `delta`.
/// Kept on a separate channel from `ui.token` so the Notch panel can render
/// the reasoning trace distinctly from the visible reply.
export type UIThinkingParams =
  | { sessionId: string; turnId: string; kind: "delta"; delta: string }
  | { sessionId: string; turnId: string; kind: "end" };

/// `ui.toolCall` carries the lifecycle of one tool invocation. Tagged union
/// by `phase`:
///   - `"called"`   — assistant emitted a tool call AND its arguments passed
///                    schema validation. `args` is the parsed, validated
///                    argument object the tool will receive.
///   - `"result"`   — tool finished executing (success OR runtime error).
///                    `outputText` is a one-shot text rendering of the result
///                    content for the Shell to display; structured details
///                    stay sidecar-side.
///   - `"rejected"` — argument validation failed; the handler never ran.
///                    `args` is the model's raw arguments (so the Shell can
///                    show what was attempted) and `errorMessage` is the
///                    validation failure surfaced to both the user and the
///                    model on the next round.
/// Lives on its own channel (separate from `ui.token`) so the Notch panel
/// can render tool activity distinctly from the visible reply.
export type UIToolCallParams =
  | {
      sessionId: string;
      turnId: string;
      phase: "called";
      toolCallId: string;
      toolName: string;
      args: JSONValue;
    }
  | {
      sessionId: string;
      turnId: string;
      phase: "result";
      toolCallId: string;
      toolName: string;
      isError: boolean;
      outputText: string;
    }
  | {
      sessionId: string;
      turnId: string;
      phase: "rejected";
      toolCallId: string;
      toolName: string;
      args: JSONValue;
      errorMessage: string;
    };

export type UIStatus = "working" | "waiting" | "done";

export interface UIStatusParams {
  sessionId: string;
  turnId: string;
  status: UIStatus;
}

export interface UIErrorParams {
  sessionId: string;
  turnId: string;
  code: number;
  message: string;
  data?: JSONValue;
}

/// Token-usage snapshot emitted once per LLM round, immediately after the
/// model returns its final assistant message (BEFORE tool execution and
/// BEFORE the next round). Drives the live composer's context-usage ring
/// so the user sees their context window fill in real time, round by round,
/// without waiting for the whole agent loop to terminate.
///
/// `inputTokens` here is the catalog `Usage.input` field (input tokens that
/// were NOT served from cache). Cache reads/writes are tracked separately so
/// the tooltip can break them out, but for the headline "used context" the
/// Shell sums `input + cacheRead + cacheWrite + output` — that's the byte
/// equivalent the next round's prompt+reply round-trips through.
export interface UIUsageParams {
  sessionId: string;
  turnId: string;
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheWriteTokens: number;
  totalTokens: number;
  /// Catalog `model.contextWindow` for the model that just produced this
  /// reply. Echoed on the wire so the Shell can render the ring without a
  /// second `config.get` round trip and so a mid-conversation model swap
  /// is reflected immediately.
  contextWindow: number;
  modelId: string;
}

/// Wire shape for one TodoWrite item. Mirrors `TodoItem` in
/// `agent/todos/manager.ts`. Values for `status` are exactly the strings the
/// LLM also writes; the closed enum is documented inline rather than typed
/// as a Swift-side enum so the wire fixture stays a plain string.
export interface TodoItemWire {
  id: string;
  text: string;
  status: "pending" | "in_progress" | "completed";
}

/// `ui.todo` projects the session's TodoWrite plan onto the wire. Fired on
/// every successful `todo_write` tool call, on `agent.reset` (with an empty
/// list), and once on `session.activate` so the Shell can hydrate the todo
/// panel for the freshly visible session. The whole list is sent each time —
/// keying off `sessionId` lets the Shell route the snapshot to the right
/// per-session mirror.
export interface UITodoParams {
  sessionId: string;
  items: TodoItemWire[];
}

/// Lifecycle phases of a context-compact pass — the auto path
/// (triggered at runTurn entry when remaining context falls below the
/// threshold) and the future manual `/compact` RPC path both emit the
/// same sequence: `started` → (`done` | `failed`).
export type UICompactPhase = "started" | "done" | "failed";

/// `ui.compact` is the Shell-facing signal that a compaction pass is
/// running on this session. Phases:
///   - `started`: emitted before the summarization LLM call begins. The
///     Shell can show a spinner / "compacting…" badge.
///   - `done`: the summary landed and the conversation has been
///     rewritten. `compactedTurnCount` reports how many turns were folded
///     into the summary so the UI can render an honest "N earlier turns
///     summarized" marker. The Shell's mirror is now structurally out of
///     sync with the sidecar's pruned `_turns`; future rounds will
///     re-anchor naturally on the next `conversation.turnStarted`.
///   - `failed`: the summarization call errored or returned no usable
///     text. The conversation is unchanged and the loop continues with
///     the original (oversized) history. `errorMessage` carries the
///     reason for surfacing.
export interface UICompactParams {
  sessionId: string;
  turnId: string;
  phase: UICompactPhase;
  /// Populated only on `done`. Number of turns folded into the summary.
  compactedTurnCount?: number;
  /// Populated only on `failed`.
  errorMessage?: string;
}

// ---------------------------------------------------------------------------
// provider.* — bidirectional namespace (per docs/plans/onboarding.md)
// ---------------------------------------------------------------------------

export type ProviderState = "ready" | "unauthenticated";
export type ProviderLoginState =
  | "awaitingCallback"
  | "exchanging"
  | "success"
  | "failed";
export type ProviderStatusReason = "authInvalidated" | "loggedOut";

/// How the user authenticates with this provider. Drives Shell UI:
/// `oauth` shows a login button; `apiKey` shows a secure text field.
export type ProviderAuthMethod = "oauth" | "apiKey";

export interface ProviderInfo {
  id: string;
  name: string;
  authMethod: ProviderAuthMethod;
  state: ProviderState;
}

export type ProviderStatusParams = Record<string, never>;

export interface ProviderStatusResult {
  providers: ProviderInfo[];
}

export interface ProviderStartLoginParams {
  providerId: string;
}

export interface ProviderStartLoginResult {
  loginId: string;
  authorizeUrl: string;
}

export interface ProviderCancelLoginParams {
  loginId: string;
}

export interface ProviderCancelLoginResult {
  cancelled: boolean;
}

export interface ProviderLoginStatusParams {
  loginId: string;
  providerId: string;
  state: ProviderLoginState;
  message?: string;
  errorCode?: number;
}

export interface ProviderStatusChangedParams {
  providerId: string;
  state: ProviderState;
  reason?: ProviderStatusReason;
  message?: string;
}

// `provider.setApiKey` / `provider.clearApiKey` — Shell → Bun.
// Used by apiKey-auth providers (e.g. deepseek). The Shell owns durable
// persistence (Keychain) and pushes the current value to the sidecar at
// startup AND on user edits. The sidecar holds the key in memory only.
//
// Sidecar emits `provider.statusChanged` after applying the change so the
// Shell ProviderService can refresh its state without polling.

export interface ProviderSetApiKeyParams {
  providerId: string;
  apiKey: string;
}

export interface ProviderSetApiKeyResult {
  ok: boolean;
}

export interface ProviderClearApiKeyParams {
  providerId: string;
}

export interface ProviderClearApiKeyResult {
  /// `false` when no key was present — handler is idempotent.
  cleared: boolean;
}

// `provider.logout` — Shell → Bun. Auth-method-agnostic clear. For
// apiKey providers it forwards to the same store as `provider.clearApiKey`;
// for OAuth providers it deletes the persisted token file (and any
// `.invalid` quarantine sibling) so the next `startLogin` runs the full
// authorization flow from scratch.
export interface ProviderLogoutParams {
  providerId: string;
}

export interface ProviderLogoutResult {
  /// `false` when nothing was cleared (no token / no key on disk).
  cleared: boolean;
}

// ---------------------------------------------------------------------------
// config.* — Shell → Bun. Global user config (selected provider/model, etc).
// Backed by ~/.aos/config.json. Catalog snapshot is included in `config.get`
// so the Shell settings UI doesn't need a second RPC.
// ---------------------------------------------------------------------------

/// One picker row for a model's reasoning effort.
///   - `value`: the wire string the sidecar sends to the provider
///     (e.g. `"high"`, `"xhigh"`, `"max"`). Stored verbatim in
///     `~/.aos/config.json` when the user picks it.
///   - `label`: human-readable name shown in the picker.
/// Each model declares its own list — there is no universal effort
/// vocabulary across providers.
export interface ConfigEffortLevel {
  value: string;
  label: string;
}

export interface ConfigModelEntry {
  id: string;
  name: string;
  /// Effort levels this model accepts, in canonical low→high order.
  /// Empty array → non-reasoning model: the Shell hides the effort
  /// picker. Otherwise the picker shows exactly these rows; the sidecar
  /// stores the picked `value` and forwards it to the provider's API
  /// untouched.
  supportedEfforts: ConfigEffortLevel[];
  /// Default effort `value` for this model. `null` for non-reasoning
  /// models. The Shell shows this in the picker when the user has not
  /// (yet) picked, and falls back to it when the saved global pick is
  /// not in `supportedEfforts`.
  defaultEffort: string | null;
  /// `true` when the model accepts image input (catalog `input` includes
  /// `"image"`). The Shell uses this to decide whether the per-app
  /// "attach screenshot" toggle is offered, or shown as disabled with an
  /// `eye.slash` glyph indicating the active model is text-only.
  supportsVision: boolean;
}

export interface ConfigProviderEntry {
  id: string;
  name: string;
  defaultModelId: string;
  models: ConfigModelEntry[];
}

export interface ConfigSelection {
  providerId: string;
  modelId: string;
}

export type ConfigGetParams = Record<string, never>;

export interface ConfigGetResult {
  /// `null` when the user has never picked. Shell falls back to
  /// `defaultModelId` of the first provider for the initial UI selection.
  selection: ConfigSelection | null;
  /// User's last picked effort `value`, stored verbatim. `null` when
  /// never picked. Shell resolves the actual rendered effort by looking
  /// it up in the active model's `supportedEfforts`, falling back to the
  /// model's `defaultEffort`.
  effort: string | null;
  providers: ConfigProviderEntry[];
  /// One-shot flag: flips `true` the first time the Shell observes both
  /// runtime permissions granted AND a ready provider. After that the
  /// Shell stops routing back to onboard panels.
  hasCompletedOnboarding: boolean;
  /// `true` iff this `config.get` just discovered a malformed config file
  /// and reset it to `{}`. The Shell uses this to surface a one-time
  /// banner ("Settings file was corrupt and has been reset.") so the user
  /// understands why they were sent back through onboarding.
  recoveredFromCorruption: boolean;
}

export interface ConfigSetParams {
  providerId: string;
  modelId: string;
}

export interface ConfigSetResult {
  selection: ConfigSelection;
}

export interface ConfigSetEffortParams {
  /// Wire `value` of one of the active model's supported efforts. The
  /// sidecar stores it verbatim — no closed-enum validation; if the
  /// value is not actually in the active model's list, the next request
  /// silently falls back to the model's default.
  effort: string;
}

export interface ConfigSetEffortResult {
  effort: string;
}

export type ConfigMarkOnboardingCompletedParams = Record<string, never>;

export interface ConfigMarkOnboardingCompletedResult {
  hasCompletedOnboarding: true;
}

// ---------------------------------------------------------------------------
// dev.* — observability surface for the Shell's Dev Mode window.
//
// `dev.context.get`     — Shell→Bun request. Returns the latest LLM context
//                         snapshot the agent loop captured, or null if the
//                         loop hasn't produced a turn since process start.
// `dev.context.changed` — Bun→Shell notification fired once per turn,
//                         immediately before `streamSimple()` is invoked.
//
// `messagesJson` is a pre-formatted JSON string of the `Message[]` passed
// to the LLM provider — the wire's idea of "原文". The Shell renders it
// as monospace text; no further parsing is performed.
// ---------------------------------------------------------------------------

export interface DevContextSnapshot {
  /// Milliseconds since epoch.
  capturedAt: number;
  sessionId: string;
  turnId: string;
  modelId: string;
  providerId: string;
  /// Reasoning effort applied for this turn; `null` for non-reasoning models.
  effort: string | null;
  systemPrompt: string;
  /// Pretty-printed JSON of the messages array passed to `streamSimple`.
  messagesJson: string;
}

export type DevContextGetParams = Record<string, never>;

export interface DevContextGetResult {
  /// `null` when the agent loop has not yet produced a turn.
  snapshot: DevContextSnapshot | null;
}

export interface DevContextChangedParams {
  snapshot: DevContextSnapshot;
}

// ---------------------------------------------------------------------------
// session.* — bidirectional namespace (Shell↔Bun)
//
// Per docs/designs/session-management.md. Wire shape mirrors `SessionListItem`
// in `agent/session/types.ts`. `turnCount` and `lastActivityAt` are computed
// on demand by the Sidecar — no caching, no drift.
// ---------------------------------------------------------------------------

export interface SessionListItem {
  id: string;
  title: string;
  /// Milliseconds since epoch.
  createdAt: number;
  /// Number of `status === "done"` turns.
  turnCount: number;
  /// Last turn's `startedAt`; equals `createdAt` for empty sessions.
  lastActivityAt: number;
}

export interface SessionCreateParams {
  /// Optional initial title; defaults to "新对话". Auto-derivation from the
  /// first user prompt happens on submit, only if title is still default.
  title?: string;
}

export interface SessionCreateResult {
  session: SessionListItem;
}

export type SessionListParams = Record<string, never>;

export interface SessionListResult {
  /// `null` only before the Shell has issued its bootstrap `session.create`.
  activeId: string | null;
  sessions: SessionListItem[];
}

export interface SessionActivateParams {
  sessionId: string;
}

export interface SessionActivateResult {
  /// Full snapshot of the activated session's conversation, ordered by
  /// `startedAt` ascending. All statuses included (in-flight + terminal).
  /// Display-only mirror fields (thinking) are NOT carried here — see
  /// "Snapshot merge 契约" in docs/designs/session-management.md.
  snapshot: ConversationTurnWire[];
}

export interface SessionCreatedNotificationParams {
  session: SessionListItem;
}

export interface SessionActivatedNotificationParams {
  sessionId: string;
}

export type SessionListChangedNotificationParams = Record<string, never>;

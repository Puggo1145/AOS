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
export const AOS_PROTOCOL_VERSION = "1.0.0" as const;

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
  conversationTurnStarted: "conversation.turnStarted",
  conversationReset: "conversation.reset",
  uiToken: "ui.token",
  uiStatus: "ui.status",
  uiError: "ui.error",
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
  devContextGet: "dev.context.get",
  devContextChanged: "dev.context.changed",
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
  turnId: string;
  prompt: string;
  citedContext: CitedContext;
}

export interface AgentSubmitResult {
  accepted: boolean;
}

export interface AgentCancelParams {
  turnId: string;
}

export interface AgentCancelResult {
  cancelled: boolean;
}

/// `agent.reset` clears the entire conversation. Cancels any in-flight turn.
/// Sidecar emits `conversation.reset` after the wipe so all observers can
/// discard their mirrors.
export type AgentResetParams = Record<string, never>;

export interface AgentResetResult {
  ok: boolean;
}

// ---------------------------------------------------------------------------
// conversation.* — Sidecar → Shell (notifications)
//
// The sidecar owns the canonical conversation state (turns array, LLM
// history). Shell mirrors it 1:1 from these notifications:
//   - `conversation.turnStarted { turn }` fires once per `agent.submit` once
//     the turn has been registered in the sidecar's Conversation. `turn`
//     carries the snapshot the sidecar persisted (id, prompt, citedContext,
//     initial empty reply, status: thinking).
//   - `conversation.reset` fires after `agent.reset` clears the store.
//   - reply token deltas continue to flow over the existing `ui.token`
//     notification so tight streaming doesn't pay a serialization cost on
//     every character.
//   - per-turn status changes flow over `ui.status` / `ui.error` (existing).
// ---------------------------------------------------------------------------

export type TurnStatus =
  | "thinking"
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
  turn: ConversationTurnWire;
}

export type ConversationResetParams = Record<string, never>;

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
  /// CGWindowID hint. May be stale; re-resolve via computerUse.listWindows.
  windowId?: number;
}

export interface BehaviorEnvelope {
  kind: string;
  citationKey: string;
  displaySummary: string;
  /// Opaque per-producer JSON; sidecar passes through unchanged.
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
  turnId: string;
  delta: string;
}

export type UIStatus = "thinking" | "tool_calling" | "waiting_input" | "done";

export interface UIStatusParams {
  turnId: string;
  status: UIStatus;
}

export interface UIErrorParams {
  turnId: string;
  code: number;
  message: string;
  data?: JSONValue;
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

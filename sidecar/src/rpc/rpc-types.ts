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
  configGet: "config.get",
  configSet: "config.set",
  configSetEffort: "config.setEffort",
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
  clipboard?: CitedClipboard;
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

export interface ProviderInfo {
  id: string;
  name: string;
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

// ---------------------------------------------------------------------------
// config.* — Shell → Bun. Global user config (selected provider/model, etc).
// Backed by ~/.aos/config.json. Catalog snapshot is included in `config.get`
// so the Shell settings UI doesn't need a second RPC.
// ---------------------------------------------------------------------------

/// Wire enum for reasoning effort. Mirrors `Effort` in
/// `sidecar/src/llm/models/catalog.ts`. Sidecar clamps per-model at request
/// time (e.g. `xhigh` → `high` for models that don't support xhigh, and
/// any value is replaced by "off" for non-reasoning models).
export type ConfigEffort = "minimal" | "low" | "medium" | "high" | "xhigh";

export interface ConfigModelEntry {
  id: string;
  name: string;
  /// Whether the model supports any reasoning effort at all (`!model.reasoning`
  /// → `false`, in which case the Shell should disable the effort picker
  /// while this model is selected).
  reasoning: boolean;
  /// Whether the model accepts the highest "xhigh" tier specifically. The
  /// effort picker should disable that row for models with `false`.
  supportsXhigh: boolean;
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
  /// `null` when the user has never picked. Shell falls back to
  /// `defaultEffort` for the initial UI selection.
  effort: ConfigEffort | null;
  defaultEffort: ConfigEffort;
  providers: ConfigProviderEntry[];
}

export interface ConfigSetParams {
  providerId: string;
  modelId: string;
}

export interface ConfigSetResult {
  selection: ConfigSelection;
}

export interface ConfigSetEffortParams {
  effort: ConfigEffort;
}

export interface ConfigSetEffortResult {
  effort: ConfigEffort;
}

// Session-layer runtime types.
//
// Per docs/designs/session-management.md. Only types that need to be shared
// across session/{session,manager,handlers}.ts and the loop live here. Wire
// schema is owned by `rpc/rpc-types.ts`; runtime-to-wire projection is owned
// by `agent/rpc-projection.ts`.

import type { Session } from "./session";

export type SessionId = string;

export interface SessionInfo {
	/// Process-unique. `sess_<8-byte hex>`.
	id: SessionId;
	/// ms since epoch.
	createdAt: number;
	/// Default "New Conversation"; auto-derived from first user prompt (≤32 chars, first
	/// non-empty line). Derivation runs once on first submit; not auto-overwritten.
	title: string;
}

/// Manager → sink events. These are runtime events; RPC handlers perform the
/// wire projection at the dispatch edge.
export type SessionEvent =
	| { kind: "created"; session: Session }
	| { kind: "activated"; sessionId: SessionId }
	| { kind: "listChanged" };

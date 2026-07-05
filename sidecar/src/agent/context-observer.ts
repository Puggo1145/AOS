// Dev-mode observability hook for the agent loop's LLM context.
//
// Purpose: the Shell's Dev Mode window needs to display, in real time,
// exactly what is being sent to the model on each turn. This module is the
// only producer of those snapshots — the agent loop calls `publish()` once
// per turn, immediately before invoking `streamSimple()`. The observer
// fans out to a single sink (the dispatcher's `dev.context.changed`
// notification) and remembers the latest snapshot so a freshly opened
// Dev Mode window can hydrate via `dev.context.get` without waiting for
// the next turn.
//
// Architecture notes:
//   - The sink is injected (not imported) so this module has no dependency
//     on `dispatcher` or `rpc-types` — the boundary between agent state
//     and the wire protocol stays clean.
//   - Snapshot is held by VALUE; callers serialize the message array into
//     `messagesJson` once, the observer keeps that string immutable.
//   - Sink exceptions are NOT caught. The dispatcher already swallows
//     transport-level write failures internally (`.catch(logger.error)` in
//     `notify()`), so the only synchronous throws reaching this layer are
//     programmer errors (wrong namespace direction, malformed notification
//     usage). Per AGENTS.md "Fail fast and loudly" those must surface, not
//     silently disable Dev Mode while leaving `latest()` returning stale
//     data.

import type { Message } from "../llm";

export interface DevContextSnapshot {
	/// Milliseconds since epoch when this snapshot was captured.
	capturedAt: number;
	/// Session that issued this turn. Per docs/designs/session-management.md
	/// `ContextObserver` keeps a *global latest* (not per-session) — Dev Mode
	/// renders the sessionId + an "active?" badge so background turns are
	/// distinguishable.
	sessionId: string;
	turnId: string;
	modelId: string;
	providerId: string;
	/// Reasoning effort selected for this turn, or null for non-reasoning models.
	effort: string | null;
	systemPrompt: string;
	/// Pretty-printed JSON of the `Message[]` array passed to `streamSimple`.
	/// Pre-rendered into a single string so the Shell can show a faithful raw
	/// view without re-deriving formatting; the Sidecar is the only side that
	/// owns Message shape knowledge.
	messagesJson: string;
}

export type ContextObserverSink = (snapshot: DevContextSnapshot) => void;

export class ContextObserver {
	private _latest: DevContextSnapshot | null = null;
	private _sink: ContextObserverSink | null = null;

	setSink(sink: ContextObserverSink | null): void {
		this._sink = sink;
	}

	latest(): DevContextSnapshot | null {
		return this._latest;
	}

	publish(snapshot: DevContextSnapshot): void {
		this._latest = snapshot;
		const sink = this._sink;
		if (!sink) return;
		sink(snapshot);
	}

	/// Render a `Message[]` to the canonical raw-display string. Centralized
	/// so the wire format the Dev Mode window sees is one knob, edited here.
	static renderMessages(messages: ReadonlyArray<Message>): string {
		return JSON.stringify(messages, null, 2);
	}

	reset(): void {
		this._latest = null;
	}
}

/// Singleton: Notch Agent Stage 0 has exactly one agent loop. Tests can construct
/// throwaway `ContextObserver` instances and inject them.
export const contextObserver = new ContextObserver();

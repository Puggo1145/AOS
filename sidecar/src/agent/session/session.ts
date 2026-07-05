// Per-session runtime container.
//
// A Session bundles the durable conversation history, the abort registry for
// in-flight turns, and the immutable identity/info. Each session is fully
// isolated: `agent.reset { sessionId }` only touches one session's
// Conversation + TurnRegistry; other sessions keep running.

import { Conversation } from "../conversation";
import { TurnRegistry } from "../registry";
import { TodoManager } from "../todos/manager";
import { CompactBreaker } from "../compact/breaker";
import type { CitedContext } from "../../rpc/rpc-types";
import type { SessionId, SessionInfo } from "./types";

export interface PendingSteerPrompt {
	turnId: string;
	prompt: string;
	citedContext: CitedContext;
}

export interface ComputerUseAppSessionInfo {
	pid: number;
	windowId: number;
}

export class Session {
	readonly id: SessionId;
	readonly conversation: Conversation;
	readonly turns: TurnRegistry;
	/// Per-session TodoWrite plan. Lifecycle matches the conversation:
	/// fresh on session create, cleared on `agent.reset`. The `todo_write`
	/// tool mutates this; the agent loop subscribes and projects every
	/// update onto the wire as `ui.todo`.
	readonly todos: TodoManager;
	/// Per-session auto-compact circuit breaker. See `compact/breaker.ts` for
	/// why this is a value object owned by the session rather than a
	/// module-global map — the breaker's lifetime is tied to the session's,
	/// so `agent.reset` resets it directly instead of remembering to
	/// separately "forget" a keyed global entry.
	readonly compactBreaker: CompactBreaker;
	private _pendingSteer: PendingSteerPrompt | undefined;
	private _compactController: AbortController | undefined;
	/// Count of consecutive tool-call rounds in the in-flight (or most
	/// recently completed) turn during which the assistant produced no
	/// visible text. The agent loop is the sole writer; ambient providers
	/// read it to decide whether to inject a "tell the user where you are"
	/// reminder. Mirrors the loop's per-turn `consecutiveSilentToolRounds`
	/// counter so the value stays accessible to ambient renderers, which
	/// only get a `Session` handle.
	private _silentToolRounds = 0;
	private _computerUseAppSession: ComputerUseAppSessionInfo | undefined;
	private _info: SessionInfo;

	constructor(info: SessionInfo) {
		this.id = info.id;
		this._info = info;
		this.conversation = new Conversation();
		this.turns = new TurnRegistry();
		this.todos = new TodoManager();
		this.compactBreaker = new CompactBreaker();
	}

	get info(): SessionInfo {
		return this._info;
	}

	get silentToolRounds(): number {
		return this._silentToolRounds;
	}

	get pendingSteer(): PendingSteerPrompt | undefined {
		return this._pendingSteer;
	}

	get isCompacting(): boolean {
		return this._compactController !== undefined;
	}

	get computerUseAppSession(): ComputerUseAppSessionInfo | undefined {
		return this._computerUseAppSession;
	}

	beginCompact(): AbortController {
		if (this._compactController) {
			throw new Error(`session ${this.id} is already compacting`);
		}
		this._compactController = new AbortController();
		return this._compactController;
	}

	cancelCompact(): boolean {
		const controller = this._compactController;
		if (!controller) return false;
		controller.abort(new Error("compact cancelled"));
		return true;
	}

	clearCompact(controller?: AbortController): void {
		if (controller && this._compactController !== controller) return;
		this._compactController = undefined;
	}

	/// Abort any in-flight compact and drop the controller. Used by
	/// `agent.reset` — a reset session must not leave a stale compact running
	/// against a conversation that's about to be wiped.
	abortCompact(): void {
		this.cancelCompact();
		this.clearCompact();
	}

	queueSteer(input: PendingSteerPrompt): void {
		if (this._pendingSteer) {
			throw new Error(`session ${this.id} already has a queued steer prompt`);
		}
		this._pendingSteer = input;
	}

	consumeSteer(): PendingSteerPrompt | undefined {
		const next = this._pendingSteer;
		this._pendingSteer = undefined;
		return next;
	}

	cancelSteer(turnId: string): boolean {
		if (this._pendingSteer?.turnId !== turnId) return false;
		this._pendingSteer = undefined;
		return true;
	}

	setSilentToolRounds(n: number): void {
		this._silentToolRounds = n < 0 ? 0 : n;
	}

	setComputerUseAppSession(info: ComputerUseAppSessionInfo): void {
		this._computerUseAppSession = info;
	}

	clearComputerUseAppSession(): void {
		this._computerUseAppSession = undefined;
	}

	/// Replace title. Manager calls this once on first user prompt; subsequent
	/// title changes are not auto-applied.
	setTitle(title: string): void {
		this._info = { ...this._info, title };
	}
}

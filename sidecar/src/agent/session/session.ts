// Per-session runtime container.
//
// A Session bundles the durable conversation history, the abort registry for
// in-flight turns, and the immutable identity/info. Each session is fully
// isolated: `agent.reset { sessionId }` only touches one session's
// Conversation + TurnRegistry; other sessions keep running.

import { Conversation } from "../conversation";
import { TurnRegistry } from "../registry";
import { TodoManager } from "../todos/manager";
import type { CitedContext } from "../../rpc/rpc-types";
import { ComputerUseStateCache } from "./computer-use-state-cache";
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
  readonly computerUseStateCache = new ComputerUseStateCache();
  private _pendingSteer: PendingSteerPrompt | undefined;
  private _compacting = false;
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
    return this._compacting;
  }

  get computerUseAppSession(): ComputerUseAppSessionInfo | undefined {
    return this._computerUseAppSession;
  }

  setCompacting(compacting: boolean): void {
    this._compacting = compacting;
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
    if (
      this._computerUseAppSession &&
      (this._computerUseAppSession.pid !== info.pid || this._computerUseAppSession.windowId !== info.windowId)
    ) {
      this.computerUseStateCache.clear();
    }
    this._computerUseAppSession = info;
  }

  clearComputerUseAppSession(): void {
    this._computerUseAppSession = undefined;
    this.computerUseStateCache.clear();
  }

  /// Replace title. Manager calls this once on first user prompt; subsequent
  /// title changes are not auto-applied.
  setTitle(title: string): void {
    this._info = { ...this._info, title };
  }
}

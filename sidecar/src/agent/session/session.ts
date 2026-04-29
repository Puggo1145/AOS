// Per-session runtime container.
//
// A Session bundles the durable conversation history, the abort registry for
// in-flight turns, and the immutable identity/info. Each session is fully
// isolated: `agent.reset { sessionId }` only touches one session's
// Conversation + TurnRegistry; other sessions keep running.

import { Conversation } from "../conversation";
import { TurnRegistry } from "../registry";
import { TodoManager } from "../todos/manager";
import type { SessionId, SessionInfo, SessionListItem } from "./types";

export class Session {
  readonly id: SessionId;
  readonly conversation: Conversation;
  readonly turns: TurnRegistry;
  /// Per-session TodoWrite plan. Lifecycle matches the conversation:
  /// fresh on session create, cleared on `agent.reset`. The `todo_write`
  /// tool mutates this; the agent loop subscribes and projects every
  /// update onto the wire as `ui.todo`.
  readonly todos: TodoManager;
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

  /// Replace title. Manager calls this once on first user prompt; subsequent
  /// title changes are not auto-applied.
  setTitle(title: string): void {
    this._info = { ...this._info, title };
  }

  /// Wire-shape projection. `turnCount` and `lastActivityAt` are computed on
  /// demand from the live Conversation — no caching, no drift.
  toListItem(): SessionListItem {
    const turns = this.conversation.turns;
    let turnCount = 0;
    let lastActivityAt = this._info.createdAt;
    for (const t of turns) {
      if (t.status === "done") turnCount += 1;
      if (t.startedAt > lastActivityAt) lastActivityAt = t.startedAt;
    }
    return {
      id: this.id,
      title: this._info.title,
      createdAt: this._info.createdAt,
      turnCount,
      lastActivityAt,
    };
  }
}

// SessionManager — registry + active pointer for in-process sessions.
//
// Per docs/designs/session-management.md. Stage 1 is pure refactor: this
// module exists, but only one session is created at sidecar boot and the
// wire format is unchanged. Stage 2 will expose `session.*` RPCs and remove
// the bootstrap auto-create.
//
// Manager only emits *list-level* events (created / activated / listChanged).
// Turn-level notifications (`ui.token`, `conversation.turnStarted`, ...) stay
// owned by `loop.ts` to avoid turning the manager into a notification proxy.

import { Session } from "./session";
import type { SessionEvent, SessionId, SessionInfo } from "./types";

const DEFAULT_TITLE = "New Conversation";
const TITLE_MAX = 32;

export type SessionSink = (event: SessionEvent) => void;

function newSessionId(): SessionId {
  // 8 bytes = 16 hex chars; collision risk in a process lifetime is negligible.
  const bytes = new Uint8Array(8);
  crypto.getRandomValues(bytes);
  let hex = "";
  for (const b of bytes) hex += b.toString(16).padStart(2, "0");
  return `sess_${hex}`;
}

function deriveTitle(prompt: string): string {
  const firstLine = prompt.split("\n").find((l) => l.trim().length > 0)?.trim() ?? "";
  if (!firstLine) return DEFAULT_TITLE;
  // Use Array.from to count by code points so emoji/CJK don't get cut mid-codepoint.
  const cps = Array.from(firstLine);
  return cps.length <= TITLE_MAX ? firstLine : cps.slice(0, TITLE_MAX).join("");
}

export class SessionManager {
  private readonly sessions = new Map<SessionId, Session>();
  private _activeId: SessionId | null = null;
  private sink: SessionSink = () => {};

  setSink(sink: SessionSink): void {
    this.sink = sink;
  }

  get activeId(): SessionId | null {
    return this._activeId;
  }

  /// Returns the active Session, or `null` if manager is empty (only legitimate
  /// before the Shell has run its bootstrap `session.create`).
  getActive(): Session | null {
    if (this._activeId === null) return null;
    return this.sessions.get(this._activeId) ?? null;
  }

  get(sessionId: SessionId): Session | undefined {
    return this.sessions.get(sessionId);
  }

  /// Create a new Session and auto-activate. Emits `created` and `activated`.
  create(opts: { title?: string } = {}): Session {
    const now = Date.now();
    const info: SessionInfo = {
      id: newSessionId(),
      createdAt: now,
      title: opts.title?.trim() || DEFAULT_TITLE,
    };
    const s = new Session(info);
    this.sessions.set(s.id, s);
    this._activeId = s.id;
    this.sink({ kind: "created", session: s });
    this.sink({ kind: "activated", sessionId: s.id });
    return s;
  }

  /// Switch active pointer. Throws on unknown id — callers translate to the
  /// `unknownSession` RPC error code.
  activate(sessionId: SessionId): Session {
    const s = this.sessions.get(sessionId);
    if (!s) throw new Error(`unknown sessionId: ${sessionId}`);
    if (this._activeId === sessionId) return s;
    this._activeId = sessionId;
    this.sink({ kind: "activated", sessionId });
    return s;
  }

  list(): Session[] {
    // Stable order: insertion order is creation order; consumers can re-sort.
    return Array.from(this.sessions.values());
  }

  /// Title derivation hook. Manager applies the derived title once, on the
  /// FIRST user prompt of a session whose title is still the default. Returns
  /// `true` when a derivation actually happened (caller emits listChanged).
  maybeDeriveTitle(sessionId: SessionId, prompt: string): boolean {
    const s = this.sessions.get(sessionId);
    if (!s) return false;
    if (s.info.title !== DEFAULT_TITLE) return false;
    s.setTitle(deriveTitle(prompt));
    return true;
  }

  /// Notify the sink that a session's derived list fields (turnCount /
  /// lastActivityAt / title) have changed. Loop calls this on first prompt
  /// and on turn done; reset path also calls it (turnCount goes back to 0).
  notifyListChanged(): void {
    this.sink({ kind: "listChanged" });
  }
}

// Tracks live agent turns so `agent.cancel` can abort the matching stream.
//
// Each `agent.submit` allocates an AbortController under the caller-supplied
// turnId. The agent loop (loop.ts) listens to `signal.aborted` to stop pushing
// `ui.token` notifications and short-circuit the stream; the controller is
// removed when the turn finishes (success, error, or cancellation).

export class TurnRegistry {
  private readonly turns = new Map<string, AbortController>();

  /// Allocate a new controller. Throws if turnId is already active — callers
  /// (the agent.submit handler) should reject the request before this point.
  add(turnId: string): AbortController {
    if (this.turns.has(turnId)) {
      throw new Error(`turnId already active: ${turnId}`);
    }
    const c = new AbortController();
    this.turns.set(turnId, c);
    return c;
  }

  get(turnId: string): AbortController | undefined {
    return this.turns.get(turnId);
  }

  /// Abort the turn if active. Returns true iff a live turn was aborted.
  abort(turnId: string): boolean {
    const c = this.turns.get(turnId);
    if (!c) return false;
    c.abort();
    return true;
  }

  remove(turnId: string): void {
    this.turns.delete(turnId);
  }

  /// Abort every live turn. Used by `agent.reset` to ensure no stream
  /// continues writing into a conversation that's about to be wiped.
  abortAll(): void {
    for (const c of this.turns.values()) c.abort();
    this.turns.clear();
  }

  /// Test helper.
  get size(): number {
    return this.turns.size;
  }
}

export const turns = new TurnRegistry();

// AmbientProvider — pluggable source for transient context blocks injected
// at the tail of every outbound LLM request.
//
// Ambient is recomputed every round and never persisted into the
// Conversation. Each provider owns one named block (todos, future:
// worktree path, current time, environment summary, ...). The registry
// composes them; this file only declares the contract.
//
// The wrapping `<name>...</name>` tags are the registry's job — providers
// return the inner content (or `null` to skip injection entirely for the
// current round). Returning `null` keeps an idle provider out of the
// final `<ambient>` block instead of emitting an empty `<name/>`.

import type { Session } from "../session/session";

export interface AmbientProvider {
  /// Block name used as the wrapping XML tag in the rendered ambient
  /// payload. Must be a valid tag fragment — no whitespace, no `<` / `>`.
  name: string;
  /// Compute the inner content for this block. Returning `null` signals
  /// "nothing to inject this round" and the registry omits the wrapper.
  render(session: Session): string | null;
}

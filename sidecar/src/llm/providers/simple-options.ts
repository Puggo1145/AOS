// Helper shared by every `streamSimple*` provider implementation.
//
// Collapses a `SimpleStreamOptions` into the parent `StreamOptions` shape
// — i.e. drops `reasoning`, which the caller must translate per provider
// (effort string goes onto the wire as-is per the catalog's native
// vocabulary).
//
// Effort gating is NOT done here — the agent loop runs the user's pick
// through `effectiveEffort` (in `models/effort.ts`) before reaching the
// provider, so by the time a value lands here it is either supported or
// `undefined`. Providers just forward it.

import type { SimpleStreamOptions, StreamOptions } from "../types";

export function buildBaseOptions(simple: SimpleStreamOptions | undefined): StreamOptions {
  if (!simple) return {};
  const { reasoning: _r, ...base } = simple;
  return base;
}

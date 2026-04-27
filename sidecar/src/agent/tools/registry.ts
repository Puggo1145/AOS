// Process-wide tool registry.
//
// Mirrors the shape of `llm/api-registry.ts`: a single in-memory map keyed by
// tool name, plus a `sourceId` tag for batch unregister (used by tests and,
// later, by skill packages that want to swap their tool set in/out).
//
// Single registry vs per-session: AOS Stage 0 has one global agent across
// all sessions, and every session gets the same tool surface. If per-session
// scoping becomes necessary (e.g. workspace-restricted tools), add an
// `availableTo(sessionId)` filter at this layer — the loop already calls
// `list()` once per turn, so injecting a session id later is non-breaking.

import type { ToolHandler } from "./types";

interface RegistryEntry {
  handler: ToolHandler<any, any>;
  sourceId: string;
}

const DEFAULT_SOURCE_ID = "builtin";

class ToolRegistry {
  private readonly entries = new Map<string, RegistryEntry>();

  register(handler: ToolHandler<any, any>, sourceId: string = DEFAULT_SOURCE_ID): void {
    const name = handler.spec.name;
    if (this.entries.has(name)) {
      // Re-registration is a programmer error (overlapping plugins, double
      // boot). Fail loud — silently overwriting would mask whichever copy
      // the loop ends up dispatching to.
      throw new Error(`tool already registered: "${name}"`);
    }
    this.entries.set(name, { handler, sourceId });
  }

  unregisterBySource(sourceId: string): void {
    for (const [name, entry] of this.entries) {
      if (entry.sourceId === sourceId) this.entries.delete(name);
    }
  }

  /// Test helper: drop every registration regardless of source.
  clear(): void {
    this.entries.clear();
  }

  get(name: string): ToolHandler<any, any> | undefined {
    return this.entries.get(name)?.handler;
  }

  /// Snapshot of every registered handler in registration order. The loop
  /// calls this once per LLM round to build the `tools` array passed to the
  /// model.
  list(): ToolHandler<any, any>[] {
    return Array.from(this.entries.values(), (e) => e.handler);
  }
}

export const toolRegistry = new ToolRegistry();
export { ToolRegistry };

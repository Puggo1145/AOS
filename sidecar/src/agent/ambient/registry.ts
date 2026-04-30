// Process-wide ambient-provider registry.
//
// Mirrors `agent/tools/registry.ts`: a single in-memory map keyed by
// provider name, plus a `sourceId` tag for batch unregister (mirrors the
// tool registry's plugin-unload pattern — a future skill pack adding
// ambient blocks can swap them in/out as a group).
//
// Ordering: `list()` returns providers in registration order so the
// rendered `<ambient>` block has a stable layout. Callers depend on this
// (tests assert ordering; humans reading the rendered prompt expect a
// stable surface).

import type { AmbientProvider } from "./provider";

interface RegistryEntry {
  provider: AmbientProvider;
  sourceId: string;
}

const DEFAULT_SOURCE_ID = "builtin";

class AmbientRegistry {
  private readonly entries = new Map<string, RegistryEntry>();

  register(provider: AmbientProvider, sourceId: string = DEFAULT_SOURCE_ID): void {
    const name = provider.name;
    if (this.entries.has(name)) {
      // Re-registration is a programmer error (overlapping plugins, double
      // boot). Match `tools/registry.ts`: fail loud rather than silently
      // overwrite — the renderer would otherwise pick whichever copy won
      // the race and downstream debugging gets murky.
      throw new Error(`ambient provider already registered: "${name}"`);
    }
    this.entries.set(name, { provider, sourceId });
  }

  unregister(name: string): void {
    this.entries.delete(name);
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

  /// Snapshot in registration order. Callers (`renderAmbient`) iterate this
  /// once per LLM round.
  list(): AmbientProvider[] {
    return Array.from(this.entries.values(), (e) => e.provider);
  }
}

export const ambientRegistry = new AmbientRegistry();
export { AmbientRegistry };

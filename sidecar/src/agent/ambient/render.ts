// Compose the ambient block injected at the tail of every outbound LLM
// request.
//
// Layout:
//
//   <ambient>
//   <providerA>
//   ...providerA inner text...
//   </providerA>
//   <providerB>
//   ...providerB inner text...
//   </providerB>
//   </ambient>
//
// Providers returning `null` are skipped — no empty `<name/>` ever ships.
// If every provider returns `null` (no open todos, no other live data),
// the entire function returns `null` and the loop omits the ambient
// message altogether. An empty `<ambient/>` block would just be noise the
// model has to ignore on every round.

import type { Session } from "../session/session";
import { ambientRegistry } from "./registry";

export function renderAmbient(session: Session): string | null {
  const blocks: string[] = [];
  for (const provider of ambientRegistry.list()) {
    const inner = provider.render(session);
    if (inner === null) continue;
    blocks.push(`<${provider.name}>\n${inner}\n</${provider.name}>`);
  }
  if (blocks.length === 0) return null;
  return `<ambient>\n${blocks.join("\n")}\n</ambient>`;
}

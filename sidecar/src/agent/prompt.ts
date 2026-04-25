// Per-turn prompt assembly: folds the wire `CitedContext` into the LLM-facing
// user message so the agent actually sees what the user was looking at.
//
// Per docs/designs/os-sense.md "与 AOS 主进程集成":
//   "BehaviorEnvelope payload 完全 opaque, Bun 持有、序列化进 prompt、转发给 LLM"
//
// Format is plain text wrapped in <os-context> tags so the LLM can clearly
// separate the user's prompt from the captured OS state. Each behavior carries
// `kind` + `displaySummary` + opaque `payload`; the LLM is the only consumer
// that interprets the payload structure by `kind`.

import type { CitedContext, BehaviorEnvelope } from "../rpc/rpc-types";
import type { UserMessage } from "../llm/types";

/// Build the LLM `UserMessage` for a turn. If `citedContext` carries any
/// non-empty field, prepend an `<os-context>...</os-context>` block before the
/// user prompt so the agent receives both the captured environment and the
/// user's question in a single message.
///
/// Shape rule: an empty CitedContext (every field undefined) yields a message
/// with the bare prompt — no tags, no whitespace, byte-for-byte the previous
/// behavior. This keeps the trivial case (no Sense data yet) clean.
export function buildUserMessage(input: {
  prompt: string;
  citedContext: CitedContext;
  startedAt: number;
}): UserMessage {
  const block = formatCitedContext(input.citedContext);
  const content = block.length > 0 ? `${block}\n\n${input.prompt}` : input.prompt;
  return {
    role: "user",
    content,
    timestamp: input.startedAt,
  };
}

/// Render a `CitedContext` as a plain-text block. Returns `""` when nothing
/// in the context is populated. Exported so tests can pin its shape without
/// constructing a full `UserMessage`.
export function formatCitedContext(ctx: CitedContext): string {
  const lines: string[] = [];

  if (ctx.app) {
    const ident = ctx.app.bundleId ? `${ctx.app.name} (${ctx.app.bundleId})` : ctx.app.name;
    lines.push(`App: ${ident}`);
  }
  if (ctx.window) {
    lines.push(`Window: ${ctx.window.title}`);
  }
  if (ctx.clipboard) {
    lines.push(`Clipboard: ${formatClipboard(ctx.clipboard)}`);
  }
  if (ctx.behaviors && ctx.behaviors.length > 0) {
    lines.push("Behaviors:");
    for (const b of ctx.behaviors) {
      lines.push(...formatBehavior(b));
    }
  }
  if (ctx.visual) {
    // Frame bytes are intentionally NOT included — the LLM call this round
    // is text-only. The presence + capturedAt + size is still useful signal.
    lines.push(
      `Visual: ${ctx.visual.frameSize.width}x${ctx.visual.frameSize.height} captured ${ctx.visual.capturedAt}`,
    );
  }

  if (lines.length === 0) return "";
  return ["<os-context>", ...lines, "</os-context>"].join("\n");
}

function formatClipboard(clip: NonNullable<CitedContext["clipboard"]>): string {
  switch (clip.kind) {
    case "text":
      return `text "${truncate(clip.content, 200)}"`;
    case "filePaths":
      return `files [${clip.paths.join(", ")}]`;
    case "image":
      return `image ${clip.metadata.width}x${clip.metadata.height} ${clip.metadata.type}`;
  }
}

function formatBehavior(b: BehaviorEnvelope): string[] {
  const head = `  - ${b.kind}: ${b.displaySummary}`;
  // Opaque payload — Bun does not interpret. JSON.stringify with sorted keys
  // gives a stable, compact rendering; LLM reads the structure per `kind`.
  let payloadLine: string | null;
  try {
    const payloadJson = JSON.stringify(b.payload);
    payloadLine = payloadJson === undefined ? null : `    payload: ${payloadJson}`;
  } catch {
    payloadLine = null;
  }
  return payloadLine ? [head, payloadLine] : [head];
}

function truncate(s: string, max: number): string {
  if (s.length <= max) return s;
  return `${s.slice(0, max)}…[+${s.length - max} chars]`;
}

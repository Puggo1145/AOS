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
import type { ImageContent, UserContent, UserMessage } from "../llm/types";

/// Build the LLM `UserMessage` for a turn. If `citedContext` carries any
/// non-empty field, prepend an `<os-context>...</os-context>` block before the
/// user prompt so the agent receives both the captured environment and the
/// user's question in a single message.
///
/// Shape rule: an empty CitedContext (every field undefined) yields a message
/// with the bare prompt — no tags, no whitespace, byte-for-byte the previous
/// behavior. This keeps the trivial case (no Sense data yet) clean.
///
/// Visual frames: when `citedContext.visual.frame` is present, the actual
/// image bytes ride alongside the text as an `ImageContent` block so the
/// agent can *see* the user's window. For non-vision models the provider's
/// `transformMessages` swaps the image for a placeholder text block — the
/// catalog's `model.input` is the single source of truth, so this builder
/// does not branch on capability itself.
export function buildUserMessage(input: {
  prompt: string;
  citedContext: CitedContext;
  startedAt: number;
}): UserMessage {
  const block = formatCitedContext(input.citedContext);
  // Shell ships clipboard pastes as inline markers (`[[clipboard:N]]`)
  // inside the prompt — one per chip the user inserted into the rich
  // input. Expand them here so the LLM sees the chip's content at the
  // exact position the user placed it. The position carries intent:
  // "summarize <paste1> using <paste2>" and the swap read differently.
  const expandedPrompt = expandClipboardMarkers(input.prompt, input.citedContext.clipboards ?? []);
  const text = block.length > 0 ? `${block}\n\n${expandedPrompt}` : expandedPrompt;
  const image = imageFromVisual(input.citedContext.visual);
  if (image) {
    const content: UserContent[] = [{ type: "text", text }, image];
    return {
      role: "user",
      content,
      timestamp: input.startedAt,
    };
  }
  return {
    role: "user",
    content: text,
    timestamp: input.startedAt,
  };
}

/// Translate a `CitedVisual` into a wire `ImageContent` block. Returns
/// `null` when no frame is attached (the screenshot toggle was off, or
/// capture failed). Frame bytes ride to the LLM verbatim; the provider
/// layer adds the data URL framing.
function imageFromVisual(visual: CitedContext["visual"]): ImageContent | null {
  if (!visual || !visual.frame) return null;
  return { type: "image", data: visual.frame, mimeType: "image/png" };
}

/// Substitute every `[[clipboard:N]]` marker in `prompt` with an inline
/// description of the corresponding entry in `clipboards`. Markers whose
/// index is out of range are left as-is — that's a Shell↔Sidecar contract
/// violation worth surfacing to the LLM rather than silently dropping.
function expandClipboardMarkers(prompt: string, clipboards: CitedClipboardLike[]): string {
  return prompt.replace(/\[\[clipboard:(\d+)\]\]/g, (match, idxStr) => {
    const idx = Number.parseInt(idxStr, 10);
    const clip = clipboards[idx];
    if (!clip) return match;
    return formatClipboard(clip, idx + 1);
  });
}

type CitedClipboardLike = NonNullable<CitedContext["clipboards"]>[number];

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
  // Clipboards are intentionally NOT listed here. Shell ships them as
  // inline `[[clipboard:N]]` markers inside the prompt, and we expand
  // those markers to `<clipboard N: …>` at the user's caret position.
  // Re-listing them in os-context would duplicate the payload AND
  // strip the position signal the marker carried.
  if (ctx.behaviors && ctx.behaviors.length > 0) {
    lines.push("Behaviors:");
    for (const b of ctx.behaviors) {
      lines.push(...formatBehavior(b));
    }
  }
  // Visual frames are NOT projected as text. When present, `buildUserMessage`
  // attaches the actual bytes as an `ImageContent` block; redundantly
  // describing size/capturedAt in <os-context> would just pollute the
  // vision model's prompt with metadata it can already infer from the image.
  // For non-vision targets, the provider's `transformMessages` swaps the
  // image for an explicit `[image omitted: ...]` placeholder — that path
  // already self-narrates, no extra metadata line needed here.

  if (lines.length === 0) return "";
  return ["<os-context>", ...lines, "</os-context>"].join("\n");
}

/// Render a single clipboard entry as a closed XML element. The opening
/// tag carries the chip's 1-based `index` (matches the user's visual
/// "chip #N") and the payload `kind`; the body holds the content. Keeps
/// shape symmetric with the surrounding `<os-context>` block so the LLM
/// has one consistent parse rule.
function formatClipboard(clip: CitedClipboardLike, index: number): string {
  switch (clip.kind) {
    case "text":
      return `<clipboard index="${index}" kind="text">${escapeXmlText(clip.content)}</clipboard>`;
    case "filePaths":
      return `<clipboard index="${index}" kind="filePaths">${escapeXmlText(clip.paths.join("\n"))}</clipboard>`;
    case "image":
      return `<clipboard index="${index}" kind="image" width="${clip.metadata.width}" height="${clip.metadata.height}" type="${escapeXmlAttr(clip.metadata.type)}" />`;
  }
}

/// Escape characters that would break XML element-body framing. Clipboard
/// payloads are user-pasted (not adversarial), but a literal `</clipboard>`
/// or stray `<` would still confuse the LLM's parse of the structure we
/// promised it. Keep the escape set minimal — just enough to preserve
/// element boundaries.
function escapeXmlText(s: string): string {
  return s.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
}

/// Same as `escapeXmlText` plus `"` because attribute values are quoted.
function escapeXmlAttr(s: string): string {
  return escapeXmlText(s).replaceAll('"', "&quot;");
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


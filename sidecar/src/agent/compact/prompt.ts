// System prompt + NO_TOOLS preamble for the compaction summarization
// pass.
//
// Kept deliberately short and general (this harness is not coding-specific
// — same prompt has to handle email drafts, research threads, computer-use
// sessions, etc.). Four sections are the minimum that empirically retain
// enough state for the model to keep working post-compact:
//
//   1) intent     — what the user has been asking for, end-to-end
//   2) progress   — what has already been done / decided
//   3) current    — what the agent was actively working on at compaction
//   4) anchors    — concrete identifiers (paths, ids, urls, names) the
//                   model must remember verbatim to continue
//
// The NO_TOOLS preamble is the same idea Claude Code uses: tool calls
// here would be wasted (and on some providers will silently fail) — the
// model already has every byte of history it could possibly need above.

const NO_TOOLS_PREAMBLE = [
	"CRITICAL: Respond with TEXT ONLY. Do NOT call any tools.",
	"- The full conversation above is the only input you need.",
	"- Tool calls will be REJECTED and waste your only turn.",
	"- Output a plain-text summary in the structure described below.",
].join("\n");

const STRUCTURE = [
	"Structure your reply with exactly these four sections, in order:",
	"",
	"  1. Intent — the user's overall goal across this conversation, in one to three sentences. Capture nuance: what they want, what they explicitly do not want, and any constraints they stated.",
	"  2. Progress — bullet list of what has already been completed, decided, or ruled out. Be specific. If a decision was made for a non-obvious reason, include the reason.",
	"  3. Current — what the agent (you, in the future) was actively doing at the moment of compaction. One short paragraph. If the active step is mid-flight (a tool call pending, a question awaiting user reply), say so.",
	"  4. Anchors — bullet list of every concrete identifier worth remembering verbatim: file paths, function names, urls, ids, exact phrasings the user used, version numbers. These are the things a summary normally loses; do not lose them here.",
	"",
	"Be concise but lossless on the Anchors. Skip pleasantries, restated tool output, and anything the model can re-derive trivially.",
].join("\n");

export const COMPACT_SYSTEM_PROMPT = [
	NO_TOOLS_PREAMBLE,
	"",
	"You are summarizing a multi-turn conversation between a user and an AI agent so the agent can continue working after its conversation history is compacted.",
	"",
	STRUCTURE,
].join("\n");

/// Final user-role nudge appended after the conversation history. The
/// trailing assistant turn must be a fresh assistant reply that IS the
/// summary — this nudge gives the model an explicit "now produce it" cue
/// rather than relying on it inferring a turn boundary.
export const COMPACT_FINAL_REQUEST =
	"The conversation above is the full history to compact. Produce the four-section summary now. Plain text, no tool calls.";

// Cross-model message normalization (guide §6).
//
// Even though the Notch Agent agent loop currently only ever submits a single
// `UserMessage` per turn (zero-history single-shot), `transformMessages`
// is implemented in full so that the future thinking / tool use / multi
// turn paths require zero edits here.
//
// Normalizations performed (in order):
//   1. Drop assistant messages whose stopReason is "error" or "aborted"
//      — they cannot be safely replayed.
//   2. If the target model lacks vision capability, replace `image`
//      blocks in user / toolResult messages with a placeholder text
//      block. Consecutive placeholders fold into one block.
//   3. For each assistant message, decide same-source vs cross-source:
//        same   = api+provider+model all equal
//        cross  = anything else
//      - Thinking blocks are kept verbatim when same-source.
//        When cross-source: a thinking block with non-empty body
//        downgrades to a `text` block (signature dropped); empty /
//        redacted blocks are dropped.
//      - Text blocks: same-source keeps `textSignature`; cross-source
//        strips it.
//      - ToolCall blocks: cross-source drops `thoughtSignature` and
//        normalizes the `id` via `normalizeToolCallId`. The original
//        id → new id mapping is recorded so subsequent toolResult
//        messages can be rewritten consistently.
//   4. Rewrite each toolResult's `toolCallId` via the id map.
//   5. Synthesize empty toolResult messages for any toolCall whose id
//      was emitted but never matched by a toolResult, before the next
//      assistant or user boundary (per guide §4.4).

import type {
	AssistantMessage,
	AssistantContent,
	Api,
	Message,
	Model,
	TextContent,
	ToolCall,
	ToolResultMessage,
	ToolResultContent,
	UserContent,
	UserMessage,
} from "../types";

export type NormalizeToolCallIdFn<TApi extends Api> = (
	id: string,
	model: Model<TApi>,
	source: AssistantMessage,
) => string;

const IMAGE_PLACEHOLDER =
	"[image omitted: target model does not support vision]";

function isSameSource<TApi extends Api>(
	msg: AssistantMessage,
	model: Model<TApi>,
): boolean {
	return (
		msg.api === model.api &&
		msg.provider === model.provider &&
		msg.model === model.id
	);
}

function downgradeUserContent(
	content: UserMessage["content"],
	hasVision: boolean,
): UserMessage["content"] {
	if (hasVision) return content;
	if (typeof content === "string") return content;
	return mergePlaceholders(
		content.map(
			(block): UserContent =>
				block.type === "image"
					? { type: "text", text: IMAGE_PLACEHOLDER }
					: block,
		),
	) as UserContent[];
}

function downgradeToolResultContent(
	content: ToolResultContent[],
	hasVision: boolean,
): ToolResultContent[] {
	if (hasVision) return content;
	return mergePlaceholders(
		content.map(
			(block): ToolResultContent =>
				block.type === "image"
					? { type: "text", text: IMAGE_PLACEHOLDER }
					: block,
		),
	) as ToolResultContent[];
}

function mergePlaceholders<T extends { type: string; text?: string }>(
	blocks: T[],
): T[] {
	const out: T[] = [];
	for (const b of blocks) {
		const last = out[out.length - 1];
		if (
			last &&
			last.type === "text" &&
			b.type === "text" &&
			last.text === IMAGE_PLACEHOLDER &&
			b.text === IMAGE_PLACEHOLDER
		) {
			continue;
		}
		out.push(b);
	}
	return out;
}

export function transformMessages<TApi extends Api>(
	messages: Message[],
	model: Model<TApi>,
	normalizeToolCallId?: NormalizeToolCallIdFn<TApi>,
): Message[] {
	const hasVision = model.input.includes("image");
	const idMap = new Map<string, string>();
	const result: Message[] = [];

	// First pass — drop unreplayable assistant messages and rewrite blocks
	// / ids. We collect into `result` directly; toolCall id remapping is
	// recorded in `idMap` so that later toolResult messages can be patched.
	for (const msg of messages) {
		if (msg.role === "assistant") {
			if (msg.stopReason === "error" || msg.stopReason === "aborted") continue;
			const same = isSameSource(msg, model);
			const newContent: AssistantContent[] = [];
			for (const block of msg.content) {
				if (block.type === "thinking") {
					if (same) {
						newContent.push(block);
					} else {
						// Cross-source: empty / redacted → drop, otherwise downgrade
						// to plain text without signature.
						if (
							block.redacted ||
							!block.thinking ||
							block.thinking.trim() === ""
						)
							continue;
						newContent.push({
							type: "text",
							text: block.thinking,
						} as TextContent);
					}
					continue;
				}
				if (block.type === "text") {
					newContent.push(
						same ? block : ({ type: "text", text: block.text } as TextContent),
					);
					continue;
				}
				if (block.type === "toolCall") {
					const original = block.id;
					let newId = original;
					if (!same) {
						if (normalizeToolCallId)
							newId = normalizeToolCallId(original, model, msg);
						const { thoughtSignature: _ts, ...rest } = block;
						newContent.push({ ...rest, id: newId } as ToolCall);
					} else {
						newContent.push(block);
					}
					if (newId !== original) idMap.set(original, newId);
					continue;
				}
				// Future-proof: unknown content blocks pass through
				newContent.push(block);
			}
			result.push({ ...msg, content: newContent });
			continue;
		}
		if (msg.role === "user") {
			result.push({
				...msg,
				content: downgradeUserContent(msg.content, hasVision),
			});
			continue;
		}
		if (msg.role === "toolResult") {
			const remappedId = idMap.get(msg.toolCallId) ?? msg.toolCallId;
			result.push({
				...msg,
				toolCallId: remappedId,
				content: downgradeToolResultContent(msg.content, hasVision),
			});
		}
	}

	// Second pass — synthesize empty toolResult messages for orphan
	// toolCalls. We scan forward; a "boundary" is the next assistant /
	// user message after an assistant with toolCalls (per guide §4.4),
	// or end-of-list.
	return synthesizeOrphanToolResults(result);
}

function synthesizeOrphanToolResults(messages: Message[]): Message[] {
	const out: Message[] = [];
	for (let i = 0; i < messages.length; i++) {
		const m = messages[i]!;
		out.push(m);
		if (m.role !== "assistant") continue;
		const calls = m.content.filter((c): c is ToolCall => c.type === "toolCall");
		if (calls.length === 0) continue;
		// Walk past contiguous toolResult messages, recording the call ids
		// that were satisfied AND copying them straight through to `out`
		// in their original order.
		const seenIds = new Set<string>();
		let j = i + 1;
		while (j < messages.length && messages[j]!.role === "toolResult") {
			const tr = messages[j] as ToolResultMessage;
			seenIds.add(tr.toolCallId);
			out.push(tr);
			j++;
		}
		// Append synthesized empty results for any unmet calls, in declaration order.
		for (const call of calls) {
			if (!seenIds.has(call.id)) {
				out.push({
					role: "toolResult",
					toolCallId: call.id,
					toolName: call.name,
					content: [
						{ type: "text", text: "No result provided" } as TextContent,
					],
					isError: true,
					timestamp: Date.now(),
				});
			}
		}
		// Advance the outer loop past the toolResults we just consumed.
		i = j - 1;
	}
	return out;
}

/// OpenAI Responses tool call ids may include `|` and exceed 64 chars,
/// which trips strict-id providers. Normalize to `[A-Za-z0-9_-]{1,64}`.
export function normalizeOpenAIResponsesToolCallId(id: string): string {
	return id.replace(/[^a-zA-Z0-9_-]/g, "_").slice(0, 64);
}

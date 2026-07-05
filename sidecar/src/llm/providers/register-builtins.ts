// Registers the built-in `openai-responses` API provider.
//
// Lazy: the actual provider module is dynamically imported on the first
// `stream()` invocation. This keeps the public `index.ts` cheap to load
// when callers only need types or the model registry.

import { errorText } from "../../errors";
import { registerApiProvider } from "../api-registry";
import { AssistantMessageEventStream } from "../utils/event-stream";
import type {
	Api,
	ApiProviderEntry,
	Context,
	Model,
	ProviderStreamOptions,
	SimpleStreamOptions,
	StreamFunction,
	SimpleStreamFunction,
	AssistantMessage,
} from "../types";

let registered = false;

function lazyError(
	model: Model<Api>,
	error: unknown,
): AssistantMessageEventStream {
	const out = new AssistantMessageEventStream();
	const message: AssistantMessage = {
		role: "assistant",
		content: [],
		api: model.api,
		provider: model.provider,
		model: model.id,
		usage: {
			input: 0,
			output: 0,
			cacheRead: 0,
			cacheWrite: 0,
			totalTokens: 0,
			cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
		},
		stopReason: "error",
		errorMessage: `Failed to load openai-responses provider: ${errorText(error)}`,
		timestamp: Date.now(),
	};
	queueMicrotask(() => {
		out.push({ type: "error", reason: "error", error: message });
		out.end();
	});
	return out;
}

function createLazyStream<TApi extends Api>(
	load: () => Promise<StreamFunction<TApi>>,
): StreamFunction<TApi> {
	return (
		model: Model<TApi>,
		context: Context,
		options?: ProviderStreamOptions,
	) => {
		const outer = new AssistantMessageEventStream();
		load()
			.then((fn) => {
				const inner = fn(model, context, options);
				// Forward all events from inner → outer.
				(async () => {
					try {
						for await (const ev of inner) outer.push(ev);
						const final = await inner.result();
						outer.end(final);
					} catch {
						// Inner stream's error event already pushed; just end.
						outer.end();
					}
				})();
			})
			.catch((err) => {
				const errStream = lazyError(model, err);
				(async () => {
					for await (const ev of errStream) outer.push(ev);
					outer.end();
				})();
			});
		return outer;
	};
}

function createLazySimpleStream<TApi extends Api>(
	load: () => Promise<SimpleStreamFunction<TApi>>,
): SimpleStreamFunction<TApi> {
	return (
		model: Model<TApi>,
		context: Context,
		simple?: SimpleStreamOptions,
	) => {
		const outer = new AssistantMessageEventStream();
		load()
			.then((fn) => {
				const inner = fn(model, context, simple);
				(async () => {
					try {
						for await (const ev of inner) outer.push(ev);
						const final = await inner.result();
						outer.end(final);
					} catch {
						outer.end();
					}
				})();
			})
			.catch((err) => {
				const errStream = lazyError(model, err);
				(async () => {
					for await (const ev of errStream) outer.push(ev);
					outer.end();
				})();
			});
		return outer;
	};
}

export function registerBuiltins(): void {
	if (registered) return;
	registered = true;

	const responsesEntry: ApiProviderEntry<"openai-responses"> = {
		api: "openai-responses",
		stream: createLazyStream(async () => {
			const m = await import("./openai-responses");
			return m.streamOpenaiResponses;
		}),
		streamSimple: createLazySimpleStream(async () => {
			const m = await import("./openai-responses");
			return m.streamSimpleOpenaiResponses;
		}),
		sourceId: "builtin",
	};
	registerApiProvider(responsesEntry);

	const completionsEntry: ApiProviderEntry<"openai-completions"> = {
		api: "openai-completions",
		stream: createLazyStream(async () => {
			const m = await import("./openai-completions");
			return m.streamOpenAICompletions;
		}),
		streamSimple: createLazySimpleStream(async () => {
			const m = await import("./openai-completions");
			return m.streamSimpleOpenAICompletions;
		}),
		sourceId: "builtin",
	};
	registerApiProvider(completionsEntry);

	const deepseekEntry: ApiProviderEntry<"deepseek"> = {
		api: "deepseek",
		stream: createLazyStream(async () => {
			const m = await import("./deepseek");
			return m.streamDeepseek;
		}),
		streamSimple: createLazySimpleStream(async () => {
			const m = await import("./deepseek");
			return m.streamSimpleDeepseek;
		}),
		sourceId: "builtin",
	};
	registerApiProvider(deepseekEntry);
}

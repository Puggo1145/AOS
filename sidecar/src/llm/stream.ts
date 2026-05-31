// Top-level façade: routes by `model.api` to a registered provider.
//
// The agent loop only ever calls `stream` / `streamSimple` from here;
// it must NOT import provider modules directly (see design doc
// "包边界" rules).

import { getApiProvider } from "./api-registry";
import type {
	Api,
	Context,
	Model,
	ProviderStreamOptions,
	SimpleStreamOptions,
} from "./types";
import { AssistantMessageEventStream } from "./utils/event-stream";

export function stream<TApi extends Api>(
	model: Model<TApi>,
	context: Context,
	options?: ProviderStreamOptions,
): AssistantMessageEventStream {
	const provider = getApiProvider(model.api);
	if (!provider) {
		return immediateError(
			model,
			`No API provider registered for api: ${model.api}`,
		);
	}
	return provider.stream(model, context, options);
}

export function streamSimple<TApi extends Api>(
	model: Model<TApi>,
	context: Context,
	simpleOptions?: SimpleStreamOptions,
): AssistantMessageEventStream {
	const provider = getApiProvider(model.api);
	if (!provider) {
		return immediateError(
			model,
			`No API provider registered for api: ${model.api}`,
		);
	}
	if (!provider.streamSimple) {
		// Fall back: treat simple options as base options.
		return provider.stream(
			model,
			context,
			simpleOptions as ProviderStreamOptions,
		);
	}
	return provider.streamSimple(model, context, simpleOptions);
}

function immediateError<TApi extends Api>(
	model: Model<TApi>,
	message: string,
): AssistantMessageEventStream {
	const stream = new AssistantMessageEventStream();
	const errorMessage = {
		role: "assistant" as const,
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
		stopReason: "error" as const,
		errorMessage: message,
		timestamp: Date.now(),
	};
	// Dispatch on a microtask so callers can install iterators first.
	queueMicrotask(() => {
		stream.push({ type: "error", reason: "error", error: errorMessage });
		stream.end();
	});
	return stream;
}

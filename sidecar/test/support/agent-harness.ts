import { Dispatcher } from "../../src/rpc/dispatcher";
import {
	StdioTransport,
	type ByteSink,
	type ByteSource,
} from "../../src/rpc/transport";
import type { Conversation } from "../../src/agent/conversation";
import { SessionManager } from "../../src/agent/session/manager";
import type {
	PermissionAuthorizeInput,
	PermissionAuthorizeResult,
	PermissionAuthorizer,
} from "../../src/agent/permissions";
import type { Api, AssistantMessage, Model } from "../../src/llm";

export interface CapturedFrame {
	method: string;
	params: any;
	id?: any;
}

export interface CapturedResponse {
	id: any;
	result?: any;
	error?: any;
}

export interface CapturedRpc {
	notifications: CapturedFrame[];
	requests: CapturedFrame[];
	responses: CapturedResponse[];
}

export function makeFakeModel(overrides: Partial<Model<Api>> = {}): Model<Api> {
	return {
		id: "fake-model",
		name: "Fake",
		api: "openai-responses",
		provider: "test",
		baseUrl: "",
		reasoning: false,
		input: ["text"],
		cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
		contextWindow: 100_000,
		maxTokens: 1_000,
		...overrides,
	};
}

export function fakeAssistantMessage(
	model: Model<Api>,
	opts: { errorMessage?: string } = {},
): AssistantMessage {
	return {
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
		stopReason: opts.errorMessage ? "error" : "stop",
		errorMessage: opts.errorMessage,
		timestamp: Date.now(),
	};
}

export function makeCapturingDispatcher(): {
	dispatcher: Dispatcher;
	captured: CapturedRpc;
	pushInbound: (frame: object) => void;
} {
	const inbound: string[] = [];
	const inboundWaiters: ((s: string) => void)[] = [];
	const pushInboundLine = (line: string): void => {
		if (inboundWaiters.length > 0) inboundWaiters.shift()!(line);
		else inbound.push(line);
	};
	const source: ByteSource = (async function* () {
		while (true) {
			if (inbound.length > 0) {
				yield Buffer.from(inbound.shift()!, "utf8");
				continue;
			}
			yield Buffer.from(
				await new Promise<string>((r) => inboundWaiters.push(r)),
				"utf8",
			);
		}
	})();
	const captured: CapturedRpc = {
		notifications: [],
		requests: [],
		responses: [],
	};
	const sink: ByteSink = {
		write(line: string): boolean {
			const trimmed = line.endsWith("\n") ? line.slice(0, -1) : line;
			const frame = JSON.parse(trimmed);
			if ("method" in frame && !("id" in frame)) {
				captured.notifications.push({
					method: frame.method,
					params: frame.params,
				});
			} else if ("id" in frame && !("method" in frame)) {
				captured.responses.push({
					id: frame.id,
					result: frame.result,
					error: frame.error,
				});
			} else if ("method" in frame && "id" in frame) {
				captured.requests.push({
					id: frame.id,
					method: frame.method,
					params: frame.params,
				});
				if (frame.method === "computerUse.stopAppSession") {
					pushInboundLine(
						`${JSON.stringify({ jsonrpc: "2.0", id: frame.id, result: { stopped: true, pid: 123 } })}\n`,
					);
				}
			}
			return true;
		},
	};
	const transport = new StdioTransport(source, sink);
	const dispatcher = new Dispatcher(transport);
	void dispatcher.start();
	return {
		dispatcher,
		captured,
		pushInbound: (frame: object) => {
			pushInboundLine(`${JSON.stringify(frame)}\n`);
		},
	};
}

export function setupSession(): {
	manager: SessionManager;
	sessionId: string;
	convo: Conversation;
} {
	const manager = new SessionManager();
	const session = manager.create();
	return { manager, sessionId: session.id, convo: session.conversation };
}

export async function flush(ms = 80): Promise<void> {
	await new Promise((r) => setTimeout(r, ms));
}

export function allowAllPermissionGateway(): PermissionAuthorizer {
	return {
		async authorize(
			_input: PermissionAuthorizeInput,
		): Promise<PermissionAuthorizeResult> {
			return { kind: "allowed" };
		},
		clearTurnGrants(_sessionId: string, _turnId: string): void {
			// Test helper: no turn-scoped state.
		},
	};
}

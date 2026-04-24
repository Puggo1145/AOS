# LLM Provider 适配层设计指南

基于对 pi-mono `packages/ai` 的通读整理，抽取多 provider LLM 适配层的通用设计模式。不包含 AOS 业务逻辑，聚焦「怎么把 Anthropic / OpenAI / Google / vLLM / 自部署 等风格各异的 LLM API 塞进同一条调用路径」。

目标读者：实现 AOS agent runtime 的工程师。本文是上层架构参考，不覆盖任何单一 provider 的完整字段。

---

## 0. 名词约定

| 术语 | 含义 |
|---|---|
| Provider | 供应商身份（`anthropic`、`openai`、`google-vertex`、`openrouter`、某个自部署 endpoint 等）。决定鉴权与 baseUrl |
| API | 协议族（`anthropic-messages`、`openai-completions`、`openai-responses`、`google-generative-ai`、`bedrock-converse-stream`）。决定消息序列化与流式协议 |
| Model | Provider + API + 具体型号的组合实例，携带 cost / context window / capabilities |
| Content block | 单条消息内部的最小可寻址单元：text / thinking / image / toolCall / toolResult |
| Stream event | 流式协议里的一个事件（start / delta / end / done / error），agent runtime 消费的最小单位 |
| Capability | 模型能力声明：vision / thinking / tool use / 长缓存 / xhigh reasoning 等 |

核心架构：

```
                          ┌───── anthropic-messages ──── Anthropic / Copilot / z.ai / Bedrock-proxy ...
Agent Runtime ─▶ stream() │
(Model, Context, Options) ├───── openai-completions ──── OpenAI / Groq / Cerebras / xAI / OpenRouter / vLLM / ...
                          │
                          ├───── openai-responses ─────── OpenAI (new) / Azure
                          │
                          ├───── google-generative-ai ─── Gemini / Vertex / Gemini-CLI
                          │
                          └───── bedrock-converse-stream ─ AWS Bedrock
                              ▲
                              │  ApiProvider registry
                              │  (lazy-loaded modules)

                          每条分支内部：
                          Message/Tool → provider 格式 → 发起 HTTP 流
                          provider stream events → 统一 AssistantMessageEvent → 上抛
```

设计底线：agent runtime 只认识一个 `Model<Api>`、一份 `Context`、一条 `AssistantMessageEventStream`。跨 provider 的所有差异收敛在 provider 实现内部。

---

## 1. 两层抽象：Provider vs API

### 1.1 为什么不一把梭

不同供应商可能共用同一种协议（OpenAI Completions 协议被 Groq / Cerebras / xAI / OpenRouter / vLLM / Mistral / z.ai 直接复用）；同一供应商也可能出多种协议（OpenAI 同时提供 Completions 和 Responses；Google 有 Generative AI、Vertex、Gemini CLI 三套）。

所以分两层：

- **API 层**：一份协议一份 provider 实现，处理序列化 / 流解析 / tool 格式 / 错误映射
- **Provider 层**：身份 + 鉴权 + baseUrl + 少量协议微调（"compat"），复用同一份 API 实现

Model 通过 `model.api` 把两者串起来：

```typescript
interface Model<TApi extends Api> {
  id: string;              // "claude-opus-4-5-20250325"
  name: string;            // 人类可读名
  api: TApi;               // 协议族："anthropic-messages"
  provider: Provider;      // 身份："anthropic" / "github-copilot" / "zai" / ...
  baseUrl: string;
  reasoning: boolean;      // capability: thinking
  input: ("text" | "image")[];  // capability: vision
  cost: { input; output; cacheRead; cacheWrite };  // $/million tokens
  contextWindow: number;
  maxTokens: number;
  headers?: Record<string, string>;
  compat?: /* 按 api 分叉的微调字段 */ ;
}
```

### 1.2 API registry

调用方只面对一个顶层函数：

```typescript
export function stream<TApi extends Api>(
  model: Model<TApi>,
  context: Context,
  options?: StreamOptions,
): AssistantMessageEventStream {
  const provider = getApiProvider(model.api);
  if (!provider) throw new Error(`No API provider registered for api: ${model.api}`);
  return provider.stream(model, context, options);
}
```

注册由各 provider 模块自己完成，允许第三方插入自定义 api：

```typescript
registerApiProvider({
  api: "anthropic-messages",
  stream: streamAnthropic,
  streamSimple: streamSimpleAnthropic,
});
```

API registry 保留 `sourceId` 便于某个插件卸载时批量反注册 `unregisterApiProviders(sourceId)`。

### 1.3 懒加载

Anthropic SDK、OpenAI SDK、Google GenAI SDK、AWS SDK 加起来几 MB。只有真正用到对应 api 时才动态 import：

```typescript
function createLazyStream<TApi>(load: () => Promise<Module>): StreamFunction<TApi> {
  return (model, context, options) => {
    const outer = new AssistantMessageEventStream();
    load()
      .then((m) => forwardStream(outer, m.stream(model, context, options)))
      .catch((error) => {
        const msg = createLazyLoadErrorMessage(model, error);
        outer.push({ type: "error", reason: "error", error: msg });
        outer.end(msg);
      });
    return outer;
  };
}
```

两个关键性质：
- 函数同步返回空的事件流，调用方可以立刻开始 `for await` 迭代
- 加载失败也通过流内 `error` 事件表达，不 reject promise

---

## 2. 统一 Message / Content Block

### 2.1 Message

只有三种 role：

```typescript
type Message = UserMessage | AssistantMessage | ToolResultMessage;

interface UserMessage {
  role: "user";
  content: string | (TextContent | ImageContent)[];
  timestamp: number;
}

interface AssistantMessage {
  role: "assistant";
  content: (TextContent | ThinkingContent | ToolCall)[];
  api: Api;                // 记录来源 api
  provider: Provider;      // 记录来源 provider
  model: string;           // 记录来源 model id
  responseId?: string;     // 上游返回的消息 id
  usage: Usage;
  stopReason: StopReason;
  errorMessage?: string;
  timestamp: number;
}

interface ToolResultMessage<TDetails = any> {
  role: "toolResult";
  toolCallId: string;
  toolName: string;
  content: (TextContent | ImageContent)[];
  details?: TDetails;       // runtime 侧的 opaque 补充信息
  isError: boolean;
  timestamp: number;
}
```

要点：
- 没有独立的 `system` role —— system prompt 挂在 `Context.systemPrompt` 上，由 provider 按各家规范放置
- 所有 assistant 消息都带 `api / provider / model`，用于跨模型重放时判定「同源 vs 异源」
- `tool` 不是独立 role，是 `toolResult`，强调它一定是对某次 `toolCall` 的应答

### 2.2 Content Block

```typescript
interface TextContent {
  type: "text";
  text: string;
  textSignature?: string;     // 部分 provider 的消息元数据（如 OpenAI Responses 的消息 id）
}

interface ThinkingContent {
  type: "thinking";
  thinking: string;
  thinkingSignature?: string; // 多轮续推所需的不透明签名
  redacted?: boolean;         // 被安全过滤的思考：signature 里是加密 payload
}

interface ImageContent {
  type: "image";
  data: string;               // base64
  mimeType: string;
}

interface ToolCall {
  type: "toolCall";
  id: string;
  name: string;
  arguments: Record<string, any>;
  thoughtSignature?: string;  // Google-specific：思考上下文签名
}
```

设计约束：
- `thinking` 必须保存 signature，否则回灌给同一个模型会被拒绝
- `redacted: true` 时 `thinking` 字段是占位文本（`"[Reasoning redacted]"`），真实内容在 `thinkingSignature`
- signature 类字段属于「仅当 provider+model 同源时保留」，跨模型时丢掉（见 §4）

### 2.3 Context

```typescript
interface Context {
  systemPrompt?: string;
  messages: Message[];
  tools?: Tool[];
}

interface Tool<TParameters extends TSchema = TSchema> {
  name: string;
  description: string;
  parameters: TParameters;    // TypeBox schema（编译期也是 JSON Schema）
}
```

`Context` 是无状态的一次性输入：agent runtime 自己维护对话历史，每次调用把相关片段灌进去。

---

## 3. Streaming 事件统一

### 3.1 事件协议

所有 provider 输出同一份 discriminated union：

```typescript
type AssistantMessageEvent =
  | { type: "start"; partial: AssistantMessage }
  | { type: "text_start"; contentIndex: number; partial: AssistantMessage }
  | { type: "text_delta"; contentIndex: number; delta: string; partial: AssistantMessage }
  | { type: "text_end"; contentIndex: number; content: string; partial: AssistantMessage }
  | { type: "thinking_start"; contentIndex: number; partial: AssistantMessage }
  | { type: "thinking_delta"; contentIndex: number; delta: string; partial: AssistantMessage }
  | { type: "thinking_end"; contentIndex: number; content: string; partial: AssistantMessage }
  | { type: "toolcall_start"; contentIndex: number; partial: AssistantMessage }
  | { type: "toolcall_delta"; contentIndex: number; delta: string; partial: AssistantMessage }
  | { type: "toolcall_end"; contentIndex: number; toolCall: ToolCall; partial: AssistantMessage }
  | { type: "done"; reason: "stop" | "length" | "toolUse"; message: AssistantMessage }
  | { type: "error"; reason: "aborted" | "error"; error: AssistantMessage };
```

协议约束：
- `start` 必发一次
- 每个 content block 三段式：`*_start` → 若干 `*_delta` → `*_end`
- 终止事件只有 `done` 或 `error` 两种，二者都携带最终 `AssistantMessage`
- `partial` 字段每次都是最新累积快照的引用。UI 直接渲染 `partial` 即可增量更新，无需再拼 delta

### 3.2 AssistantMessageEventStream

用一个通用的 push/pull 队列包装：

```typescript
class EventStream<T, R = T> implements AsyncIterable<T> {
  private queue: T[] = [];
  private waiting: ((r: IteratorResult<T>) => void)[] = [];
  private done = false;
  private finalResultPromise: Promise<R>;

  constructor(
    private isComplete: (e: T) => boolean,
    private extractResult: (e: T) => R,
  ) { /* ... */ }

  push(event: T): void { /* 派发给 waiter 或排队 */ }
  end(result?: R): void { /* 通知所有 waiter done */ }
  async *[Symbol.asyncIterator](): AsyncIterator<T> { /* ... */ }
  result(): Promise<R> { return this.finalResultPromise; }
}

class AssistantMessageEventStream extends EventStream<AssistantMessageEvent, AssistantMessage> {
  constructor() {
    super(
      (e) => e.type === "done" || e.type === "error",
      (e) => e.type === "done" ? e.message : e.error,
    );
  }
}
```

好处：
- 调用方要 stream：`for await (const ev of stream)`
- 调用方要 final message：`await stream.result()`
- 两种消费方式共用一条底层队列，不重复订阅

### 3.3 partial 快照的累积责任

provider 实现是事件真正的产生者，必须：

1. 新建一个 `AssistantMessage output`，所有 `content` push 写进 `output.content`
2. 每次 push 事件时，把 `partial: output` 一起塞进去（引用即可，调用方若要持久化自己 clone）
3. `usage` 字段每收到 `message_start` / `message_delta` 都更新一次，并立即 `calculateCost`
4. provider 内部临时字段（如 Anthropic 的 `block.index`、streaming 累积的 `partialJson`）在对应 `*_end` 事件前清理掉，绝不持久化

```typescript
// Anthropic 的示例：流结束时清理 index 和 partialJson
} catch (error) {
  for (const block of output.content) {
    delete (block as { index?: number }).index;
    delete (block as { partialJson?: string }).partialJson;
  }
  output.stopReason = options?.signal?.aborted ? "aborted" : "error";
  output.errorMessage = error instanceof Error ? error.message : JSON.stringify(error);
  stream.push({ type: "error", reason: output.stopReason, error: output });
  stream.end();
}
```

### 3.4 错误永远走流内

provider 实现的强约束：一旦 `stream()` 返回，任何后续失败都必须用 `error` 事件上抛，不能 reject 外层 promise 或 throw。

```typescript
export const streamAnthropic: StreamFunction<"anthropic-messages", AnthropicOptions> = (model, context, options) => {
  const stream = new AssistantMessageEventStream();
  (async () => {
    const output: AssistantMessage = { /* ... */ };
    try {
      // ... 正常流处理 ...
      stream.push({ type: "done", reason: output.stopReason, message: output });
      stream.end();
    } catch (error) {
      output.stopReason = options?.signal?.aborted ? "aborted" : "error";
      output.errorMessage = error instanceof Error ? error.message : JSON.stringify(error);
      stream.push({ type: "error", reason: output.stopReason, error: output });
      stream.end();
    }
  })();
  return stream;
};
```

这让上层 agent runtime 只写一套消费逻辑：`for await (ev of stream)` 遇到 `error` 就退出。

### 3.5 Streaming JSON（tool arguments）

tool call 的 `arguments` 字段服务端是分片 JSON delta 回来的，流式阶段 UI 也想看到半成品。用三段降级解析：

```typescript
export function parseStreamingJson<T = Record<string, unknown>>(partial: string | undefined): T {
  if (!partial || partial.trim() === "") return {} as T;
  try { return JSON.parse(partial) as T; }
  catch {
    try { return (partialParse(partial) ?? {}) as T; }
    catch {
      try { return (partialParse(repairJson(partial)) ?? {}) as T; }
      catch { return {} as T; }
    }
  }
}
```

- `partial-json` 库能从不完整的 JSON 中尽量抽值
- `repairJson` 把裸控制字符和非法转义补好（LLM 常吐出字符串里带原始 `\n`、`\t`）

每来一个 `input_json_delta` 就跑一次 `parseStreamingJson`，把 `block.arguments` 刷新成最新结构。UI 据此展示「tool arguments 正在填充」。

---

## 4. Tool Use / Function Calling

### 4.1 Tool 定义格式

框架统一用 **JSON Schema**（经由 TypeBox 声明），每个 provider 自己改写成本家格式：

```typescript
// 统一：
const tool: Tool = {
  name: "read_file",
  description: "Read a file from disk.",
  parameters: Type.Object({
    path: Type.String({ description: "Absolute path." }),
  }),
};

// Anthropic:
{ name, description, input_schema: { type: "object", properties, required } }

// OpenAI:
{ type: "function", function: { name, description, parameters: jsonSchema } }

// Google:
{ functionDeclarations: [{ name, description, parameters: jsonSchema }] }
```

### 4.2 Tool call id 归一化

不同 provider 生成的 id 有完全不同的合法字符集：
- Anthropic 要求 `^[a-zA-Z0-9_-]+$`，最长 64
- OpenAI Responses 生成 400+ 字符、含 `|`
- 某些 provider 完全不返回 id（Google 旧版）

在 message 回灌前统一化，并维护原 id → 新 id 的映射表：

```typescript
function normalizeAnthropicToolCallId(id: string): string {
  return id.replace(/[^a-zA-Z0-9_-]/g, "_").slice(0, 64);
}
```

`transformMessages()`（见 §6）负责两件事：
- 第一遍：对 assistant 消息里的 `toolCall.id` 调 `normalizeToolCallId`，把旧→新记入 map
- 第二遍：对 `toolResult.toolCallId` 用同一张 map 映射，保证 pair 不断

### 4.3 Tool result 的特殊处理

多数 provider 要求 tool_result 跟在 assistant 的 tool_use 之后，且一次 assistant 回合的多个 tool_result 要合并成单条 user 消息：

```typescript
// 把连续的 toolResult 批量收进一条 user 消息（Anthropic 要求）
if (msg.role === "toolResult") {
  const toolResults: ContentBlockParam[] = [];
  toolResults.push({ type: "tool_result", tool_use_id: msg.toolCallId, content: ..., is_error: msg.isError });
  let j = i + 1;
  while (j < messages.length && messages[j].role === "toolResult") {
    toolResults.push({ ... });
    j++;
  }
  i = j - 1;
  params.push({ role: "user", content: toolResults });
}
```

### 4.4 Tool 结果孤儿处理

assistant 发出了 `toolCall`，但该轮流中断、rewrite 或用户插入了新 user 消息，导致某些 call 没有对应的 result。直接回灌会被 API 拒。做法：在最终序列化前为孤儿 call 合成空 result：

```typescript
for (const tc of pendingToolCalls) {
  if (!existingToolResultIds.has(tc.id)) {
    result.push({
      role: "toolResult",
      toolCallId: tc.id,
      toolName: tc.name,
      content: [{ type: "text", text: "No result provided" }],
      isError: true,
      timestamp: Date.now(),
    });
  }
}
```

触发点：
- 遇到下一条 assistant 消息前
- 遇到 user 消息（用户 interrupt 了 tool 流）前
- 整个序列末尾

### 4.5 Tool 参数校验

模型经常给出不完全符合 schema 的参数（类型混淆、字段缺失、枚举值错位）。提供 `validateToolArguments(tool, toolCall)`：

```typescript
export function validateToolArguments(tool: Tool, toolCall: ToolCall): any {
  const args = structuredClone(toolCall.arguments);
  Value.Convert(tool.parameters, args);  // TypeBox: 最宽松的类型转换
  // 对非 TypeBox 的 JSON Schema 做一轮 coerce（string→number、string→bool、null→default）
  const validator = getValidator(tool.parameters);
  // ...
  if (validator.Check(args)) return args;
  const errors = validator.Errors(args).map((e) => `  - ${path(e)}: ${e.message}`).join("\n");
  throw new Error(`Validation failed for tool "${toolCall.name}":\n${errors}\n\nReceived arguments:\n${JSON.stringify(toolCall.arguments, null, 2)}`);
}
```

原则：
- 尝试一次轻量 coerce，再校验
- 校验失败要给 LLM 回一条机器可读的错误（`role: toolResult, isError: true`），让它下一轮自我修正
- 绝不 silent 通过

---

## 5. 能力声明（Capabilities）

Model 字段自身就是 capability 的载体：

```typescript
interface Model<TApi> {
  reasoning: boolean;                 // 支持 thinking
  input: ("text" | "image")[];        // 支持 vision
  cost: { ... };                      // 支持 pricing 计算
  contextWindow: number;              // 支持 overflow 判断
  maxTokens: number;
  compat?: /* 按 api 分叉的微调字段 */;
}
```

除此之外，基于 `model.id` 的正则做一些细粒度能力判断，封装为函数：

```typescript
export function supportsXhigh<TApi>(model: Model<TApi>): boolean {
  return /gpt-5\.[2-5]/.test(model.id)
      || /opus-4[-.]6/.test(model.id)
      || /opus-4[-.]7/.test(model.id);
}
```

对多 provider 共存的 API（`openai-completions` 被几十家复用），用 `compat` 做精细微调：

```typescript
interface OpenAICompletionsCompat {
  supportsStore?: boolean;
  supportsDeveloperRole?: boolean;
  supportsReasoningEffort?: boolean;
  supportsUsageInStreaming?: boolean;
  maxTokensField?: "max_completion_tokens" | "max_tokens";
  requiresToolResultName?: boolean;
  requiresAssistantAfterToolResult?: boolean;
  requiresThinkingAsText?: boolean;
  thinkingFormat?: "openai" | "openrouter" | "zai" | "qwen" | "qwen-chat-template";
  cacheControlFormat?: "anthropic";
  supportsStrictMode?: boolean;
  supportsLongCacheRetention?: boolean;
  /* ... 更多 routing / pricing 相关字段 */
}
```

能力由谁声明：
- 内置 provider：写在 `models.generated.ts` 或 provider 模块的默认 compat 里
- 第三方自部署：用户在配置文件里手写 model + compat

---

## 6. 消息归一化：transformMessages

跨 model 重放时，assistant 消息来自某个 "旧" 模型（provider/api/modelId 组合），而本次请求发给 "新" 模型。三大问题：

1. **Image** 不支持 vision 的模型要把 image 块替换成文字占位符
2. **Thinking** 异源模型的 thinking block 要么丢掉、要么转为普通 text（无 signature），同源才保留
3. **Tool call id** 异源模型生成的 id 字符集可能不被新 provider 接受

统一入口：

```typescript
export function transformMessages<TApi>(
  messages: Message[],
  model: Model<TApi>,
  normalizeToolCallId?: (id: string, model: Model<TApi>, source: AssistantMessage) => string,
): Message[] {
  // 1) downgradeUnsupportedImages: 当 model.input 不含 "image" 时，
  //    把 user / toolResult 里的 image 块换成占位 text，并合并连续占位
  // 2) 遍历消息：
  //    - user 透传
  //    - assistant 按块改写：
  //        thinking (redacted)    → 同源保留，异源丢弃
  //        thinking (带 signature) → 同源保留，异源降级为 text
  //        thinking (空)           → 丢弃
  //        text                    → 同源保留 signature，异源丢 signature
  //        toolCall                → 异源时丢 thoughtSignature，并 id 归一化，记 map
  //    - toolResult 用 map 重写 toolCallId
  // 3) 给孤儿 toolCall 补合成 toolResult（见 §4.4）
  // 4) 丢弃 stopReason 为 "error" / "aborted" 的 assistant 消息（不可重放）
}
```

关键判断：

```typescript
const isSameModel =
  assistantMsg.provider === model.provider &&
  assistantMsg.api === model.api &&
  assistantMsg.model === model.id;
```

三项全等才算同源。跨 provider（哪怕同 api）也按异源处理。

---

## 7. 统一 Options

### 7.1 StreamOptions（底层）

```typescript
interface StreamOptions {
  temperature?: number;
  maxTokens?: number;
  signal?: AbortSignal;
  apiKey?: string;
  transport?: "sse" | "websocket" | "auto";
  cacheRetention?: "none" | "short" | "long";
  sessionId?: string;
  onPayload?: (payload: unknown, model: Model<Api>) => unknown | undefined | Promise<unknown | undefined>;
  onResponse?: (response: { status: number; headers: Record<string, string> }, model: Model<Api>) => void | Promise<void>;
  headers?: Record<string, string>;
  maxRetryDelayMs?: number;
  metadata?: Record<string, unknown>;
}

type ProviderStreamOptions = StreamOptions & Record<string, unknown>;
```

hook 的用途：
- `onPayload`：在发送前读或改写 provider 原生 payload。实现 logging、policy、payload 捕获
- `onResponse`：HTTP 响应头和状态码，用于追踪 rate limit / 请求 id / 计费

### 7.2 SimpleStreamOptions（高层）

调用方大部分时候不想关心 provider 具体调参，只想说「给我思考一下」：

```typescript
interface SimpleStreamOptions extends StreamOptions {
  reasoning?: "minimal" | "low" | "medium" | "high" | "xhigh";
  thinkingBudgets?: Partial<Record<ThinkingLevel, number>>;
}
```

每个 provider 的 `streamSimple` 负责把 `reasoning` 映射成自家格式：
- Anthropic 新模型 → `effort: "low"|"medium"|"high"|"xhigh"`
- Anthropic 老模型 → `thinkingBudgetTokens`
- OpenAI → `reasoning_effort`
- OpenRouter → `reasoning: { effort }`
- z.ai → `enable_thinking: boolean`

`streamSimple` 只是在上层加了一层参数翻译，核心仍走 `streamXxx(model, context, baseOptions)`。

### 7.3 Cache retention

`cacheRetention` 是一个粗粒度语义（`none` / `short` / `long`）。每个 provider 翻译为原生字段：

- Anthropic: `cache_control: { type: "ephemeral", ttl?: "1h" }`
- OpenAI Responses: `prompt_cache_retention: "24h"`
- OpenAI-compat w/ anthropic-style cache: 同 Anthropic

缓存字段的「贴」位置也要统一：系统 prompt 最后、最后一个 tool definition、最后一条 user/assistant text content。

---

## 8. Usage & Cost 统一结构

```typescript
interface Usage {
  input: number;
  output: number;
  cacheRead: number;
  cacheWrite: number;
  totalTokens: number;
  cost: {
    input: number;
    output: number;
    cacheRead: number;
    cacheWrite: number;
    total: number;
  };
}
```

归一规则：
- `totalTokens` 自己算：`input + output + cacheRead + cacheWrite`（Anthropic 不给 total；OpenAI 给的 total 含义可能不一致）
- 每次拿到 usage 更新立刻调 `calculateCost(model, usage)`，把 cost 一并算好挂在同一个对象上
- 流中途 abort 也要尽量保留已捕获的 usage（Anthropic `message_start` 就给了 input tokens）

```typescript
export function calculateCost<TApi>(model: Model<TApi>, usage: Usage): Usage["cost"] {
  usage.cost.input      = (model.cost.input      / 1_000_000) * usage.input;
  usage.cost.output     = (model.cost.output     / 1_000_000) * usage.output;
  usage.cost.cacheRead  = (model.cost.cacheRead  / 1_000_000) * usage.cacheRead;
  usage.cost.cacheWrite = (model.cost.cacheWrite / 1_000_000) * usage.cacheWrite;
  usage.cost.total = usage.cost.input + usage.cost.output + usage.cost.cacheRead + usage.cost.cacheWrite;
  return usage.cost;
}
```

---

## 9. StopReason 归一

每个 provider 有自家终止码。统一映射到五种：

```typescript
type StopReason = "stop" | "length" | "toolUse" | "error" | "aborted";
```

Anthropic 映射：

```typescript
function mapStopReason(r: string): StopReason {
  switch (r) {
    case "end_turn":       return "stop";
    case "max_tokens":     return "length";
    case "tool_use":       return "toolUse";
    case "refusal":        return "error";
    case "pause_turn":     return "stop";  // 立刻再发一次请求即可接续
    case "stop_sequence":  return "stop";
    case "sensitive":      return "error";
    default:
      throw new Error(`Unhandled stop reason: ${r}`);   // 失败比静默兜底好
  }
}
```

设计取向：遇到未知 reason 直接抛错，强制维护者显式处理。fallback 成 `"stop"` 会掩盖上游协议变化。

---

## 10. 错误归一化 / 重试 / Overflow 检测

### 10.1 分层职责

- **provider 内层**：只负责把一次 HTTP 流变成事件流。遇到错误翻成 `AssistantMessage { stopReason: "error" | "aborted", errorMessage }`，push `error` 事件
- **provider 内层**可以做轻量的 transport 级 retry（跨 endpoint failover、对 429/5xx 退避一次），但必须尊重 `options.signal` 和 `options.maxRetryDelayMs`
- **agent runtime 外层**：业务级 retry（对话重试、compaction 后重试、换模型）由上层决定

### 10.2 Retry-After 提取

服务端告知的延迟优先使用，否则退化为指数退避：

```typescript
// header
const retryAfter = headers.get("retry-after");
// body 里的文本："Please retry in 12.5s"、"retryDelay": "34s"
// 多模式 regex 兜底
```

超过 `maxRetryDelayMs`（默认 60000）就放弃 retry，把延迟值写进错误消息交给上层决策：

```typescript
if (maxDelayMs > 0 && serverDelay && serverDelay > maxDelayMs) {
  throw new Error(
    `Server requested ${Math.ceil(serverDelay/1000)}s retry delay (max: ${Math.ceil(maxDelayMs/1000)}s). ${extractErrorMessage(errorText)}`,
  );
}
```

### 10.3 Overflow 检测

context 超限是所有 agent 必须处理的场景。每个 provider 错误文案不同，集中一处匹配：

```typescript
const OVERFLOW_PATTERNS = [
  /prompt is too long/i,
  /request_too_large/i,
  /input is too long for requested model/i,
  /exceeds the context window/i,
  /input token count.*exceeds the maximum/i,
  /maximum prompt length is \d+/i,
  /reduce the length of the messages/i,
  /maximum context length is \d+ tokens/i,
  /exceeds the limit of \d+/i,
  /context[_ ]length[_ ]exceeded/i,
  /token limit exceeded/i,
  /^4(?:00|13)\s*(?:status code)?\s*\(no body\)/i,
];

const NON_OVERFLOW_PATTERNS = [
  /^(Throttling error|Service unavailable):/i,
  /rate limit/i,
  /too many requests/i,
];

export function isContextOverflow(msg: AssistantMessage, contextWindow?: number): boolean {
  if (msg.stopReason === "error" && msg.errorMessage) {
    if (NON_OVERFLOW_PATTERNS.some((p) => p.test(msg.errorMessage!))) return false;
    if (OVERFLOW_PATTERNS.some((p) => p.test(msg.errorMessage!))) return true;
  }
  // 静默 overflow（如 z.ai）：usage > context window
  if (contextWindow && msg.stopReason === "stop") {
    const input = msg.usage.input + msg.usage.cacheRead;
    if (input > contextWindow) return true;
  }
  return false;
}
```

agent runtime 调完 `stream` 拿到 final message，就用 `isContextOverflow(msg, model.contextWindow)` 决定要不要 compaction。

---

## 11. 鉴权与配置

### 11.1 env key 查找

同一 provider 可能配多个 env 名（历史兼容），OAuth token 优先于 API key：

```typescript
function getApiKeyEnvVars(provider: string): readonly string[] | undefined {
  if (provider === "anthropic")      return ["ANTHROPIC_OAUTH_TOKEN", "ANTHROPIC_API_KEY"];
  if (provider === "github-copilot") return ["COPILOT_GITHUB_TOKEN", "GH_TOKEN", "GITHUB_TOKEN"];
  return { openai: "OPENAI_API_KEY", google: "GEMINI_API_KEY", /* ... */ }[provider];
}

export function getEnvApiKey(provider: string): string | undefined {
  const envKeys = findEnvKeys(provider);
  if (envKeys?.[0]) return process.env[envKeys[0]];

  // 特殊 provider：没有显式 key 但有 ambient credentials
  if (provider === "google-vertex" && hasVertexAdcCredentials()) return "<authenticated>";
  if (provider === "amazon-bedrock" && hasAwsCredentials())      return "<authenticated>";
  return undefined;
}
```

`<authenticated>` 是一个哨兵值，告诉 provider「走 SDK 自己的 credentials chain，不要读 key」。

### 11.2 OAuth

OAuth 走独立模块（`utils/oauth/`），每个 OAuth provider 实现 `OAuthProviderInterface`：authorize URL、PKCE、token 交换、refresh、存储。Agent runtime 侧持久化 token，调用前注入 `options.apiKey`。

### 11.3 动态 import 守护

provider 实现经常依赖 Node-only 模块（`node:fs`、`@aws-sdk/...`）。在浏览器环境下，顶层 import 会炸。解决：

```typescript
// 运行时判断环境后再动态 import
if (typeof process !== "undefined" && (process.versions?.node || process.versions?.bun)) {
  dynamicImport("node:fs").then((m) => { _existsSync = m.existsSync; });
}
```

同样的方法用在 Bedrock：`register-builtins.ts` 对 Bedrock 走 `importNodeOnlyProvider`，并给出 `setBedrockProviderModule(...)` 让浏览器侧直接注入一个 stub。

---

## 12. Model Registry / Catalog

### 12.1 生成式 catalog

维护一份 `models.generated.ts`，结构：

```typescript
export const MODELS = {
  anthropic: {
    "claude-opus-4-5-20250325": { id, name, api: "anthropic-messages", provider: "anthropic", baseUrl, ... },
    "claude-sonnet-4-6-20250910": { ... },
  },
  openai: {
    "gpt-5-2": { id, name, api: "openai-responses", provider: "openai", ... },
  },
  // ...
} as const;
```

用 `as const` 让每个 model 字面量保留精确类型，`getModel(provider, modelId)` 能推断出 `Model<TApi>` 的 `TApi` 精度。

### 12.2 Registry API

```typescript
export function getModel<P extends KnownProvider, M extends keyof (typeof MODELS)[P]>(
  provider: P,
  modelId: M,
): Model<ModelApi<P, M>>;
export function getProviders(): KnownProvider[];
export function getModels<P extends KnownProvider>(provider: P): Model<...>[];
export function modelsAreEqual(a, b): boolean;   // id + provider 相等
```

### 12.3 用户自定义 model

自部署 / vLLM / 第三方网关：用户在 `settings.json` 写出完整 `Model<TApi>` 对象，由配置加载器推进 `modelRegistry`。model 的 `api` 必须匹配一个已注册的 `ApiProvider`（通常就是 `openai-completions`），compat 字段按需填充。

---

## 13. 推荐模块结构

```
llm/
  index.ts                         # 公开导出
  types.ts                         # Message / Content / Event / Model / Options / Capability
  api-registry.ts                  # registerApiProvider / getApiProvider / sourceId
  stream.ts                        # stream / complete / streamSimple / completeSimple

  models/
    registry.ts                    # modelRegistry + getModel
    catalog.ts                     # 内置 catalog（可自动生成）
    cost.ts                        # calculateCost / pricing helpers
    capabilities.ts                # supportsXhigh / supportsVision / ...

  providers/
    register-builtins.ts           # lazy import + registerApiProvider
    simple-options.ts              # buildBaseOptions / clampReasoning / adjustMaxTokensForThinking
    transform-messages.ts          # 跨 model 重放归一化
    anthropic.ts
    openai-completions.ts
    openai-responses.ts
    google.ts
    google-vertex.ts
    google-gemini-cli.ts
    amazon-bedrock.ts              # node-only，由 register-builtins 按环境 gate
    mistral.ts
    faux.ts                        # 测试 / 本地 mock

  utils/
    event-stream.ts                # EventStream / AssistantMessageEventStream
    json-parse.ts                  # parseStreamingJson / repairJson
    validation.ts                  # validateToolCall / validateToolArguments
    overflow.ts                    # isContextOverflow
    sanitize-unicode.ts            # surrogate / BOM cleanup
    headers.ts                     # header 合并 / 转 Record
    typebox-helpers.ts             # Tool schema 构造糖

  auth/
    env-api-keys.ts                # env 查找 + <authenticated> 哨兵
    oauth/                         # PKCE / provider 特化
      types.ts
      anthropic.ts
      github-copilot.ts
      ...
```

agent runtime 只需要：
- `import { stream, completeSimple, isContextOverflow, validateToolCall } from "llm"`
- `import { getModel } from "llm"`

---

## 14. 开发流程：接入一个新 provider

1. 若协议是 OpenAI Completions 兼容：不写新 provider，改 `openai-completions.ts` 的 auto-detect，或在 model 配置里写 `compat` 覆盖项
2. 若协议是独立的：
   1. 新建 `providers/<name>.ts`
   2. 实现 `streamXxx(model, context, options): AssistantMessageEventStream`
   3. 实现 `streamSimpleXxx(model, context, simpleOptions)`：调 `buildBaseOptions` 把通用参数铺齐，翻译 `reasoning` 到本家格式
   4. 在 `register-builtins.ts` 加 lazy 载入 + `registerApiProvider`
   5. 在 `catalog` 添加 model 条目
   6. 加到 `env-api-keys` 的查找表
3. 写 unit test：`faux.ts` 风格的 mock 流，覆盖 text / thinking / toolCall / error / abort 五条路径
4. 写一个端到端最小 smoke（可选 `test.sh` 风格）：跑一次真实请求，确认事件序列
5. 在 `overflow.ts` 加一条 regex pattern（主动触发一次超限请求，抓 error message）

---

## 15. 常见坑位 checklist

- [ ] `stream()` 同步返回，异步错误必须走 `error` 事件而非 reject
- [ ] `AssistantMessage.partial` 是引用，调用方若要持久化需自行 clone
- [ ] Anthropic tool call id 限制 `^[a-zA-Z0-9_-]{1,64}$`，跨 provider 回灌必须归一化并维护映射
- [ ] Tool result 必须紧跟对应 tool call；连续 tool result 合并为单条 user 消息
- [ ] assistant 发出 tool call 但未收到 result → 合成空 result，否则 API 报错
- [ ] stopReason 为 `error` / `aborted` 的 assistant 消息不可重放，必须在 `transformMessages` 里丢弃
- [ ] thinking block 的 `signature` 必须和 thinking 配对保留，否则同源重放被拒
- [ ] 异源模型的 thinking 要么丢弃要么降级为 text，绝不能带着 signature 发给别家
- [ ] redacted thinking 只在同源重放才保留；`thinkingSignature` 里是加密 payload
- [ ] 不支持 vision 的模型必须把 image 块替换为占位 text，多个连续占位要合并
- [ ] 流结束前清理 provider 内部临时字段（`block.index`、`partialJson` 等），不持久化
- [ ] `usage.totalTokens` 自己算，不要相信上游
- [ ] `message_start` 的 input tokens 立即捕获，方便 abort 后也能报 usage
- [ ] Retry-After 既可能在 header 也可能在 body 文案里，多模式抽取
- [ ] `maxRetryDelayMs` 被服务端超出时要让业务层可见，不要静默 sleep 10 分钟
- [ ] Overflow 检测：文本模式 + silent overflow (`usage.input > contextWindow`) 双路
- [ ] 统一 stopReason 映射表里遇到未知值直接抛错，不要 fallback 成 `"stop"`
- [ ] `options.signal` 要贯穿到 HTTP fetch 和所有 sleep 上，否则 abort 生效不及时
- [ ] 浏览器环境下 Node-only provider 要 gate 掉，`register-builtins` 里按环境决定懒加载路径
- [ ] OAuth token 在 env 查找里优先于 API key（Anthropic `ANTHROPIC_OAUTH_TOKEN` 优先）
- [ ] `<authenticated>` 哨兵值告知 provider 走 SDK 自带 credentials chain，不读 key
- [ ] streaming 阶段的 tool arguments 用 `parseStreamingJson` 三段降级，UI 才能看到半成品
- [ ] 用 `sanitizeSurrogates` 清掉代理字符，否则某些 provider 直接 400
- [ ] Tool schema 传给各 provider 前按本家字段名改写（`input_schema` / `parameters` / `functionDeclarations`），不要直接灌通用 schema
- [ ] 同一条 assistant 消息里可能同时有 thinking + text + toolCall，provider 序列化顺序要保持原顺序

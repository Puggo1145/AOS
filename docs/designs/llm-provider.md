# LLM 接入层设计

## 目标

为 AOS sidecar 提供唯一一条 LLM 调用路径，让 agent loop 只看到：

```ts
stream(model, context, options): AssistantMessageEventStream
```

所有 provider / api 差异收敛在 `sidecar/src/llm/` 子目录内，agent loop 不感知任何具体协议。本轮一次性落地：

- 一个 ApiProvider：`openai-responses`
- 一个 OAuth provider：`chatgpt-plan`（ChatGPT 订阅 PKCE flow）
- 一份 Model catalog（首发 `gpt-5-2`）
- 完整的 `transformMessages` / `isContextOverflow` / 事件流统一基础设施

参见 `docs/guide/llm-providers-guide.md` §0–§13 作为通用参考。本文是 AOS 自身的具体落地契约。

## 非目标

- 不做 tool use（无 tool 注册、本轮 agent loop 不调任何工具）
- 不做 thinking content（即便 `gpt-5-2` 支持 reasoning，本轮事件流只消费 text_*）
- 不做 vision input（用户输入仅文本）
- 不做多 provider 接入（Anthropic / Google / OpenRouter / vLLM / Bedrock 全部不入本轮）
- 不做 compaction（overflow 直接 `ui.error`）
- 不做多 turn history（每个 `agent.submit` = 一次 0 history 的 single-shot）
- 不做 prompt caching 字段管理（`cacheRetention` 字段保留但本轮不传）

## 架构总览

```
┌──────────────────────────────────────────────────────────────┐
│  Bun Sidecar                                                  │
│                                                                │
│  ┌──────────────┐   submit/cancel  ┌───────────────────────┐  │
│  │ rpc/         │ ───────────────▶ │ agent/loop.ts         │  │
│  │ dispatcher   │                  │   - 读 model from      │  │
│  └──────┬───────┘                  │     getModel()         │  │
│         │ ui.token / ui.status /   │   - 构造 Context       │  │
│         │ ui.error notifications   │   - for await events   │  │
│         │◀─────────────────────────┤   - 投影到 ui.*        │  │
│         │                          └─────────┬─────────────┘  │
│                                              │ stream()       │
│                                              ▼                 │
│                                  ┌───────────────────────────┐ │
│                                  │ llm/index.ts → stream     │ │
│                                  │   getApiProvider("openai- │ │
│                                  │   responses").stream()    │ │
│                                  └─────────┬─────────────────┘ │
│                                            │                   │
│                                            ▼                   │
│                          ┌─────────────────────────────────┐  │
│                          │ providers/openai-responses.ts   │  │
│                          │   - SSE fetch                   │  │
│                          │   - response.* → events         │  │
│                          │   - tool call id normalize §4   │  │
│                          │   - usage / cost §8             │  │
│                          │   - stop reason §9              │  │
│                          │   - overflow detect §10         │  │
│                          └─────────┬───────────────────────┘  │
│                                    │ apiKey lookup            │
│                                    ▼                          │
│                          ┌─────────────────────────────────┐  │
│                          │ auth/env-api-keys.ts            │  │
│                          │  getEnvApiKey("chatgpt-plan")   │  │
│                          │  → "<authenticated>" sentinel   │  │
│                          └─────────┬───────────────────────┘  │
│                                    │                          │
│                                    ▼                          │
│                          ┌─────────────────────────────────┐  │
│                          │ auth/oauth/chatgpt-plan.ts      │  │
│                          │  storage: ~/.aos/auth/          │  │
│                          │           chatgpt.json (0600)   │  │
│                          │  - PKCE login (CLI only)        │  │
│                          │  - read at runtime              │  │
│                          │  - refresh < 60s to expiry      │  │
│                          └─────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
```

参见 `docs/guide/llm-providers-guide.md` §0 的通用架构图。

## 两层抽象（Provider × Api）

完全采用 `docs/guide/llm-providers-guide.md` §1.1 的两层切分。AOS 本轮落地的具体组合：

| 维度 | 值 |
|---|---|
| `api` | `"openai-responses"` |
| `provider` | `"chatgpt-plan"` |
| baseUrl | `https://chatgpt.com/backend-api/codex`（待 OAuth 端点最终确认时按真实 endpoint 修订；本设计的边界是「baseUrl 是 model 字段，可在 catalog 与 OAuth provider 间统一」） |
| 鉴权 | OAuth PKCE，token 持久化到 `~/.aos/auth/chatgpt.json` |

`Model<TApi>.api` 把两者串起来；`stream()` 只看 `model.api` 来路由 ApiProvider。Provider 身份只参与鉴权与 baseUrl 决策。

## 统一 Message / Content / Event

完全采用 `docs/guide/llm-providers-guide.md` §2 的 Message / Content 与 §3 的 Event 协议，**字段名与 discriminated union variants 不变**。

AOS 本轮的简化只发生在「实际产生 / 消费哪些 variant」上，不删任何类型字段：

| 类型 | 本轮使用情况 |
|---|---|
| `UserMessage` | 仅一条，content 为 `string`（无 image） |
| `AssistantMessage` | provider 输出；本轮无 `thinking` / `toolCall` content blocks 实际产生 |
| `ToolResultMessage` | 类型保留；本轮 agent loop 不会构造或消费 |
| `TextContent` | ✓ |
| `ThinkingContent` | 类型保留；本轮不产生（reasoning effort 设 `minimal`，且事件流忽略 thinking_*） |
| `ImageContent` | 类型保留；本轮不产生 |
| `ToolCall` | 类型保留；本轮不产生 |
| Events `text_start` / `text_delta` / `text_end` | ✓ 主路径 |
| Events `thinking_*` / `toolcall_*` | 类型保留，provider 实现按 §3 完整发出（如果上游有），agent loop 简单忽略 |
| Events `start` / `done` / `error` | ✓ |

`AssistantMessage.partial` 引用语义见 §3.3：agent loop 仅读 `text_delta.delta`，不依赖 `partial` 累积。

## 首发实现 — `openai-responses` ApiProvider

`sidecar/src/llm/providers/openai-responses.ts` 实现 `StreamFunction<"openai-responses", OpenAIResponsesOptions>`。职责：

| 项 | 行为 | 引用 |
|---|---|---|
| 事件流统一 | 把 OpenAI Responses 的 `response.created` / `response.output_text.delta` / `response.output_text.done` / `response.completed` / `response.failed` 翻译成统一 event union | guide §3 |
| 起手立即返回空 stream | 同步返回 `AssistantMessageEventStream`，错误走 `error` 事件，不 reject | guide §3.4 |
| Transport | SSE via `fetch` + `eventsource-parser`；`AbortSignal` 贯穿 fetch 与所有读循环 | guide §15 |
| Tool call id 归一化 | 实现 §4.2 的 `normalizeOpenAIResponsesToolCallId`（`OpenAI Responses` 的原 id 包含 `\|` / 长度超 64，需归一）；本轮虽不产生 toolCall，归一函数仍实现并被 `transformMessages` 调用 | guide §4.2 |
| Simple options reasoning | 实现 `streamSimpleOpenAIResponses`，把 `SimpleStreamOptions.reasoning` 映射到 `reasoning.effort`（`minimal` / `low` / `medium` / `high` / `xhigh`） | guide §7.2 |
| Usage / cost | 从 `response.usage` 抽 input/output/cache_read/cache_write，立即 `calculateCost(model, usage)` | guide §8 |
| StopReason | OpenAI Responses 的 `incomplete_details.reason = "max_output_tokens"` → `"length"`；`response.completed` → `"stop"`；`response.failed` → `"error"`；遇到未知 reason 抛错（不 fallback） | guide §9 |
| Overflow 检测 | `error` 事件文案匹配 `OVERFLOW_PATTERNS` + silent overflow（`usage.input + cacheRead > contextWindow`） | guide §10 |
| 临时字段清理 | 流结束前清除 provider 内累积的 `partialJson` / `block.index` 等 | guide §3.3 |
| 错误永远走流内 | `try/catch` 包整个 async 主体；abort 时设 `stopReason: "aborted"` | guide §3.4 |

API key 注入：

```ts
const apiKey = options?.apiKey ?? getEnvApiKey("chatgpt-plan");
if (apiKey === "<authenticated>") {
  // 从 chatgpt.json 读 accessToken；过期则 refresh
  const token = await readChatGPTToken();      // 见下文鉴权小节
  headers["Authorization"] = `Bearer ${token.accessToken}`;
} else if (typeof apiKey === "string") {
  headers["Authorization"] = `Bearer ${apiKey}`;
} else {
  throw new Error("ChatGPT 订阅未授权");        // 由外层 catch 转 error 事件
}
```

## 首发实现 — `chatgpt-plan` OAuth provider

`sidecar/src/llm/auth/oauth/chatgpt-plan.ts` 实现 `OAuthProviderInterface`（参见 `docs/guide/llm-providers-guide.md` §11.2）。

### PKCE flow（CLI 子命令独立可执行）

```
1. 生成 codeVerifier (random 64 bytes base64url) + codeChallenge (S256)
2. 启动 loopback 服务：http.createServer，bind 127.0.0.1:0（系统分配 port）
   redirect_uri = "http://127.0.0.1:<port>/callback"
3. 打印 / 自动打开 authorize URL：
     https://auth.openai.com/oauth/authorize
       ?response_type=code
       &client_id=<aos client id>
       &redirect_uri=<encoded>
       &scope=<scope>
       &state=<random>
       &code_challenge=<S256>
       &code_challenge_method=S256
4. 浏览器回跳 /callback?code=...&state=...
   loopback handler 校验 state，写出短 HTML "Login successful, you can close this tab"
5. POST https://auth.openai.com/oauth/token
     grant_type=authorization_code
     code=<code>
     redirect_uri=<same>
     client_id=<aos client id>
     code_verifier=<verifier>
   → { access_token, refresh_token, expires_in, account_id }
6. 写入 ~/.aos/auth/chatgpt.json，文件模式 0600
7. 关闭 loopback server，进程退出 0
```

> 注：上述 endpoint / client_id / scope 待 OAuth 端点最终确认时填实际值；架构与字段契约稳定，参数级细节属于 §"风险" 项。

### Token 持久化

`~/.aos/auth/chatgpt.json`：

```jsonc
{
  "accessToken": "...",        // string
  "refreshToken": "...",       // string
  "expiresAt": 1714900000000,  // number, epoch ms
  "accountId": "..."           // string，OAuth 返回，identifies ChatGPT account
}
```

文件权限：`fs.chmod(0o600)`，目录 `~/.aos/auth/` 创建时 `0o700`。

### Refresh 策略

`auth/oauth/chatgpt-plan.ts` 暴露 `readChatGPTToken(): Promise<TokenRecord>`：

1. 读 `chatgpt.json`，不存在 → 抛 `Error("ChatGPT 订阅未授权")`
2. 若 `expiresAt - now < 60_000`（60s 余量）→ 调 token endpoint refresh
3. refresh 成功 → 原子写回（写到 `chatgpt.json.tmp` 再 rename）
4. refresh 失败 → 抛 `Error("ChatGPT 订阅授权已失效，请重新登录")`

并发保护：用 in-process `Promise<TokenRecord>` cache，同时多个 stream 调用只触发一次 refresh。

### CLI 子命令

```
bun run sidecar/src/auth/oauth/chatgpt-plan.ts login
```

- 完整跑 PKCE flow
- 不通过 RPC、不依赖 sidecar 主进程
- 用户首次使用 AOS 前手动跑一次
- 多次执行会覆盖现有 token 文件

**修订（onboarding 设计）**：sidecar 运行时**允许**发起 OAuth login，承接来自 Shell 的 `provider.startLogin` 请求。原约束（"sidecar 运行时永不发起 login"，"避免与 stdio RPC 冲突"）不成立——loopback HTTP 是独立 socket，与 stdio NDJSON 物理隔离；浏览器由 Shell 通过 `NSWorkspace.open` 打开，sidecar 进程内只 `listen 127.0.0.1:0` 接 callback。

CLI login 入口（`bun run sidecar/src/auth/cli.ts login`）仍保留，作为开发期 / 排障路径。

详细 runtime 协议见 `docs/designs/rpc-protocol.md` §"provider.* namespace" 与 `docs/plans/onboarding.md`。

## Token → Provider 桥接

参见 `docs/guide/llm-providers-guide.md` §11.1 的 `<authenticated>` 哨兵机制。

`auth/env-api-keys.ts`：

```ts
getEnvApiKey(provider: string): string | undefined {
  if (provider === "chatgpt-plan") {
    return existsSync(chatgptTokenPath()) ? "<authenticated>" : undefined;
  }
  // 其他 provider：读 env，本轮不触发
}
```

`openai-responses.ts` 在 `apiKey === "<authenticated>"` 时调 `readChatGPTToken()` 拿 bearer token。其它 provider 的 ambient credentials 路径（vertex / bedrock）本轮不实现。

错误路径：

| 场景 | 行为 |
|---|---|
| `chatgpt.json` 不存在 | `provider.status` 直接返回 `unauthenticated`，Shell opened 态展示 onboard 面板；agent loop 不会被触发（Shell 在 unauthenticated 状态禁止 `agent.submit`） |
| token 存在但 refresh 失败 | runtime `readChatGPTToken()` 把失效文件 `rename` 到 `chatgpt.json.invalid` 并抛 `AuthInvalidatedError`；agent loop 同时发 `ui.error { code: -32003 }` 与 `provider.statusChanged { state: unauthenticated, reason: authInvalidated }`，Shell 切回 onboard |
| stream 中途 401 | provider 流内 catch → `error` 事件携带 `errorReason: "authInvalidated"` → agent loop 转 `ui.error { code: -32003 }` + `provider.statusChanged`；用户需通过 onboard 重新登录 |

ErrPermissionDenied 码段定义参见 `docs/designs/rpc-protocol.md` §"错误模型"。

## Model catalog

`sidecar/src/llm/models/catalog.ts` 至少注册一条：

```ts
{
  "chatgpt-plan": {
    "gpt-5-2": {
      id: "gpt-5-2",
      name: "GPT-5.2 (ChatGPT Plan)",
      api: "openai-responses",
      provider: "chatgpt-plan",
      baseUrl: "https://chatgpt.com/backend-api/codex",
      reasoning: true,
      input: ["text", "image"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 400_000,
      maxTokens: 16_384,
      compat: { /* openai-responses-specific compat fields if any */ },
    },
  },
}
```

字段说明：

| 字段 | 取值理由 |
|---|---|
| `id: "gpt-5-2"` | ChatGPT 订阅当前可用旗舰模型 id；当真实可用 id 变化时一行替换，不动其它代码 |
| `cost: 0` | 订阅制下 per-token 成本不直接计算；`calculateCost` 仍跑通，结果为 0，使后续切到 metered API 时无需修改 calling site |
| `input: ["text", "image"]` | 模型本身能力声明；本轮不发 image，但 `transformMessages` 对未来 image 输入零改动 |
| `reasoning: true` | 用于 `supportsXhigh` 判定与 simple options reasoning 翻译 |
| `contextWindow: 400_000` | 用于 silent overflow 判定（参见 guide §10.3） |

`models/registry.ts` 对外暴露 `getModel(provider, modelId)`，agent loop 启动时调一次拿到 `Model<"openai-responses">`。

## Capabilities

`models/capabilities.ts` 实现 `docs/guide/llm-providers-guide.md` §5 的两项判定：

```ts
supportsXhigh(model): boolean   // 用于 simple options reasoning 上限
supportsVision(model): boolean  // 等价于 model.input.includes("image")
```

本轮仅 `streamSimpleOpenAIResponses` 内部消费 `supportsXhigh`；vision 判定保留给未来 image input。

## transformMessages

完全实现 `docs/guide/llm-providers-guide.md` §6。即便本轮 `Context.messages` 始终是 `[UserMessage]`（0/1 turn history），仍：

- agent loop 在调 `stream` 前调用 `transformMessages(messages, model, normalizeOpenAIResponsesToolCallId)`
- 实现内部完整覆盖 image downgrade / thinking 同源判定 / toolCall id 归一 / toolResult id 重映射 / 孤儿 toolCall 合成 / `error` & `aborted` assistant 消息丢弃

理由：避免后续接入 thinking / tool use / 多 turn 历史时再回头补，本轮一次写完更便宜。

## 错误归一

| 工具 | 落地 |
|---|---|
| `isContextOverflow` | `utils/overflow.ts`，模式集见 guide §10.3；agent loop 在 `final = await stream.result()` 后调 `isContextOverflow(final, model.contextWindow)`，**本轮 overflow 直接转 `ui.error { code: -32300+ (TBD agent 段), message: "Context too long" }`，不做 compaction** |
| `extractRetryAfter` | `providers/openai-responses.ts` 内部使用，仅用于 transport 级单次 retry；`maxRetryDelayMs` 默认 60000，超出即抛 |
| stop reason 未知值 | `providers/openai-responses.ts` 的 `mapStopReason` 抛错，不 fallback |

agent loop 错误路径（统一）：

```
stream.result() →
  if stopReason === "error" / "aborted" →
    if isContextOverflow → ui.error overflow
    else                 → ui.error { code, message: errorMessage }
  else if stopReason === "stop" →
    ui.status { status: "done" }
```

## 包边界 / 模块结构

完全采用 `docs/guide/llm-providers-guide.md` §13 的目录组织，AOS 实例化为：

```
sidecar/src/llm/
  index.ts                         # 仅 re-export：stream / streamSimple / getModel
                                   #               isContextOverflow / validateToolCall
                                   #               types
  types.ts                         # Message / Content / Event / Model / Options / Capability
  api-registry.ts                  # registerApiProvider / getApiProvider / sourceId
  stream.ts                        # stream / streamSimple

  models/
    registry.ts                    # modelRegistry + getModel
    catalog.ts                     # gpt-5-2 + chatgpt-plan
    cost.ts                        # calculateCost
    capabilities.ts                # supportsXhigh / supportsVision

  providers/
    register-builtins.ts           # lazy import + registerApiProvider("openai-responses")
    simple-options.ts              # buildBaseOptions / clampReasoning
    transform-messages.ts          # 完整 §6 实现
    openai-responses.ts            # 唯一 ApiProvider 实现

  utils/
    event-stream.ts                # EventStream / AssistantMessageEventStream
    json-parse.ts                  # parseStreamingJson + repair
    validation.ts                  # validateToolCall / validateToolArguments
    overflow.ts                    # isContextOverflow + 文案 patterns
    sanitize-unicode.ts
    headers.ts

  auth/
    env-api-keys.ts                # getEnvApiKey + chatgpt-plan 哨兵
    oauth/
      types.ts                     # OAuthProviderInterface
      chatgpt-plan.ts              # PKCE + storage + refresh + login CLI
      storage.ts                   # ~/.aos/auth/chatgpt.json 读写
```

agent loop 的 import 边界（**强契约**）：

```ts
// 唯一允许的 imports：
import { stream, getModel, isContextOverflow, validateToolCall } from "./llm";
import type { Model, Context, AssistantMessage, AssistantMessageEvent } from "./llm";
```

agent loop **禁止** 直接 import：
- `./llm/providers/*`（包括 `openai-responses`）
- `./llm/auth/*`
- `./llm/models/catalog`
- `./llm/utils/*`

## 数据流 / 事件流图

```
agent.submit(turnId, prompt, citedContext)
        │
        ▼
┌────────────────────────────────────────────────────────────┐
│ agent/loop.ts                                              │
│                                                            │
│   const model = getModel("chatgpt-plan", "gpt-5-2")        │
│   const ctx: Context = {                                   │
│     systemPrompt: buildSystemPrompt(citedContext),         │
│     messages: [{ role: "user", content: prompt, ... }],    │
│     tools: undefined,                                      │
│   }                                                         │
│                                                            │
│   const transformed = transformMessages(ctx.messages,      │
│       model, normalizeOpenAIResponsesToolCallId)           │
│                                                            │
│   const evStream = stream(model, {                         │
│       ...ctx, messages: transformed                        │
│   }, { signal: registry.get(turnId).signal })              │
│                                                            │
│   ui.status { turnId, status: "thinking" }                 │
│                                                            │
│   for await (const ev of evStream) {                       │
│     switch (ev.type) {                                     │
│       case "text_delta":                                   │
│         ui.token { turnId, delta: ev.delta };              │
│         break;                                             │
│       case "thinking_*": case "toolcall_*":                │
│         /* ignored this round */                           │
│         break;                                              │
│       case "error":                                        │
│         ui.error { turnId, code, message }; return;        │
│     }                                                      │
│   }                                                         │
│                                                            │
│   const final = await evStream.result()                    │
│   if (isContextOverflow(final, model.contextWindow)) {     │
│     ui.error { turnId, code: -32301, message: "Context    │
│       too long" }                                           │
│   } else {                                                  │
│     ui.status { turnId, status: "done" }                   │
│   }                                                         │
└────────────────────────────────────────────────────────────┘
```

`registry: Map<turnId, AbortController>` 在 `agent.cancel` 时调 `controller.abort()`，`options.signal` 把信号一路串到 fetch + sleep。

## 风险

| 风险 | 影响 | 缓解 / 备注 |
|---|---|---|
| ChatGPT plan OAuth endpoint / scope / client_id 尚未对外正式公开 | PKCE 调用参数细节当前是「按 OpenAI Codex CLI 等开源参考」拼接，需在真实端点确认后修订 | 该设计的字段契约（PKCE、loopback、token storage、refresh 60s 余量、CLI 子命令）保持稳定；端点参数级修改不影响其他模块 |
| Bun 的 SSE / EventSource 语义 | `eventsource-parser` 在 Bun fetch 上的兼容性需要单测覆盖 | `test/llm-event-stream.test.ts` 用 mock SSE 流验证 parse；首次接通真实端点跑 smoke |
| Stream 中途 401（token 过期且 refresh 失败 / 撤销） | 流被服务端切断，事件未能完整发出 | provider catch → `error` 事件 → agent loop 转 `ui.error { code: -32003 }`；下一次 submit 前用户必须重跑 login |
| Bun 版本对 `fetch` body streaming 与 AbortSignal 的支持 | 异常 abort 可能延迟到下一个 chunk | abort handler 在 `stream()` 顶层主动 push `error { reason: "aborted" }` |
| OAuth refresh token 撤销 / rotate | 老 refreshToken 失效 → refresh 失败 | refresh 失败时直接抛 "请重新登录"，不做静默 retry |
| `~/.aos/auth/chatgpt.json` 同时被多个 sidecar 实例读写 | rare 但存在 | refresh 用 atomic rename 写出；多实例并发竞争属于已知小窗口，下一次读会拿最新 |
| OpenAI Responses 协议未来字段变更 | 事件类型新增导致未知 variant | provider 内部对未识别的 SSE event 仅记 stderr log，不抛错；新 variant 等显式实现 |

## 不做的事

- 不做 tool use（无 tool 注册、`Context.tools` 始终 undefined；`validateToolCall` / `validateToolArguments` 实现但本轮无 caller）
- 不做 thinking content 渲染（事件流忽略 thinking_*）
- 不做 vision input（`Context.messages` 仅 text）
- 不做多 provider 接入（Anthropic / Google / OpenRouter / vLLM / Bedrock / Mistral / faux）
- 不做 compaction（overflow 直接 `ui.error`）
- 不做多 turn history（每个 `agent.submit` = 一次 0 history single-shot，sidecar 不持久化对话）
- 不做 prompt caching（`cacheRetention` 字段保留但本轮不传）
- 不做 model 用户自定义（catalog 写死 `gpt-5-2`，无 settings UI / 配置文件加载）
- 不做对 `<authenticated>` 哨兵以外的 ambient credentials chain（vertex ADC / aws creds 等）
- 不做 sidecar 内置 login UI（login 走 CLI 子命令，sidecar 主进程只读 token）
- 不做 Bedrock 风格按 Node-only gate 的环境分支（sidecar 单一 Bun 运行时）

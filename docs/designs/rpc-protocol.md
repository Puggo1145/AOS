# Shell ↔ Bun RPC 协议设计

## 目标

定义 AOS Shell (Swift) 和 Bun Sidecar (TS) 之间的**唯一通信通道**。承载：
- Shell → Bun：用户提交的 prompt（含用户显式引用的 context 子集）、设置变更
- Bun → Shell：agent 发起的 Computer Use 工具调用、流式 agent 输出、状态更新

## 非目标

- 不承载外部 agent 接入
- 不做跨进程共享状态
- 不做 binary 协议（gRPC / protobuf / Cap'n Proto）
- 不做 request batching / 中间件链 / 订阅 pub-sub

## 协议选型（已锁定）

| 维度 | 决策 | 理由 |
|---|---|---|
| 协议 | JSON-RPC 2.0 | 规范简单、双向对称、成熟 |
| 传输 | stdio，UTF-8 newline-delimited JSON | Shell 作为 parent spawn Bun，stdin/stdout 天然双工 |
| Framing | 每行一个 JSON 对象（`\n` 分隔） | 不做 `Content-Length` header，stdio 场景够用 |
| 编码实现 | 两端各自手写 codec | 不引第三方库；Swift / TS 各 <200 行 |
| 日志通道 | Bun stderr | Shell 接收 stderr 转 AOS 日志系统，与 RPC 通道物理隔离 |

## 进程 topology

```
┌──────────────────────────────┐
│  AOS Shell (Swift, parent)   │
│  ┌────────────────────────┐  │
│  │  RPC Dispatcher        │  │──── stdin/stdout ────┐
│  ├────────────────────────┤  │                       │
│  │  AOSOSSenseKit         │  │    stderr (logs)      │
│  │  AOSComputerUseKit     │  │   ◄───────────────┐   │
│  └────────────────────────┘  │                   │   │
└──────────────┬───────────────┘                   │   │
               │ spawns                            │   │
               ▼                                   │   │
┌──────────────────────────────┐                  │   │
│  Bun Sidecar (TS, child)     │──────────────────┘   │
│  - Agent loop                │◄──────────────────────┘
│  - Tool registry             │
└──────────────────────────────┘
```

Shell 持有 Bun 子进程生命周期。Bun 异常退出 Shell 负责 respawn，带指数退避。

## 消息模型

完全遵循 JSON-RPC 2.0。

```jsonc
// Request
{ "jsonrpc": "2.0", "id": <num|string>, "method": <string>, "params": <object> }
// Response
{ "jsonrpc": "2.0", "id": <num|string>, "result": <any> }
{ "jsonrpc": "2.0", "id": <num|string>, "error": { "code": <int>, "message": <string>, "data": <any> } }
// Notification (no id, no response)
{ "jsonrpc": "2.0", "method": <string>, "params": <object> }
```

`params` 必须是 object（不用 positional array），方便前向兼容加字段。

## Namespace 规则

Method 名用点号分隔：`<namespace>.<method>`。每个 namespace 有**固定方向**，违反方向的调用对端返回 `MethodNotFound`。

| Namespace | 方向 | 用途 |
|---|---|---|
| `rpc.*` | 双向 | 协议本身（握手、ping） |
| `agent.*` | Shell → Bun | Agent turn 控制（含引用 context 传递）+ 整段会话重置 |
| `conversation.*` | Bun → Shell | Sidecar 拥有的 Conversation 状态向 Shell 镜像 |
| `config.*` | Shell → Bun | 全局用户配置（已选模型、effort、catalog snapshot） |
| `settings.*` | Shell → Bun | 配置变更通知（注：当前轮被 `config.*` 取代，预留扩展） |
| `computerUse.*` | Bun → Shell | Agent 发起的 app 操作 |
| `ui.*` | Bun → Shell | Agent 流式输出、状态推送 |
| `provider.*` | 双向 | LLM provider 状态查询、OAuth login 控制（详见下文方向子表） |

`provider.*` 的 namespace-level 方向是 `both`，因为 request 与 notification 各自有不同方向。Method 级方向：

| Method | 方向 | 类型 |
|---|---|---|
| `provider.status` | Shell → Bun | request |
| `provider.startLogin` | Shell → Bun | request |
| `provider.cancelLogin` | Shell → Bun | request |
| `provider.loginStatus` | Bun → Shell | notification |
| `provider.statusChanged` | Bun → Shell | notification |

## 方法清单

### `rpc.*`（双向）

| Method | 类型 | 说明 |
|---|---|---|
| `rpc.hello` | Request | 启动握手，协商协议版本 |
| `rpc.ping` | Request | 健康检查 |

`rpc.hello` 是 Bun 启动后发给 Shell 的**第一条消息**。未握手前 Shell 拒绝处理任何业务 method。

```ts
// Request
{ protocolVersion: "1.0.0", clientInfo: { name: "aos-sidecar", version: "..." } }
// Result
{ protocolVersion: "1.0.0", serverInfo: { name: "aos-shell", version: "..." } }
```

大版本不匹配 → Shell 回 `ProtocolVersionMismatch` 错误并终止 Bun。

### `agent.*`（Shell → Bun）

| Method | 类型 | Params | Result |
|---|---|---|---|
| `agent.submit` | Request | `{ turnId, prompt, citedContext? }` | `{ accepted: bool }` |
| `agent.cancel` | Request | `{ turnId }` | `{ cancelled: bool }` |
| `agent.reset` | Request | `{}` | `{ ok: bool }` |

- `turnId`：Shell 生成的 UUID，用于标识本轮 agent 对话。流式 `ui.token` 和 `ui.status` 都带这个 id 回推
- `citedContext`：用户从 Notch UI 的 chip 列表中显式勾选的 OS Sense context 子集，**wire-only schema**，与 OS Sense 进程内的 `SenseContext` live model 解耦（live model 含 `NSImage` / `CGImage` 等不可序列化类型）。Shell 在编码时把 live model 投影到 `CitedContext`：

  ```ts
  type CitedContext = {
    app?:      { bundleId: string, name: string, pid: number, iconPNG?: string }  // base64 PNG
    window?:   { title: string, windowId?: number }   // CGWindowID；degraded 模式（无 AX 权限）下字段 omitted，不序列化为 null
    behaviors?: BehaviorEnvelope[]      // { kind, citationKey, displaySummary, payload }
    visual?:   CitedVisual
    clipboard?: CitedClipboard
  }
  type CitedVisual = {
    frame: string                       // base64 PNG，≤ 400KB
    frameSize: { width: number, height: number }
    capturedAt: string                  // ISO-8601
  }
  type CitedClipboard =
    | { kind: "text", content: string }
    | { kind: "filePaths", paths: string[] }
    | { kind: "image", metadata: { width: number, height: number, type: string } }
  ```

  - `BehaviorEnvelope.payload` 是 opaque JSON，由 producer（GeneralProbe 或某个 adapter）决定 schema。Bun 透传，不解码
  - `CitedContext` 与 `BehaviorEnvelope` 是 RPC 层的唯一边界类型，Swift / TS 各自维护对应 Codable / TS 类型并由 fixture conformance test 守住
  - **`CitedContext.window.windowId` 是 hint，不是 long-lived handle**：可以直接喂给 `computerUse.*` 作为首选 windowId，但窗口重建 / title 更新 / Space 切换后可能 stale。Bun 收到 `ErrWindowMismatch` / `ErrWindowOffSpace` / `ErrStateStale` 时应当回头调 `computerUse.listWindows({pid})` 重新选窗（必要时让 LLM 决策），不要直接报错给用户
- Shell 本地保留完整 `SenseContext`，**未被勾选的项永不传到 Bun**；live model 不直接参与序列化
- `agent.submit` 立刻返回 `{ accepted: true }` 作为 ack，实际输出走 notifications
- `agent.cancel` 返回 `{ cancelled: boolean }`（已结束的 turn 返 false）
- `agent.reset` 清空 sidecar 持有的整段 Conversation：
  - 先 abort 所有 in-flight turn 的 AbortController（等同于对每个活动 turn 隐式 `agent.cancel`）
  - 清掉 turns 数组与 LLM 历史
  - 然后发送 `conversation.reset` 通知，Shell 镜像跟着清空
  - ack `{ ok: true }`
  - 该方法**幂等**——重复调用空集再发一次 reset 通知

### `conversation.*`（Bun → Shell，notifications 全部）

Sidecar 是 Conversation 的唯一权威。Shell 的 `AgentService` 是被动镜像：所有 turn 的创建、文本累积、状态切换、错误标记都由下列通知驱动；Shell 不允许本地分配 turnId 或追加 turn。

| Method | 类型 | Params | 说明 |
|---|---|---|---|
| `conversation.turnStarted` | Notification | `{ turn: ConversationTurnWire }` | 在 `agent.submit` 的 ack **之前**发出。`turn` 是 sidecar 刚 register 的 turn 快照（`reply: ""`、`status: "thinking"`）。Shell 据此把 turn 加入它的 `turns[]` |
| `conversation.reset` | Notification | `{}` | `agent.reset` 完成后必发；Shell 收到后清空镜像 |

```ts
type TurnStatus = "thinking" | "working" | "waiting" | "done" | "error" | "cancelled";

interface ConversationTurnWire {
  id: string;
  prompt: string;
  citedContext: CitedContext;
  reply: string;
  status: TurnStatus;
  errorMessage?: string;
  errorCode?: number;
  startedAt: number;          // ms since epoch
}
```

Lifecycle 不变量：

- **每个 `agent.submit` 都先发 `conversation.turnStarted`、再返回 ack**——保证观察者在看到 ack 前就能找到 turn，避免随后 `ui.token` 投到不存在的 turn。
- **流式 reply 走 `ui.token`，不走 `conversation.*`**——避免每个字符付一次 turn snapshot 的序列化代价。Sidecar 同时把 delta 写进自己持有的 turn `reply` 字段，Shell 镜像通过 `ui.token` 累加。
- **状态变化走 `ui.status` / `ui.error`**——sidecar 内部 turn 状态切换的同时发对应通知；Shell 镜像与 sidecar 同步靠这些事件。
- **mutation 失败的 race**：`agent.reset` / `agent.cancel` 之后到达的 stream 事件可能尝试写一个已被清掉的 turn。Sidecar 的 `Conversation` mutators 对 unknown turnId 显式返回 `false`（不抛错），上游 `loop.ts` 在 `false` 分支不发 `ui.*`——这是唯一被允许的「写失败但不报错」路径，其他任何 mutation 失败都会 throw 并走通用错误漏斗。

### `config.*`（Shell → Bun）

Sidecar 拥有持久化（`~/.aos/config.json`）和 catalog（provider/model 目录）。Shell 的 settings panel 完全只读，通过下面三个方法 driven。

| Method | 类型 | Params | Result |
|---|---|---|---|
| `config.get` | Request | `{}` | `{ selection?, effort?, defaultEffort, providers: ConfigProviderEntry[] }` |
| `config.set` | Request | `{ providerId, modelId }` | `{ selection: { providerId, modelId } }` |
| `config.setEffort` | Request | `{ effort }` | `{ effort }` |

```ts
type ConfigEffort = "minimal" | "low" | "medium" | "high" | "xhigh";

interface ConfigModelEntry  { id: string; name: string; reasoning: bool; supportsXhigh: bool; }
interface ConfigProviderEntry { id: string; name: string; defaultModelId: string; models: ConfigModelEntry[]; }
interface ConfigSelection   { providerId: string; modelId: string; }
```

- `config.get` 把当前选择 + 完整 catalog snapshot 一并返回，避免 Shell 二次查询「有哪些模型可选」。
- `selection` / `effort` 为 `null` 表示用户从未选过；Shell 在 UI 端用 catalog 默认值兜底，sidecar agent loop 同样在 `agent.submit` 时回落到 `DEFAULT_MODEL_PER_PROVIDER` / `DEFAULT_EFFORT`——**这是唯一允许的回落**。
- Sidecar 对配置文件的 fail-fast 契约（P2.4）：
  - 文件**不存在** → 返回空 config（首启动路径）
  - 文件**存在但 JSON 损坏 / schema 不符** → `config.get` 抛 `agentConfigInvalid` (-32301)；用户必须显式重置或修复
  - `agent.submit` 时若 selection 指向已被 catalog 删除的 model → `runTurn` 抛 internalError 并走 `ui.error`（不静默换默认）
  - `config.set` / `config.setEffort` 在「现有 config 损坏」时容忍——把它当作空配置 merge，给用户一条恢复路径
- 设置变更不走 `settings.update` notification（设计文档原本预留的字段）；Shell 主动 RPC 写、agent loop 在每次 `agent.submit` 时重读 `~/.aos/config.json`。这是 stage 0 的简化，可与 `settings.*` 合并。

### `settings.*`（Shell → Bun）

| Method | 类型 | Params |
|---|---|---|
| `settings.update` | Notification | `{ key, value }` |

用户改设置（模型选择、API key、行为开关等）时推送。Bun 侧热更新 in-memory 配置。

### `computerUse.*`（Bun → Shell）

| Method | 类型 | Params | Result |
|---|---|---|---|
| `computerUse.listApps` | Request | `{}` | `{ apps: AppInfo[] }` |
| `computerUse.listWindows` | Request | `{ pid }` | `{ windows: WindowInfo[] }`，每项含 `windowId` / `title` / `bounds` / `isOnScreen` / `onCurrentSpace` |
| `computerUse.getAppState` | Request | `{ pid, windowId, captureMode? }` | `{ stateId, axTree?, screenshot? }` |
| `computerUse.click` | Request | `{ pid, windowId, stateId, elementIndex, action? }`（语义化）<br>或 `{ pid, windowId, x, y, count?, modifiers? }`（坐标） | `{ success, method }` |
| `computerUse.drag` | Request | `{ pid, windowId, from: {x,y}, to: {x,y} }` | `{ success }` |
| `computerUse.typeText` | Request | `{ pid, windowId, text }` | `{ success }` |
| `computerUse.pressKey` | Request | `{ pid, windowId, key, modifiers? }` | `{ success }` |
| `computerUse.scroll` | Request | `{ pid, windowId, x, y, dx, dy }` | `{ success }` |
| `computerUse.doctor` | Request | `{}` | `{ accessibility, screenRecording, automation, skyLightSPI }` |

- agent 必须先 `listWindows({pid})` 选定 `windowId`，再调用任何状态 / 操作方法。**永远不隐式选窗口**；`(pid, windowId)` 是所有操作的硬契约
- `getAppState` 返回的 `stateId` 是 Kit 内部对 `(pid, windowId)` 一次 AX 树遍历结果的 handle，TTL 30s
- `captureMode ∈ "som" (默认) | "vision" | "ax"`：分别对应 AX 树+截图 / 仅截图 / 仅 AX 树
- 使用 `elementIndex` 点击时必须带对应的 `stateId`；stateId 过期或窗口状态变化返回 `ErrStateStale`
- 坐标点击路径不依赖 stateId，每次独立 hit-test
- `(pid, windowId)` 与 `stateId` 记录不一致 → `ErrWindowMismatch`
- 目标 window 不在用户当前 Space → `ErrWindowOffSpace`，`error.data` 附 `currentSpaceID` / `windowSpaceIDs`
- `doctor.skyLightSPI` 子结构：`{ postToPid, authMessage, focusWithoutRaise, windowLocation, spaces, getWindow }`，每项 `bool` 表示对应 SkyLight SPI 是否成功 dlsym 解析

Shell 的 `ComputerUseHandlers` 通过 async handler 调用 `AOSComputerUseKit` 对应方法。每个 handler 在独立 Swift Task 内执行，不阻塞 dispatcher。

### `ui.*`（Bun → Shell）

| Method | 类型 | Params | 说明 |
|---|---|---|---|
| `ui.token` | Notification | `{ turnId, delta }` | 流式 agent 输出增量（文本片段） |
| `ui.status` | Notification | `{ turnId, status }` | `status ∈ "thinking" \| "tool_calling" \| "waiting_input" \| "done"` |
| `ui.error` | Notification | `{ turnId, code, message }` | Agent 层错误 |

Shell 的 `UIHandlers` 把这些转为 SwiftUI 状态更新，驱动 Notch UI。

### `provider.*`（双向，详见 namespace 子表）

| Method | 方向 | 类型 | Params | Result |
|---|---|---|---|---|
| `provider.status` | Shell → Bun | request | `{}` | `{ providers: ProviderInfo[] }` |
| `provider.startLogin` | Shell → Bun | request | `{ providerId }` | `{ loginId, authorizeUrl }` |
| `provider.cancelLogin` | Shell → Bun | request | `{ loginId }` | `{ cancelled }` |
| `provider.loginStatus` | Bun → Shell | notification | `{ loginId, providerId, state, message?, errorCode? }` | — |
| `provider.statusChanged` | Bun → Shell | notification | `{ providerId, state, reason?, message? }` | — |

```ts
interface ProviderInfo { id: string; name: string; state: "ready" | "unauthenticated" }
type ProviderLoginState  = "awaitingCallback" | "exchanging" | "success" | "failed";
type ProviderState       = "ready" | "unauthenticated";
type ProviderStatusReason = "authInvalidated" | "loggedOut";
```

详细语义见 `docs/plans/onboarding.md`。

## 错误模型

JSON-RPC 标准错误码保留：`-32700 ~ -32603`。应用自定义错误分段：

| 段 / 码 | 常量名 | 含义 |
|---|---|---|
| `-32000 ~ -32099` | 通用 | 应用层通用错误 |
| `-32000` | `ErrUnhandshaked` | `rpc.hello` 前发了业务 method |
| `-32001` | `ErrPayloadTooLarge` | 单条消息或 binary payload 超上限 |
| `-32002` | `ErrTimeout` | 方法执行超时 |
| `-32003` | `ErrPermissionDenied` | Accessibility / Screen Recording / Automation 权限缺失 |
| `-32100 ~ -32199` | `computerUse.*` | Computer Use 错误 |
| `-32100` | `ErrStateStale` | `stateId` 过期 / 元素失效 / 窗口结构变化 |
| `-32101` | `ErrOperationFailed` | 三层降级链路全部失败 |
| `-32102` | `ErrWindowMismatch` | `windowId` 不属于 `pid`，或与 `stateId` 记录的 `(pid, windowId)` 不一致 |
| `-32103` | `ErrWindowOffSpace` | 目标 window 不在用户当前 Space |
| `-32200 ~ -32299` | `auth.*` | Provider 鉴权 / login 错误 |
| `-32200` | `loginInProgress` | 已有未完成的 login session |
| `-32201` | `loginCancelled` | session 被显式 cancel |
| `-32202` | `loginTimeout` | 超过 5min 没有 callback |
| `-32203` | `unknownProvider` | `providerId` 不在已知列表 |
| `-32204` | `loginNotConfigured` | client_id / endpoint 未配置 |
| `-32300 ~ -32399` | `agent.*` | Agent 层错误 |
| `-32300` | `agentContextOverflow` | 超过 model.contextWindow，不做 compaction，直接 ui.error |
| `-32301` | `agentConfigInvalid` | `~/.aos/config.json` 损坏或 schema 不符（fail-fast，不静默回落） |

`error.data` 承载结构化 context，供 agent 判断重试或换策略：

- `ErrOperationFailed.data = { layers: [{ name: "axAction" | "axAttribute" | "eventPost", status: <kit code|string> }, ...] }` —— 三层各自的失败原因
- `ErrWindowOffSpace.data = { currentSpaceID: number, windowSpaceIDs: number[] }`
- `ErrWindowMismatch.data = { pid: number, windowId: number, expected?: { pid, windowId } }`
- `ErrStateStale.data = { stateId: string, reason: "expired" | "elementInvalid" | "windowChanged" }`

## 二进制 payload 规则

所有 binary 数据以 base64 字符串 inline 在 JSON object 内传输：

| 字段 | 上限（base64 编码后） |
|---|---|
| `citedContext.visual.frame` | 400KB |
| `computerUse.getAppState.screenshot` | 1MB |
| 单条 NDJSON 行 | 2MB |

超限返回 `ErrPayloadTooLarge`，不做静默裁切。发送方在编码前做必要的下采样以满足上限。

Dispatcher 读满单行 2MB 仍未见 `\n` 时直接断开连接并重启 Bun。

## Dispatcher 并发模型

**Shell 侧**：
- stdin reader 为独立 Swift Task，只做 parse + dispatch，不执行 handler 业务
- 每个收到的 Request 派发到独立 `Task { ... }` 执行，handler 之间互不阻塞
- `rpc.ping` 和 `agent.cancel` 走快路径：dispatcher 内联处理，不排队在长操作后
- 每个 method 有默认 timeout：

| Method | Timeout |
|---|---|
| `rpc.ping` | 1s |
| `computerUse.listApps` / `doctor` | 2s |
| `computerUse.click` / `drag` / `typeText` / `pressKey` / `scroll` | 5s |
| `computerUse.getAppState` | 10s |
| `agent.submit` / `agent.cancel` 的 ack | 1s |

超时返回 `ErrTimeout`。

**Bun 侧**：
- stdin reader 同样独立 async loop，每条 Notification / Request 派发到独立 async handler
- Shell → Bun 的 Request 不设 timeout（由 Shell 决定何时超时重试）

## 流式语义

`agent.submit` 是唯一的长耗时 operation：

1. `agent.submit` Request 立刻返回 `{ accepted: true }`
2. Bun 开始跑 agent loop，每产生一段文本发 `ui.token { turnId, delta }`
3. 状态切换发 `ui.status { turnId, status }`
4. 结束发 `ui.status { turnId, status: "done" }`
5. 若中途 Shell 收到用户 ESC → 发 `agent.cancel { turnId }` Request，Bun 终止 loop 并发 `ui.status { turnId, status: "done" }`

取消语义限定在 `agent.cancel`，不提供通用 cancellation。

## Schema 单一信源

Swift Codable 为 source of truth，TS 类型手写同步，一致性通过 fixture-driven conformance test 保证：

```
packages/
  AOSRPCSchema/                           # Swift package
    Sources/AOSRPCSchema/
      Messages.swift                      # Request/Response/Notification 基础类型
      Agent.swift                         # agent.* params/results + CitedContext / CitedVisual / CitedClipboard / BehaviorEnvelope
      ComputerUse.swift                   # computerUse.* params/results
      UI.swift                            # ui.* params
      Settings.swift                      # settings.* params
    Tests/AOSRPCSchemaTests/
  sidecar/
    src/rpc-types.ts                      # 手写 TS 类型，与 Swift 一一对应
tests/
  rpc-fixtures/                           # canonical JSON 样本，每个 method 至少一条
    agent.submit.json
    agent.cancel.json
    agent.reset.json
    conversation.turnStarted.json
    conversation.reset.json
    config.get.json
    config.set.json
    config.setEffort.json
    computerUse.click.json                # stage 1+
    ...
  rpc-conformance/
    swift-roundtrip-test.swift            # fixture → decode → re-encode → 断言 byte-equal
    ts-roundtrip-test.ts                  # fixture → parse → re-serialize → 断言 byte-equal
```

**Canonical encoder**：Swift 侧 `AOSRPCSchema/CanonicalEncoder.swift` 暴露 `CanonicalJSON.encode(_:)`，`outputFormatting = [.sortedKeys, .withoutEscapingSlashes]`。这两个 flag 都不能省：

- `.sortedKeys` 让对象键按字典序，与 TS 端 `JSON.stringify(sortKeys(value))` 对齐
- `.withoutEscapingSlashes` 是关键——Foundation 默认把字符串内的 `/` 编码为 `\/`，而 `JSON.stringify` 不转义。少了这个 flag，运行时 Swift 发出的 wire bytes 和 TS 发出的 / fixture 文件存的版本不一致

`AOSShell/RPCClient` 在编码每条 NDJSON 时调用 `CanonicalJSON.encode`；测试 fixture 的 byte-equal 断言也用同一个函数——「测试通过但运行时漂移」的伪造稳定性被这个共用 helper 物理消除。

规则：
- 每个 method 的 params / result 在 `rpc-fixtures/` 至少有一条 canonical sample
- Swift 和 TS 的 roundtrip 测试都必须对 fixture 产出 byte-equal 结果
- 新增 / 修改 method 的 PR 必须同步更新：Swift Codable、TS 类型、fixtures
- CI 跑两端 conformance test，任一不通过阻断合并

协议版本常量在 `AOSRPCSchema/Messages.swift` 和 `sidecar/src/rpc-types.ts` 各自声明，fixture 里验证版本字段值一致。

## 版本协商

- `rpc.hello` 是 Bun 的第一条消息，必须带 `protocolVersion: "MAJOR.MINOR.PATCH"`
- Shell 的策略：MAJOR 不匹配 → 拒绝握手 + 终止 Bun；MINOR/PATCH 不匹配 → 日志 warn，接受
- 协议版本常量在 `AOSRPCSchema/Messages.swift` 和 `sidecar/src/rpc-types.ts` 各自声明，conformance fixture 断言两端一致

## 不做的事

- 不做 MCP 作为本协议替代
- 不做 WebSocket / HTTP / gRPC / mmap
- 不做 Request batching
- 不做 pub-sub / 订阅模型
- 不做中间件 / 拦截器
- 不做双向 method 命名空间
- 不做 TS 侧独立 schema source of truth（TS 类型必须手写、跟随 Swift Codable + fixtures，不允许另立标准）

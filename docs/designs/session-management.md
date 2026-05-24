# Session 管理设计

## 目标

进程内多会话管理。在 sidecar 进程生命周期内：

- 用户点击 "+" 创建新会话，旧会话保留在内存中
- 用户点击历史按钮可以查看本进程内所有会话列表，并切回任何一个继续对话
- 切回的旧会话保留它原有的全部 turns，下一次 `agent.submit` 会把这条会话的全部历史重放给 LLM

## 非目标

- **不持久化**。sidecar 进程退出 = 所有会话蒸发。这是约定，不是 bug。Notch UI 历史按钮副标题需要明确写"本次启动以来"
- 不做跨会话搜索 / 标签 / 收藏
- 不做会话级 compaction（context-overflow 仍是单条会话级硬错）
- 不做并发多 active：同一时刻有且仅有一个 active session
- 不做会话间 turn 复制 / fork
- 不做会话级模型独立设置（模型选择仍是全局 config）
- **`ui.thinking` 切换 session 后不可从 wire 恢复**：thinking trace 是 display-only 的高带宽数据，不进入 `ConversationTurnWire`，不进入 `session.activate` 的 snapshot。Shell 切走再切回时如果该 session 在那段时间内仍在跑 thinking，本地 mirror 累积的 thinking 文本保留；但用户**第一次切到**某条由别的客户端/启动期产生、而 Shell 从未挂过 mirror 的 session 时，无法补回 thinking 历史

## 与现状的差异

当前 sidecar `agent/conversation.ts` 是一个**全局单例** `Conversation`，整个进程只有一条对话；`agent.reset` 直接 `_turns = []`。本设计把"会话身份/列表"和"运行时执行"分开，`Conversation` 变成 per-session 实例，新增 `Session` + `SessionManager` 两层抽象。

## 设计原则

参考 `playground/pi-mono/packages/coding-agent/src/core/`：

- **`SessionInfo`（不变元数据）/ `Session`（运行时容器）/ `SessionManager`（注册表 + active 指针）** 三段拆分。在去掉持久化以后，这套抽象仍然成立 —— 它解决的是 SRP，不是磁盘。
- **active session 显式投影到 wire**：所有可能多义的 RPC（`agent.submit` / `agent.cancel` / `agent.reset` / `conversation.turnStarted` / `ui.*` / `dev.context.changed`）都带 `sessionId` 字段，loop 不查 active 指针 —— 不依赖隐式状态。
- **不存在"隐式 session"**：`SessionManager` 启动时为空，Shell 必须显式 `session.create` 拿到首条 sessionId 才能 `agent.submit`。这与"agent.* 不 fallback 到 active"是同一条原则的两面。
- **Sidecar 是 session 状态的唯一真相**。Shell 是镜像。`session.list` / `session.activate` 都返回 sidecar 视角的快照，Shell 不在本地预测。

## 抽象层次

```
SessionManager (singleton)
  ├── Map<SessionId, Session>
  ├── activeId: SessionId | null
  └── sink: (event) => void          ← 注入式，不依赖 dispatcher

Session
  ├── id: SessionId
  ├── info: SessionInfo               ← createdAt, title
  ├── conversation: Conversation      ← 现有类，去掉 singleton 导出
  └── turns: TurnRegistry             ← 每会话一个，agent.cancel/reset 只影响本会话
```

### 模块归属（Sidecar）

```
sidecar/src/agent/
├── session/
│   ├── types.ts          # SessionId, SessionInfo, SessionListItem (wire), SessionEvent
│   ├── session.ts        # class Session
│   └── manager.ts        # class SessionManager（含 sink 注入）
├── conversation.ts       # 不再 export 默认实例；构造函数只关心一个 session 的 turns
├── registry.ts           # TurnRegistry：移到 Session 内部持有，不再是模块单例
├── context-observer.ts   # snapshot 加 sessionId 字段；保留 global latest 语义
├── prompt.ts             # 不变
└── loop.ts               # 改造：从 manager 解析 sessionId → 操作对应 Session
```

**关键决策：`TurnRegistry` 跟随 Session**，不再是模块单例。原因：

- `agent.reset { sessionId }` 只 abort 这条会话的 in-flight turn，不影响其它会话
- 切换 active session 时，旧 session 的 in-flight turn 继续跑、继续写入它自己的 conversation；用户切回时能看到完整结果
- `agent.cancel` 的 turnId 在不同 session 间不必全局唯一（虽然实际依然 UUID，但不依赖这一假设）

### 模块归属（Shell 端字段三层）

当前 `Sources/Shell/Agent/AgentService.swift` 是单镜像，`turns / currentTurn / status / lastErrorMessage / doneRevertTask / errorRevertTask` 全部集中在一处。多 session 后必须明确分层，否则 inactive session 的 `ui.status done` 会污染 active session 的 closed-bar 状态。

| 层 | 字段 | 说明 |
|---|---|---|
| `ConversationMirror`（per-session 实例）| `turns / currentTurn / status / lastErrorMessage / doneRevertTask / errorRevertTask` + `thinking / thinkingStartedAt / thinkingEndedAt`（在 `ConversationTurn` 上） | 单条会话的执行状态。`ui.*` 通知按 `sessionId` 路由到对应 mirror，不论是否当前显示 |
| `SessionStore`（singleton, `@Observable`）| `mirrors: [SessionId: ConversationMirror] / activeId / list` | 注册表 + 路由分发；订阅 dispatcher 通知，按 sessionId 派发 |
| 全局展示状态（Notch closed bar / 输入框可用性）| 派生自 `mirrors[activeId]?.status` | 杜绝 inactive session 的 `ui.status done / error` 改动 active 状态栏 |

### 与其它模块的边界

| 模块 | 是否需要改 | 备注 |
|---|---|---|
| `llm/*` | 不动 | session 抽象完全在 agent/ 内部 |
| `rpc/dispatcher.ts` | **要改** | 新增 `session` namespace 方向（见 § dispatcher 协议方向） |
| `rpc/rpc-types.ts` | 加字段 | `agent.*` params 加 `sessionId`；`ui.*` / `conversation.*` / `dev.context.changed` 加 `sessionId`；新增 `session.*` |
| `Sources/RPCSchema/` | 加文件 | 新增 `Session.swift`（schema source of truth） |
| `prompt.ts` | 不动 | 仍然只看 turn 级别的 `citedContext` |
| `context-observer.ts` | 加字段 | snapshot 加 `sessionId`；保留 global latest 单值（见 § ContextObserver） |

## 数据模型

### `SessionInfo`（运行时不可变 + title 可派生）

```ts
interface SessionInfo {
  id: SessionId;        // 形如 "sess_<8-byte hex>"，进程内唯一
  createdAt: number;    // ms since epoch
  title: string;        // 默认 "New Conversation"；首条 user prompt 提交后自动派生（取首行 ≤32 字符）
}
```

`title` 派生策略放在 `SessionManager` 内部，由 `agent.submit` 触发的"首条 turn"路径调用一次；后续不自动覆盖。**自动派生不发独立通知**，跟随 `session.listChanged` 一起到达。

### `Session`

```ts
class Session {
  readonly id: SessionId;
  readonly info: SessionInfo;
  readonly conversation: Conversation;
  readonly turns: TurnRegistry;
}
```

### `SessionListItem`（wire）

```ts
interface SessionListItem {
  id: SessionId;
  title: string;
  createdAt: number;
  turnCount: number;       // 仅 status=done 的 turn 计数；in-flight/error/cancelled 不计入
  lastActivityAt: number;  // 最后一个 turn 的 startedAt；空会话等于 createdAt
}
```

`turnCount` / `lastActivityAt` 由 `Session` 即时计算，不缓存 —— 会话规模本就有限，避免一致性维护成本。

### `SessionEvent`（manager → sink）

```ts
type SessionEvent =
  | { kind: "created"; session: SessionListItem }
  | { kind: "activated"; sessionId: SessionId }
  | { kind: "listChanged" };          // turnCount/lastActivityAt 变化时
```

Turn 级事件（`turnStarted` / `uiToken` / ...）**不经过 manager**，仍由 loop 直接 `dispatcher.notify`。manager 只关心会话列表层面的变化，避免成为通知中转站。

## RPC 协议变更

### Protocol version bump

当前 `NOTCH_PROTOCOL_VERSION = "1.0.0"`，且 `RPCClient` 在 `rpc.hello` 阶段对 MAJOR 不一致直接拒连。本轮变更不兼容（`agent.*` 加必填 `sessionId`、多组通知加字段、新增 namespace），**必须 bump 到 `2.0.0`**。

- `sidecar/src/rpc/rpc-types.ts:14` `NOTCH_PROTOCOL_VERSION = "2.0.0"`
- `Sources/RPCSchema/` 内对应常量 `notchProtocolVersion = "2.0.0"`
- 不提供 1.x ↔ 2.x 桥接：旧版混跑预期立刻被 `rpc.hello` MAJOR 检查拦下

### 新增 namespace

| Namespace | 方向 | 用途 |
|---|---|---|
| `session.*` | 双向 (`both`) | Shell → Bun 创建/切换/列出；Bun → Shell 列表变更通知 |

### dispatcher 协议方向（必须改 `dispatcher.ts`）

仿照 `provider.*` / `dev.*` 的现有先例。`directionOf` 加 `session` case 返回 `"both"`，并新增 method 级表：

```ts
const SESSION_METHOD_KINDS: Record<string, "request" | "notification"> = {
  "session.create":       "request",
  "session.list":         "request",
  "session.activate":     "request",
  "session.created":      "notification",
  "session.activated":    "notification",
  "session.listChanged":  "notification",
};
```

不加这一段，sidecar 发 `session.created` 会被 dispatcher 默认 `shellToBun` 拦下抛 programmer error。`request` 反向调用 `notify` 也由这张表拦截。

### 错误码新段：`-32400 ~ -32499` `session.*`

| 码 | 常量名 | 含义 |
|---|---|---|
| `-32400` | `unknownSession` | sessionId 在 manager 中不存在 |
| `-32401` | `noActiveSession` | RPC 隐含需要 active session 但 manager 为空（保留位，目前所有调用都显式传 sessionId） |

不为"重复创建"留码 —— `session.create` 不带可碰撞的 id，永远成功。

### `session.*` 方法

| Method | 方向 | 类型 | Params | Result |
|---|---|---|---|---|
| `session.create` | Shell → Bun | Request | `{ title?: string }` | `{ session: SessionListItem }` |
| `session.list` | Shell → Bun | Request | `{}` | `{ activeId: SessionId \| null, sessions: SessionListItem[] }` |
| `session.activate` | Shell → Bun | Request | `{ sessionId }` | `{ snapshot: ConversationTurnWire[] }` |
| `session.created` | Bun → Shell | Notification | `{ session: SessionListItem }` | 创建后必发 |
| `session.activated` | Bun → Shell | Notification | `{ sessionId }` | 切换后必发 |
| `session.listChanged` | Bun → Shell | Notification | `{}` | `SessionListItem` 派生字段（`turnCount` / `lastActivityAt` / `title`）变化时必发。触发点至少包括：首条 user prompt（title 派生 + lastActivityAt）、turn done（turnCount + lastActivityAt）、`agent.reset { sessionId }`（turnCount 归零、lastActivityAt 回退到 createdAt）|

`session.delete` 暂不做（YAGNI，UI 也不暴露）。

`session.list` / `session.activate` 的返回值是**完整快照**，不分页。

#### `session.activate` 的 snapshot 内容

返回 `ConversationTurnWire[]`，按 `startedAt` 升序，对所有状态的 turn（包括 `error` / `cancelled` / 仍在 `thinking`）都返回。Shell 用这个快照重建对话面板。**不返回 in-flight turn 的实时 reply 增量** —— 切换到一个仍在跑的 session 时，活跃 turn 的当前文本通过快照里的 `reply` 字段拿到一次，后续增量继续走 `ui.token { sessionId, turnId, ... }`。

### Snapshot merge 契约（Shell 端）

`session.activate` 返回的 snapshot **不能粗暴覆盖整个 mirror**。否则用户切走再切回某条仍在 thinking 的 session，本地累积的 thinking 文本会被 wire 里没有该字段的 snapshot 抹掉。区分两类字段：

| 字段类型 | 来源 | activate 时的处理 |
|---|---|---|
| Sidecar-authoritative | snapshot 里的 `ConversationTurnWire`：`reply / status / errorMessage / errorCode / citedContext / startedAt` | 用 snapshot 覆盖 mirror 里同名字段 |
| Mirror-only display | `thinking / thinkingStartedAt / thinkingEndedAt`（这些不在 wire 里）| **保留 mirror 现值**，snapshot 不覆盖；仅在 mirror 中无对应 turn 时按"空"初始化 |

**首次 activate 路径**（mirror 中该 sessionId 不存在）：按 snapshot 初始化所有 sidecar-authoritative 字段，display-only 字段为空。这与"切走后再回来"路径自然区分。

### `agent.*` 改动

所有 `agent.*` request params 加 `sessionId: SessionId` 必填字段：

| Method | 旧 Params | 新 Params |
|---|---|---|
| `agent.submit` | `{ turnId, prompt, citedContext }` | `{ sessionId, turnId, prompt, citedContext }` |
| `agent.cancel` | `{ turnId }` | `{ sessionId, turnId }` |
| `agent.reset` | `{}` | `{ sessionId }` |

语义变化：

- `agent.reset` 不再清掉所有会话；只清传入的那条
- `agent.submit` 在传入未知 sessionId 时返回 `unknownSession` 错误（不静默 fallback 到 active）
- 不存在 "默认 session"。Shell 必须先 `session.create` 或 `session.activate` 拿到一个 sessionId 才能 submit

### `conversation.*` / `ui.*` / `dev.*` 改动

| Notification / Request | 加字段 |
|---|---|
| `conversation.turnStarted` | `sessionId` |
| `conversation.reset` | `sessionId` |
| `ui.token` / `ui.thinking.delta` / `ui.thinking.end` / `ui.status` / `ui.error` | `sessionId` |
| `dev.context.changed` | snapshot 内加 `sessionId` |
| `dev.context.get` | response snapshot 内加 `sessionId` |
| `provider.statusChanged` | **不加**，provider 状态是进程级的，不属于 session |

Shell 接收 `ui.*` 时按 `sessionId` 路由到对应的 `ConversationMirror`；如果用户当前显示的不是这条 session，更新写入对应 mirror 但不影响全局展示状态 —— 切回时立即看到最新内容。

## 生命周期

### 进程启动 — 显式 bootstrap

1. `SessionManager` 构造时为空。`activeId = null`
2. Shell 收到 `rpc.hello` 完成后立刻 `session.create` → 拿到首条 session 并自动 activate
3. 后续所有 `agent.submit` 都带这个 sessionId

**显式 bootstrap，不存在隐式 session**。onboarding 期间 Shell 不调用 `session.create`，sidecar manager 维持空。

### "+" 按钮

```
Shell: session.create
  ↓
Bun: 新建 Session、自动 activate（manager.activeId = new id）
  ↓
Bun → Shell: session.created { session }
            session.activated { sessionId }
  ↓
Shell: 清空当前对话面板，等待用户输入
```

`session.create` 自动 activate 是约定，Shell 不需要再单独 `session.activate`。

### 历史按钮 → 选择某条 session

```
Shell: session.list  → 渲染列表
  ↓ 用户点击某条
Shell: session.activate { sessionId }
  ↓
Bun: 切换 active 指针，返回 snapshot
  ↓
Bun → Shell: session.activated { sessionId }
  ↓
Shell: 按 § Snapshot merge 契约 重建/合并对应 mirror，切换显示
```

### 旧 session 中继续提问

切回旧 session 后用户输入新 prompt，`agent.submit { sessionId, ... }` 携带这条 session 的 id；`runTurn` 用这条 session 的 `Conversation.llmMessages()` 作为上下文。LLM 看到完整历史，自然延续之前的对话。

### 进程退出

所有 session 蒸发。下次启动一切重来。

## 并发与一致性

### 多 session 并发 in-flight turn

允许。每个 Session 持有独立的 `TurnRegistry`，独立的 `AbortController`。用户在 session A 提交后立刻切到 session B 提交，A 和 B 同时跑，各自的 `ui.token` 通过 `sessionId` 路由到对应 mirror。

### 切换 active 时的 in-flight

不影响。切换只改 `activeId` 指针，不 abort 任何东西。

### `agent.reset` 的精细化

只 abort 传入 sessionId 的 in-flight turn，只清这条 session 的 conversation；不影响其它 session、不影响 `activeId`。reset 完成后 `SessionListItem` 派生字段（`turnCount` / `lastActivityAt`）会回退，必须发 `session.listChanged` —— 否则历史列表 stale。

### Race：`agent.submit` 和 `session.activate` 同帧

不存在 race。**`agent.submit` 不读 active 指针**，只用入参里的 `sessionId` 寻址；`session.activate` 只动 `activeId`，不动 conversation。两者操作的是正交状态，到达顺序对各自结果都没有影响。

（之前版本宣称"dispatcher 顺序保证"是误述：sidecar dispatcher 对 request 启动 async handler，非串行事务。但显式 sessionId 让顺序问题从根上消失。）

### Race：`session.delete`（未来）和 in-flight turn

YAGNI，本轮不做。未来如果加，约定为：先 `agent.reset { sessionId }` 再删除。

## Conversation 的最小改造

`agent/conversation.ts` 现有 mutator-returns-boolean 的 race 设计直接复用：

- 删掉文件末尾 `export const conversation = new Conversation()` 单例导出
- 注释里 "Multi-session support is intentionally not built yet" 这段更新成"由 Session 持有"
- 公开面（`startTurn` / `appendDelta` / `setStatus` / `markDone` / `setError` / `reset` / `llmMessages` / `toWire`）一字不改

`registry.ts` 的 `TurnRegistry` 同上，删掉模块单例 `export const turns = new TurnRegistry()`。

## ContextObserver

**保留 global latest 单值**，不做 per-session map。语义对齐 Dev Mode 的实际用途：

- `ContextObserver` 表达"sidecar 最近一次实际发给 LLM 的输入"，不是"active session 的输入"
- 后台 session 跑出去的 prompt 也是真正发出去的，Dev Mode 看到它符合"观测 LLM 输入"的本意
- per-session map 是 YAGNI；如果未来要做 Dev Mode timeline，那是另一个特性，不该捎带进来

具体改动：

- `DevContextSnapshot` 加 `sessionId` 字段
- `ContextObserver._latest` 仍是单值，`publish` 直接覆盖
- Dev Mode UI 渲染时显示 `sessionId` + 当前是否 active 的角标
- 设计文档不再保留"Dev Mode 默认显示 active session"的措辞

## 与未来 s06 / s07 的衔接

- **s06 Context Compact**：压缩动作在单 session 内进行，不跨 session。`Conversation.llmMessages()` 输出前先压缩 —— session 抽象不需要变。
- **s07 Task System**：Task 隶属于 Session，多个 task 共用 session 的 conversation 历史。本设计的 `Session.turns` 只是 LLM 调用的 abort 通道，不要混入 task 状态。

## 风险与权衡

| 风险 | 缓解 |
|---|---|
| 用户以为会话会持久化 | UI 文案明确"本次启动以来"；空状态友好提示 |
| 内存泄漏（无上限累计 session） | 本轮不限。后续如有问题再加 LRU 或上限提示。日常使用预计单进程不超过几十条 session |
| 用户在 session A 等待 LLM 响应时切到 B 提交后立刻切回 A，看不到中途的 thinking | snapshot 不覆盖 mirror-only display 字段，本地累积的 thinking 文本保留；A 的 ui.thinking 持续走 mirror 路由不间断 |
| 首次切到 Shell 从未挂过 mirror 的 session 时无法补回 thinking | 接受。设计非目标已声明 |
| `sessionId` 加到 `ui.*` 增加每帧 payload 体积 | sessionId ~12 字节，相对每条 token notification 已有的 turnId 增量可忽略 |

## 测试不变量

下列在 plan 中具体落地，这里只列必须覆盖的不变量：

1. 创建 N 条 session，逐一 submit，互不干扰：每条的 `llmMessages()` 只含自己的 turns
2. session A in-flight 时切到 B，A 的 stream 继续写入 A 的 conversation；B 的 ui.token 不带 A 的 sessionId
3. `agent.reset { sessionId: A }` 不影响 B 的 turn count
4. 切回旧 session 后 submit，LLM messages 含旧历史
5. unknown sessionId 在 `agent.submit` / `session.activate` / `agent.cancel` / `agent.reset` 都返回 `unknownSession`
6. dispatcher 拒绝 `session.*` 反向调用：`notify("session.create", ...)` / `request("session.created", ...)` 都抛 programmer error
7. inactive session 的 `ui.status done` / `ui.error` 不污染 active session 的全局展示状态
8. Snapshot merge 不覆盖 mirror-only 字段：thinking 文本在 activate 前后不变
9. Dev snapshot 携带正确 sessionId；后台 session publish 后 `latest()` 反映该 sessionId（global latest 语义）
10. `rpc.hello` MAJOR 不一致拒连：1.x 客户端连 2.0.0 sidecar 必失败

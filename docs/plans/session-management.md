# Session 管理实现计划

设计依据：
- [docs/designs/session-management.md](../designs/session-management.md)
- [docs/designs/rpc-protocol.md](../designs/rpc-protocol.md)（本轮新增 namespace `session.*`、错误码段 `-32400 ~ -32499`、`NOTCH_PROTOCOL_VERSION` bump 至 `2.0.0`，以及 `agent.*` / `conversation.*` / `ui.*` / `dev.*` 加 `sessionId` 字段，需要在 namespace 表、错误码表、各 method 描述同步更新）

## 范围

进程内多会话管理。不持久化。

落地后 Shell 端能力：
- "+" 按钮 → 新会话（旧会话保留）
- 历史按钮 → 列出本次启动以来所有会话 → 切换继续对话
- 多 session 并发 in-flight turn

## 非目标（与 design 一致）

- 持久化 / 跨进程会话
- 会话级 compaction（保留 `agentContextOverflow` 现有硬错语义）
- session.delete / 重命名 UI（manager 留接口但不连 RPC）
- 会话级模型独立设置
- ui.thinking 切换后从 wire 恢复（保留 mirror 累积值，但不重建丢失片段）

## 关键架构决策（已锁定）

### 1. `agent.*` 全部加 `sessionId` 必填字段

不做"无 sessionId 自动落到 active"。理由见 design `§ 设计原则 / active session 显式投影到 wire`。

### 2. `TurnRegistry` 由 `Session` 持有

不做"全局 registry + 复合 key"。`agent.reset` 语义是"清当前会话"，全局 key 化让 reset 实现需要枚举筛选，复杂度更高且容易漏 abort 跨 session 残留。

### 3. `Conversation` 去单例，`SessionManager` 是新单例

`agent/loop.ts` 通过 manager 解析 sessionId → Session → Conversation。

### 4. `session.create` 自动 activate

减少 RPC 往返与时序窗口。Shell 不需要在 `create` 后再 `activate` 一次。

### 5. Manager 不中转 turn 级通知

`ui.*` / `conversation.turnStarted` 仍由 `loop.ts` 直接 `dispatcher.notify` 发出，sessionId 作为字段携带。`SessionManager` 只发会话列表层面的 3 个事件（`created` / `activated` / `listChanged`）。

### 6. Title 自动派生跟随 `session.listChanged`，不发独立通知

首条 user prompt 提交时由 manager 派生（首行 ≤32 字符）。

### 7. dispatcher 必须改 — 新增 `session` namespace 方向 + method 级表

仿照 `provider.*` / `dev.*` 的先例。不加这一段，sidecar 发 `session.created` 会被默认 `shellToBun` 拦下。

### 8. ContextObserver 保留 global latest 单值

snapshot 加 `sessionId`，UI 标注 active 与否。不做 per-session map。

### 9. Snapshot merge 区分 sidecar-authoritative vs mirror-only 字段

`session.activate` 返回的 snapshot 只覆盖 `reply / status / errorMessage / errorCode / citedContext / startedAt`；`thinking / thinkingStartedAt / thinkingEndedAt` 保留 mirror 现值。详见 design `§ Snapshot merge 契约`。

### 10. `NOTCH_PROTOCOL_VERSION` bump 到 `2.0.0`

`agent.*` 加必填字段是 wire breaking change，且现有 `RPCClient` 在 `rpc.hello` 阶段强制 MAJOR 一致。不 bump 旧 Shell 连新 Sidecar 会以参数错误形式失败而非协议错误，诊断成本更高。

## 落地步骤

每一步独立可合（除明确标注的"不可拆"步骤）。

### Step 1 — Sidecar 内部抽象（纯重构，行为不变，单 session）

**独立可合**。

目标：把 `Conversation` / `TurnRegistry` 单例去掉，引入 `Session` + `SessionManager`，但只跑一条进程级 session，wire 不变。

> **注意**：Step 1 中的"进程级 session 由 sidecar 启动时自动 create"是**临时兼容层**，仅为本 Step PR 内保持 wire 不变而存在。Step 2 会删除该自动 create 逻辑，改由 Shell 显式 `session.create` bootstrap。最终设计（design 文档锁定）是"manager 启动时为空、不存在隐式 session"，实现时不要把 Step 1 的过渡形态保留下来。

文件改动：
- 新增 `sidecar/src/agent/session/types.ts`：`SessionId`、`SessionInfo`、`SessionListItem`、`SessionEvent`
- 新增 `sidecar/src/agent/session/session.ts`：`class Session`，构造时分配独立的 `Conversation` + `TurnRegistry`
- 新增 `sidecar/src/agent/session/manager.ts`：`class SessionManager`，含 `create / activate / get / list / setSink`
- 改 `sidecar/src/agent/conversation.ts`：删 `export const conversation = ...`
- 改 `sidecar/src/agent/registry.ts`：删 `export const turns = ...`
- 改 `sidecar/src/agent/loop.ts`：构造一个进程级 `SessionManager`，初始化时 `create` 一条 session 作为唯一 active；现有 handler 内部从 manager 拿 conversation/registry，外部 wire 不变

通过 sidecar 现有 agent loop 测试验证行为不变。

### Step 2 — Protocol migration（**Sidecar + Shell + fixtures + protocolVersion bump 同 PR 不可拆**）

目标：暴露多会话能力到 wire，同时 Shell 完成显式 bootstrap，保证合入即可运行。

**为什么不可拆**：`agent.*` 加必填 `sessionId` + `NOTCH_PROTOCOL_VERSION` bump 是 wire breaking change。如果 Sidecar 先合，Shell 还在发旧格式 + 旧版本号，`rpc.hello` MAJOR 检查直接拒连。必须同 PR：

#### Sidecar 侧

- 改 `sidecar/src/rpc/rpc-types.ts`：
  - `NOTCH_PROTOCOL_VERSION = "2.0.0"`
  - `AgentSubmitParams` / `AgentCancelParams` / `AgentResetParams` 加 `sessionId`
  - `ConversationTurnStartedNotification` / `ConversationResetNotification` 加 `sessionId`
  - `UIToken / UIThinkingDelta / UIThinkingEnd / UIStatus / UIError` 全部加 `sessionId`
  - `DevContextSnapshot` 加 `sessionId`
  - 新增 `SessionCreateParams/Result`、`SessionListParams/Result`、`SessionActivateParams/Result`
  - 新增 `SessionCreatedNotification`、`SessionActivatedNotification`、`SessionListChangedNotification`
  - `RPCMethod` 枚举加 `sessionCreate / sessionList / sessionActivate / sessionCreated / sessionActivated / sessionListChanged`
  - `RPCErrorCode` 加 `unknownSession = -32400`、`noActiveSession = -32401`
- 改 `sidecar/src/rpc/dispatcher.ts`：
  - `directionOf` 加 `case "session": return "both"`
  - 新增 `SESSION_METHOD_KINDS` 表声明 6 个 method 的 request/notification 归属
  - `splitKind` 查询逻辑覆盖 session
- 改 `sidecar/src/agent/loop.ts`：
  - `agent.submit` 校验 `sessionId`，从 manager 解析，未知 → `unknownSession`
  - `agent.cancel` 同上
  - `agent.reset { sessionId }` 只清这条 session
  - 所有 `dispatcher.notify(uiToken/...)` 调用点 params 加 sessionId
- 新增 `sidecar/src/agent/session/handlers.ts`（独立文件）：注册 `session.create / list / activate`，把 manager 的 sink 接到 dispatcher
- 改 `sidecar/src/agent/context-observer.ts`：`DevContextSnapshot` 加 `sessionId`；保留单 latest 语义
- 删除 Step 1 的"进程级 bootstrap session"逻辑，改为 manager 启动时为空，等待 Shell `session.create`

#### Schema (RPCSchema) 侧

- 新增 `Sources/RPCSchema/Session.swift`：`SessionId / SessionInfo / SessionListItem / SessionCreateParams / SessionListResult / SessionActivateParams / SessionActivateResult / SessionCreatedNotification / SessionActivatedNotification / SessionListChangedNotification` Codable
- 改 `Sources/RPCSchema/Agent.swift`（或对应文件）：3 个 `agent.*` params 加 `sessionId`
- 改 `Sources/RPCSchema/Conversation.swift`（或对应文件）：2 个 notification 加 `sessionId`
- 改 `Sources/RPCSchema/UI.swift`（或对应文件）：5 个 `ui.*` params 加 `sessionId`
- 改 `Sources/RPCSchema/Dev.swift`（或对应文件）：`DevContextSnapshot` 加 `sessionId`
- 改 schema 中的 `notchProtocolVersion = "2.0.0"`

#### Shell 侧（最小 bootstrap，不做多镜像）

- 新增 `Sources/Shell/Agent/SessionService.swift`：包装 `session.create / list / activate` 三个 RPC，对外暴露 async API
- 改 `Sources/Shell/App/CompositionRoot.swift`（或对应启动序列）：`rpc.hello` 完成后调 `SessionService.create()`，把返回的 sessionId 存为 "current"
- 改 `Sources/Shell/Agent/AgentService.swift`：`submit / cancel / reset` 三个对外方法接受/读取 current sessionId 字段，把它带进对应 RPC params
- 接收 `ui.*` / `conversation.*` 时忽略 `sessionId` 字段（本步只跑单 session，多镜像在 Step 3 做）

#### Fixture 全量更新（共 18 项）

12 个现有 fixture 加字段：
- `Tests/rpc-fixtures/agent.submit.json` — params 加 sessionId
- `Tests/rpc-fixtures/agent.cancel.json` — params 加 sessionId
- `Tests/rpc-fixtures/agent.reset.json` — params 加 sessionId
- `Tests/rpc-fixtures/conversation.turnStarted.json` — params 加 sessionId
- `Tests/rpc-fixtures/conversation.reset.json` — params 加 sessionId
- `Tests/rpc-fixtures/ui.token.json` — params 加 sessionId
- `Tests/rpc-fixtures/ui.status.json` — params 加 sessionId
- `Tests/rpc-fixtures/ui.error.json` — params 加 sessionId
- `Tests/rpc-fixtures/ui.thinking.delta.json` — params 加 sessionId
- `Tests/rpc-fixtures/ui.thinking.end.json` — params 加 sessionId
- `Tests/rpc-fixtures/dev.context.changed.json` — snapshot 加 sessionId
- `Tests/rpc-fixtures/dev.context.get.json` — response snapshot 加 sessionId

6 个新 fixture：
- `Tests/rpc-fixtures/session.create.json`
- `Tests/rpc-fixtures/session.list.json`
- `Tests/rpc-fixtures/session.activate.json`
- `Tests/rpc-fixtures/session.created.json`
- `Tests/rpc-fixtures/session.activated.json`
- `Tests/rpc-fixtures/session.listChanged.json`

`Tests/rpc-fixtures/rpc.hello.json` 内 `protocolVersion` 同步改 `2.0.0`。

#### 测试

- `dispatcher.test.ts`：`notify("session.create", ...)` 抛错；`request("session.created", ...)` 抛错；正向调用通畅
- TS↔Swift roundtrip 测试覆盖所有改动 fixture（如已有 roundtrip 框架则全量重跑；没有则在本 Step 引入最低限度的 fixture decode 测试）
- `rpc.hello` MAJOR 不一致拒连测试：用 `1.0.0` 模拟拒连

### Step 3 — Shell 多镜像拆分 + Snapshot merge

**独立可合**（在 Step 2 已经全部 wire 落地的基础上）。

目标：把 Shell 端从单镜像改成 `[SessionId: ConversationMirror]`，做正确的字段归属与 snapshot merge。

文件改动：
- 新增 `Sources/Shell/Agent/ConversationMirror.swift`：从现有 `AgentService` 拆出 per-session 字段（`turns / currentTurn / status / lastErrorMessage / doneRevertTask / errorRevertTask`）
- 新增 `Sources/Shell/Agent/SessionStore.swift`：`@Observable`，`mirrors: [SessionId: ConversationMirror]`、`activeId: SessionId?`、`list: [SessionListItem]`
- 改 `Sources/Shell/Agent/AgentService.swift`：薄化为"当前 active 的转发器"；全局展示状态从 `mirrors[activeId]?.status` 派生
- `ui.*` / `conversation.*` notification handler 按 `sessionId` 路由到对应 mirror（如果不存在则按需创建）
- 实现 `session.activate` 的 snapshot merge：sidecar-authoritative 字段覆盖；mirror-only display 字段（thinking）保留
- 处理首次 activate 路径（mirror 不存在）按 snapshot 初始化

测试：
- `SessionStoreTests`：路由 ui.token 到正确 mirror、切 activeId 不丢镜像
- `ConversationMirrorTests`：merge 不覆盖 thinking 文本
- inactive session ui.status done 不改 active session 的 closed-bar 状态
- snapshot 含 in-flight turn 时合并后 reply 取 snapshot 值，thinking 取 mirror 值

### Step 4 — Notch UI："+" 按钮 + 历史按钮

**独立可合**。

文件改动：
- Notch opened 态左上加 "+" 按钮 → `SessionService.create()` → UI 切到新空对话（自动 activate 已由 Sidecar 通知触发）
- Notch opened 态右上加历史按钮 → 弹出会话列表
  - 列表项：title、相对时间（基于 `lastActivityAt`）、turn 数
  - 副标题或空状态文案明确"本次启动以来"
  - 当前 active 项高亮
  - 点击非 active 项 → `SessionService.activate(id)` → `SessionStore` 收到 `session.activated` 后切显示
- 输入框、Send、ESC 等绑定到 `SessionStore.activeId`

### Step 5 — Dev Mode

**独立可合**。

- Dev Mode 窗口显示 snapshot 里的 `sessionId`（标题或角标），并标注是否当前 active
- 删除原"Dev Mode 默认显示 active session"措辞，改为"显示全局 latest LLM 输入"
- 切 active 时不立刻清空显示；下次新 turn publish 才覆盖

### Step 6 — 端到端测试

**独立可合**。

#### Sidecar 单元测试（Bun + Vitest 或现有 runner）

- `session/manager.test.ts`：
  - create 自增、activate 切换、未知 id 抛错
  - sink 收到 `created` / `activated` / `listChanged`
  - listChanged 在首条 user prompt 与 turn done 时各发一次
- `session/session.test.ts`：每个 Session 持有独立 conversation/registry，互不影响
- 改造现有 `agent/loop.test.ts`：
  - 多 session 并发 turn：A 的 ui.token 不带 B 的 sessionId（用随机 sessionId 防巧合）
  - `agent.reset { sessionId: A }` 不影响 B 的 turn count
  - 切回旧 session 后 submit，llmMessages 含旧历史
  - unknown sessionId 在 `submit/cancel/activate/reset` 都返回 `unknownSession` 错误码
- `context-observer.test.ts`：snapshot 带正确 sessionId；后台 session publish 后 `latest()` 反映该 sessionId

#### Shell 单元测试（Swift Testing）

- `SessionStoreTests`、`ConversationMirrorTests`、`SessionServiceTests`（fixture 解码 + 路由）
- inactive session 通知不污染 active UI 的端到端断言

#### E2E（如已有 e2e 框架）

- 启动 → bootstrap session.create → submit → 验证收到 turnStarted/uiToken
- create A → submit A → create B（自动 activate）→ submit B → activate A → 验证 A 的 snapshot 含 A 的 turn
- agent.reset { A } 后 list 中 A 的 turnCount = 0、B 不变
- protocolVersion mismatch（用旧 fixture 启动 1.0.0 mock 客户端）→ rpc.hello 拒连

## 风险点与应对

| 风险 | 应对 |
|---|---|
| Step 2 改动跨多文件多语言，容易漏改一处导致运行时静默 | 在 `RPCMethod` 枚举值上做穷尽 switch；TS 编译器报漏掉的分支。Swift 侧 Codable 字段缺失会触发 decode 错误，被 fixture roundtrip 测试拦截。所有 18 个 fixture 必须在同 PR 全量更新 |
| Shell 切 activeId 时 in-flight turn 的中间 thinking 在用户切回前丢失增量 | design 已接受。本地 mirror 仍在累积，重切回时不丢失；但 UI 在 active 期间不显示后台 thinking |
| 多 session 并发 turn 时通知是否会乱序 | **跨 session 顺序不是契约**。每条事件都带 `sessionId + turnId`，Shell 按 key 路由到对应 mirror 即可。需要保证的是单 turn 内的流式顺序（thinking_delta → text_delta → done），由 emit 端保证、被测试覆盖。`agent.submit` 不读 active 指针，submit/activate 顺序对结果无影响 |
| 用户长会话堆积致内存膨胀 | 不在本轮处理。监控指标（已 done turn 总数）可后续加，超过阈值给 UI 提示 |
| 旧 Shell 误连新 Sidecar | `rpc.hello` MAJOR 检查直接拒连，错误信息明确指向版本不匹配 |

## 完成定义

- [ ] **Sidecar**：新增 `session/{types,session,manager,handlers}.ts`，去掉 `conversation` / `turns` 模块单例
- [ ] **Sidecar dispatcher**：`directionOf` 加 `session: both`、新增 `SESSION_METHOD_KINDS` 表，反向调用单测覆盖
- [ ] **Sidecar wire schema**：`NOTCH_PROTOCOL_VERSION = "2.0.0"`；3 个 `agent.*` params + 2 个 `conversation.*` params + 5 个 `ui.*` params 加 `sessionId`；`DevContextSnapshot` 加 `sessionId`（同时覆盖 `dev.context.changed` 和 `dev.context.get` response）；新增 6 个 `session.*` method；新增错误码 `-32400 / -32401`
- [ ] **Schema (RPCSchema)**：新增 `Sources/RPCSchema/Session.swift`；同步全部字段；`notchProtocolVersion = "2.0.0"`
- [ ] **Fixture 全量更新**：12 个改 + 6 个新 + `rpc.hello.json` version 更新（合计 19 个文件）
- [ ] **Shell**：`SessionService` / `SessionStore` / `ConversationMirror` 三类落地；`AgentService` 改为 active 转发；启动期 `session.create` 显式 bootstrap
- [ ] **Snapshot merge**：sidecar-authoritative 字段覆盖、mirror-only display 字段保留的合并契约实现 + 测试
- [ ] **Notch UI**："+" 按钮、历史按钮、active 高亮、空状态文案"本次启动以来"
- [ ] **Dev Mode**：snapshot 显示 sessionId + active 标注；删除旧"默认显示 active"措辞
- [ ] **测试**：dispatcher 反向调用、多 session 并发按 sessionId+turnId 路由不串、单 turn 流式顺序保持、agent.reset 隔离 + 触发 session.listChanged、unknown sessionId 错误码、snapshot merge 不污染 thinking、inactive session 不污染 active 全局状态、ContextObserver global latest 行为、`rpc.hello` MAJOR mismatch 拒连
- [ ] **docs/designs/rpc-protocol.md** 同步：namespace 表加 `session.*`、错误码表加 `-32400~-32499`、`agent.*` / `conversation.*` / `ui.*` / `dev.*` method 描述更新 `sessionId` 字段、`NOTCH_PROTOCOL_VERSION` 标注 `2.0.0`
- [ ] 进程退出后无遗留状态（默认行为，无需主动清理）

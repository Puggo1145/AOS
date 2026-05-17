# Agent Harness 实现进度

对照 `playground/learn-claude-code/design docs/` 的 s01–s12 harness 节，盘点
`sidecar/src/agent/` 当前实现到了哪一步。每节的细节见对应的 design doc，本表
只记录大节的整体状态。

| # | 节 | 状态 |
|---|---|---|
| s01 | Agent Loop | ✅ |
| s02 | Tool Use | ✅ |
| s03 | TodoWrite | ✅ |
| s04 | Subagent | ❌ |
| s05 | Skills | ❌ |
| s06 | Context Compact | ✅ |
| s07 | Task System | ❌ |
| s08 | Background Tasks | ❌ |
| s09 | Agent Teams | ❌ |
| s10 | Team Protocols | ❌ |
| s11 | Autonomous Agents | ❌ |
| s12 | Worktree Isolation | ❌ |

## 关键阻塞点

s04 起的节（Subagent / Skills 等）现在都可以在 s03 落成的 session-scoped 状态机制上落地。

## s02 实现摘要

- `agent/tools/` 子模块：`ToolHandler` / `ToolExecContext` / `ToolExecResult` 三件套，全局 `toolRegistry` 提供 `register` / `unregisterBySource` / `list` / `get`，按注册源分组卸载。
- `agent/tools/bash.ts`：`bash -lc` 执行，AbortSignal + timeout 共用同一控制器，输出尾部按行/字节双阈值截断。cwd 不固定，模型用 `cd` 自由切换。
- `agent/workspace.ts` + `agent/system-prompt.ts`：在 `~/.notch-agent/workspace/` 提供自有工作区并写入 system prompt，sidecar 启动时 `ensureWorkspace()` 幂等创建。
- `agent/conversation.ts` 重构：从 `prompt + reply + finalAssistant` 三字段改成扁平 `_messages: Message[]` + 每个 turn 的 `[messageStart, messageEnd)` range。turn 元数据负责 wire/UI 分组，LLM 历史是真源。
- `agent/loop.ts`：`runTurn` 加 tool 子循环，最多 `MAX_TOOL_ROUNDS = 25` 轮；每轮把 `assistant` / `toolResult` 追加进 conversation，`uiToolCall { phase: "called" | "result" }` 通知 Shell。错误（未知工具 / 参数校验失败 / handler 抛错）一律转成 isError 的 ToolResultMessage 让模型自纠，不打断 turn。
- 新增 wire 方法 `ui.toolCall` 与对应 `UIToolCallParams`。
- 新单测：`tool-registry.test.ts`、`bash-tool.test.ts`、`agent-tool-loop.test.ts`（全 182 测试通过）。

## s03 实现摘要

- `agent/todos/manager.ts`：`TodoManager` 持有 `TodoItem[]`，校验「单个 in_progress / 上限 20 / status 闭枚举 / id 唯一 / text 非空」，整体替换语义；`subscribe()` 在每次成功 `update()` 后同步触发；`render()` 输出 `[ ] / [>] / [x] #id: text` 形态供 LLM 自检。
- `Session` 上挂载 `todos: TodoManager`，与 `conversation` / `turns` 平级；`agent.reset` 同步 `todos.clear()`，`session.activate` 末尾 dispatch `ui.todo` 完成水合。
- `agent/tools/todo.ts`：`todo_write` 工具，参数 `{ items: [{id, text, status}] }`，handler 通过 `getManager(sessionId)` 调用 `TodoManager.update()`；校验失败抛 `ToolUserError` 进入可恢复路径。
- `agent/loop.ts`：runTurn 启动时订阅当前 session 的 TodoManager，把每次成功更新投影为 `ui.todo` 通知（finally 中解绑）。
- 「连续 N 轮没动 todo 就注入 `<reminder>` 用户消息」的旧机制已下线，改由通用的 ambient 子系统在每轮请求尾部追加 `<ambient><todos>...</todos></ambient>` 暂态消息：`agent/ambient/{provider,registry,render,providers/todos}.ts` + `register-builtins.ts`，与 tool registry 同形态（`register` / `unregister` / `unregisterBySource` / `list` / 重名抛错）。ambient 块 transient — 不写入 `Conversation`，每轮重新计算；空（所有 provider 返回 null）时整体省略。`Conversation.appendUserMessage()` 因此被删除（零调用方）。`runTurn` 入参从 `todos?` 改成 `session: Session`，以便未来 ambient provider 直接读会话级状态。
- 系统提示词加入「使用 `todo_write` 规划多步任务」段落。
- 协议：新增 `RPCMethod.uiTodo` + `UITodoParams { sessionId, items: TodoItemWire[] }`；TS / Swift 双端、固件 `Tests/rpc-fixtures/ui.todo.json` 字节级 roundtrip 通过。
- Shell：`ConversationMirror.todos` 镜像 + `applyTodo`、`AgentService.todos` 投影；Notch conversation UI 渲染 sticky plan 卡片，状态分别用 `[ ] / [>] / [x]` + 完成态删除线 + 透明度梯度区分；`ToolUIRegistry` 增加 `todo_write` 行 presenter（图标 `checklist`，body 复用 manager 渲染格式）；`OpenedPanelView` 在 history 与 composer 之间挂入 todo list，仅在 `todos` 非空时显示。
- 测试：`todo-manager.test.ts`（10 项校验/订阅/clear/hasOpenWork）、`agent-todo-loop.test.ts`（删除 reminder 用例后 3 项端到端：成功写入 → ui.todo+rendered 输出、in_progress 多份的 ToolUserError 路径不发 ui.todo、agent.reset 清空并发空通知）、新增 `ambient-registry.test.ts` / `ambient-render.test.ts` / `agent-ambient-loop.test.ts` 覆盖注册顺序、空注册/部分 null 渲染、以及 ambient 暂态在多轮 tool 流中重复注入且不进入 `convo.llmMessages()`，Swift `AgentServiceTests` 维持 3 项。整体通过 253 sidecar 用例（typecheck 干净）。

## s06 实现摘要

- 设计选型只做参考实现的 Layer 2 + Layer 3 入口，**故意不做 Layer 1**（原文 `micro_compact` 那种边跑边替换 tool_result 的策略）：替换会破坏 prompt cache 的稳定前缀，且在 Notch Agent 这套规模上收益有限——Claude Code 真实实现里这个策略也是默认关闭并仅在 60 分钟空档时才触发。
- `agent/compact/` 子模块：`prompt.ts` 给 summarization 单独的 system prompt（NO_TOOLS preamble + 4 段结构 Intent/Progress/Current/Anchors，对话场景导向，不是 coding-only）；`manager.ts` 暴露 `compactConversation(session, model)` 核心 + `autoCompactIfNeeded(session, model)` 自动路径包装；`breaker.ts` 维护按 sessionId 分桶的连续失败计数器（默认 3 次失败后本 session auto 路径熔断；手动入口不查熔断）。
- `Conversation` 新增 `lastInputTokens` getter + `recordInputTokens()`，loop 在每个 LLM round 完成后从 `final.usage.input` 抽出写入；这是给 auto-compact 阈值检查的真相源。新增 `compact(activeTurnId, summaryText)`：把 `_messages` 重写为 `[boundary(<compactionBoundary turns=N at=ts/>), summary([Compressed]\n\n<text>), ...活跃 turn slice]`，prune `_turns` 到只剩活跃 turn 并把它的 range 扩展覆盖整个新 buffer（避免 boundary/summary 落在任何 range 之外被 `llmMessages()` 漏掉）。
- `agent/loop.ts`：`runTurn` 入口（model 解析后、while 循环前）调 `autoCompactIfNeeded`，触发条件 `model.contextWindow - convo.lastInputTokens < AUTO_COMPACT_REMAINING_THRESHOLD = 20_000`。生命周期通过 `ui.compact { phase: "started" | "done" | "failed" }` 投到 wire；compact 失败不 fatal，turn 继续以原始（超尺寸）历史前进。`agent.reset` 内增加 `compactBreaker.forget(sessionId)` 钩。
- ambient 替代了之前 s03 设想的「compact 后重注入 todos」步骤——compact 后下一轮的 ambient render 自动把当前 todos 重新拼到尾部，无需 compact 流程介入。
- Layer 3（手动 `/compact`）本轮仅落函数封装，不绑 RPC：`compactConversation` 不依赖熔断也不依赖阈值，可被未来的 `agent.compact` 直接调用，Shell UI 自带触发后只需要 wire 入口即可。
- 协议：新增 `RPCMethod.uiCompact` + `UICompactParams { sessionId, turnId, phase, compactedTurnCount?, errorMessage? }`；TS / Swift 双端 + 三个 fixture（started / done / failed）字节级 roundtrip 通过。
- 测试：`compact-manager.test.ts`（12 项：核心调用契约、prior-only summarization input、layout pinning、错误透传、阈值/熔断/recover 全覆盖）、`agent-compact-loop.test.ts`（5 项端到端：触发→重写、未触发→不动、失败→ui.compact failed + 历史完整、compact 后下一轮 ambient 仍带 todos、`agent.reset` 清熔断器）、`rpc-roundtrip.test.ts` 加 3 个 ui.compact 用例。整体通过 276 sidecar 用例 + Swift `RoundtripTests` 全绿。

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
| s06 | Context Compact | ❌ |
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
- `agent/workspace.ts` + `agent/system-prompt.ts`：在 `~/.aos/workspace/` 提供自有工作区并写入 system prompt，sidecar 启动时 `ensureWorkspace()` 幂等创建。
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
- Shell：`ConversationMirror.todos` 镜像 + `applyTodo`、`AgentService.todos` 投影；`Notch/Components/TodoListView.swift` 渲染 sticky plan 卡片，状态分别用 `[ ] / [>] / [x]` + 完成态删除线 + 透明度梯度区分；`ToolUIRegistry` 增加 `todo_write` 行 presenter（图标 `checklist`，body 复用 manager 渲染格式）；`OpenedPanelView` 在 history 与 composer 之间挂入 `TodoListView`，仅在 `todos` 非空时显示。
- 测试：`todo-manager.test.ts`（10 项校验/订阅/clear/hasOpenWork）、`agent-todo-loop.test.ts`（删除 reminder 用例后 3 项端到端：成功写入 → ui.todo+rendered 输出、in_progress 多份的 ToolUserError 路径不发 ui.todo、agent.reset 清空并发空通知）、新增 `ambient-registry.test.ts` / `ambient-render.test.ts` / `agent-ambient-loop.test.ts` 覆盖注册顺序、空注册/部分 null 渲染、以及 ambient 暂态在多轮 tool 流中重复注入且不进入 `convo.llmMessages()`，Swift `AgentServiceTests` 维持 3 项。整体通过 253 sidecar 用例（typecheck 干净）。

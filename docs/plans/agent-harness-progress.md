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
- `agent/loop.ts`：runTurn 启动时订阅当前 session 的 TodoManager，把每次成功更新投影为 `ui.todo` 通知（finally 中解绑）；新增 `roundsSinceTodo` 计数器，连续 3 轮（`ROUNDS_BEFORE_TODO_NAG`）未调 `todo_write` 且 `hasOpenWork()` 时，向会话追加 `<reminder>...</reminder>` 用户消息后再进入下一轮；`Conversation.appendUserMessage()` 用于这条注入。
- 系统提示词加入「使用 `todo_write` 规划多步任务」段落。
- 协议：新增 `RPCMethod.uiTodo` + `UITodoParams { sessionId, items: TodoItemWire[] }`；TS / Swift 双端、固件 `Tests/rpc-fixtures/ui.todo.json` 字节级 roundtrip 通过。
- Shell：`ConversationMirror.todos` 镜像 + `applyTodo`、`AgentService.todos` 投影；`Notch/Components/TodoListView.swift` 渲染 sticky plan 卡片，状态分别用 `[ ] / [>] / [x]` + 完成态删除线 + 透明度梯度区分；`ToolUIRegistry` 增加 `todo_write` 行 presenter（图标 `checklist`，body 复用 manager 渲染格式）；`OpenedPanelView` 在 history 与 composer 之间挂入 `TodoListView`，仅在 `todos` 非空时显示。
- 测试：`todo-manager.test.ts`（10 项校验/订阅/clear/hasOpenWork）、`agent-todo-loop.test.ts`（4 项端到端：成功写入 → ui.todo+rendered 输出、in_progress 多份的 ToolUserError 路径不发 ui.todo、连续 3 轮非 todo 触发 reminder 注入、agent.reset 清空并发空通知）、Swift `AgentServiceTests` 新增 3 项（替换、reset、跨 session 路由）。整体通过 234 sidecar / 198 swift 用例。

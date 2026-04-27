# Agent Harness 实现进度

对照 `playground/learn-claude-code/design docs/` 的 s01–s12 harness 节，盘点
`sidecar/src/agent/` 当前实现到了哪一步。每节的细节见对应的 design doc，本表
只记录大节的整体状态。

| # | 节 | 状态 |
|---|---|---|
| s01 | Agent Loop | ✅ |
| s02 | Tool Use | ✅ |
| s03 | TodoWrite | ❌ |
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

s03 起的节（TodoWrite / Subagent / Skills 等）现在都可以在 s02 的工具机制上落地。

## s02 实现摘要

- `agent/tools/` 子模块：`ToolHandler` / `ToolExecContext` / `ToolExecResult` 三件套，全局 `toolRegistry` 提供 `register` / `unregisterBySource` / `list` / `get`，按注册源分组卸载。
- `agent/tools/bash.ts`：`bash -lc` 执行，AbortSignal + timeout 共用同一控制器，输出尾部按行/字节双阈值截断。cwd 不固定，模型用 `cd` 自由切换。
- `agent/workspace.ts` + `agent/system-prompt.ts`：在 `~/.aos/workspace/` 提供自有工作区并写入 system prompt，sidecar 启动时 `ensureWorkspace()` 幂等创建。
- `agent/conversation.ts` 重构：从 `prompt + reply + finalAssistant` 三字段改成扁平 `_messages: Message[]` + 每个 turn 的 `[messageStart, messageEnd)` range。turn 元数据负责 wire/UI 分组，LLM 历史是真源。
- `agent/loop.ts`：`runTurn` 加 tool 子循环，最多 `MAX_TOOL_ROUNDS = 25` 轮；每轮把 `assistant` / `toolResult` 追加进 conversation，`uiToolCall { phase: "called" | "result" }` 通知 Shell。错误（未知工具 / 参数校验失败 / handler 抛错）一律转成 isError 的 ToolResultMessage 让模型自纠，不打断 turn。
- 新增 wire 方法 `ui.toolCall` 与对应 `UIToolCallParams`。
- 新单测：`tool-registry.test.ts`、`bash-tool.test.ts`、`agent-tool-loop.test.ts`（全 182 测试通过）。

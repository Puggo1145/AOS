# Agent Harness 开发指南

基于对 `playground/learn-claude-code` 12 个 section 的通读，抽取 agent runtime / harness 的上层骨架。本文只给出**架构分层、核心组件、设计思想与指回原项目的路标**，不包含完整实现。任何细节请直接读 learn-claude-code 对应的 `design docs/` 和 `code-examples/`。

## 0. 名词约定

| 术语 | 含义 |
|---|---|
| Harness | 包裹 LLM 的运行时外壳，负责 loop、工具调度、上下文、生命周期 |
| Agent loop | 驱动 LLM 反复「思考 → 工具调用 → 结果注入 → 再思考」的控制流 |
| Turn / round | 一次 LLM 调用 + 对应工具执行构成的一个循环回合 |
| Tool | 外部能力，LLM 以结构化参数调用，Harness 负责分发执行 |
| Tool dispatch | 把 `tool_name` 路由到具体 handler 的映射 |
| Subagent | 由主 agent 派生、拥有独立 `messages[]` 的一次性子 LLM 循环 |
| Teammate | 长期存活、有身份、通过消息总线协作的并行 agent |
| Task | 持久化到磁盘的目标单元，带状态与依赖边，可跨 session 存续 |
| Worktree | 与 task 绑定的独立执行目录（通常基于 `git worktree`） |

## 1. 源项目结构

learn-claude-code 是一本「百科式教程」。正文 = `design docs/`（markdown 解说 + ASCII 图 + 片段代码 + What Changed 表 + Try It 步骤），配套 `code-examples/`（每个 section 一份可运行 Python 脚本，独立自洽；`s_full.py` 是终态合集）。

12 个 section 的主题分层：

```
Foundation layer            Runtime layer              Coordination layer
----------------            -------------              ------------------
s01 agent loop              s07 task graph              s09 agent teams
s02 tool use                s08 background tasks        s10 team protocols
s03 todo / planning                                     s11 autonomous agents
s04 subagent                                            s12 worktree isolation
s05 skill loading
s06 context compact
```

指南的讨论顺序大体沿用这个分层：先把单 agent 的 loop、工具、上下文、规划打牢；再加持久任务与并发执行；最后讨论多 agent 协作与隔离。

细节索引：

- 教程正文：`playground/learn-claude-code/design docs/s01-the-agent-loop.md` … `s12-worktree-task-isolation.md`
- 可运行代码：`playground/learn-claude-code/code-examples/s01_agent_loop.py` … `s12_worktree_task_isolation.py`
- 终态聚合：`playground/learn-claude-code/code-examples/s_full.py`

## 2. Agent Loop：一切的内核

### 2.1 形态

Agent 的本质是一个 while 循环，由 `stop_reason` 决定何时退出：

```
+--------+      +-------+      +---------+
|  User  | ---> |  LLM  | ---> |  Tool   |
| prompt |      |       |      | execute |
+--------+      +---+---+      +----+----+
                    ^                |
                    |   tool_result  |
                    +----------------+
           loop until stop_reason != "tool_use"
```

核心语义：

- 一条 `messages[]` 累加序列：`user prompt → assistant(tool_use|text) → user(tool_result[]) → assistant … → assistant(text stop)`
- 退出条件：LLM 回包 `stop_reason != "tool_use"`（即没有发起新的工具调用）
- 每一轮：发送 `messages + tools` → 追加 assistant 回包 → 执行所有 `tool_use` block → 组装 `tool_result[]` 以 user 消息追加

这套模式是**所有上层能力的公共载体**。后续 section 加入的 tool、planning、compaction、subagent、team，都没有改变这个 loop 的控制形态，只是改变「工具集合、messages 内容、调度策略」。

### 2.2 AOS 落地形态

Sidecar (Bun/TS) 侧 runtime 的最核心 module 就是这个 loop。输入来自 Shell 通过 JSON-RPC 送入的 user prompt（含用户引用 context），输出通过 `ui.*` 通知向 Shell 流式推送。loop 本身应保持极薄 —— 一切扩展点通过「外部状态 + 可插拔 hooks」接入。

细节见 `playground/learn-claude-code/design docs/s01-the-agent-loop.md`、`code-examples/s01_agent_loop.py`。

## 3. Tool 系统：LLM 的手脚

### 3.1 结构

一个 tool 由三件事组成：

- **Schema**：`{name, description, input_schema}`，随 `tools=[...]` 参数下发给 LLM
- **Handler**：接收解析后的参数、返回字符串（或可序列化结构），是 harness 侧纯函数
- **Dispatch map**：`{tool_name: handler}`，loop 在 `tool_use` block 中按名字查表调用

```
+--------+      +-------+      +-----------------------+
|  User  | ---> |  LLM  | ---> | Tool Dispatch         |
| prompt |      |       |      |  bash  -> run_bash    |
+--------+      +---+---+      |  read  -> run_read    |
                    ^           |  write -> run_write  |
                    |           |  edit  -> run_edit   |
                    +-----------+  todo  -> ...        |
                                 +-----------------------+
```

**设计约束**：新增 tool = 加一条 schema + 加一个 handler。loop 从不为了加 tool 而改动。

### 3.2 分类

教程里的 tool 按角色分四类，AOS 需要各自对应：

| 类别 | 举例 | AOS 对应 |
|---|---|---|
| Filesystem | `read_file` / `write_file` / `edit_file` / `bash` | Sidecar 本地 FS + Shell 代理的系统能力 |
| Planning | `todo` / `task_*` | Sidecar 自管 |
| Knowledge | `load_skill` / `compact` | Sidecar 自管 |
| Concurrency | `background_run` / `task` (subagent) / `spawn` | Sidecar 自管 |
| Computer Use | — | Sidecar 声明 schema，真实执行由 Shell 通过 `computerUse.*` RPC 完成 |

Computer Use 这一类是 AOS 相对 learn-claude-code 的最大区别：tool 的 handler **不是本地函数**，而是对 Shell 的一次 RPC 请求。具体契约见 `docs/plans/rpc-protocol.md` 和 `docs/plans/computer-use.md`。

### 3.3 权限与安全

- 工具侧做边界检查（如 `safe_path` 限制不出工作区）
- 危险命令拦截（`rm -rf /`、`sudo` 等简单黑名单）
- 长输出截断（一般 `[:50000]`）防止单次 tool_result 就把 context 撑爆

真正的授权决策（是否允许执行此 tool）应提升到 harness 的 permission 层，见 §10。

细节见 `playground/learn-claude-code/design docs/s02-tool-use.md`、`code-examples/s02_tool_use.py`。

## 4. System Prompt 与指令分层

Harness 向 LLM 注入信息的通道是分层的，每一层寿命、成本、可见性不同：

```
Layer 0  —  model weights          (静态、不可变)
Layer 1  —  system prompt           (整个 session 常驻)
Layer 2  —  messages[]              (整个 session 累积)
Layer 3  —  tool_result (on demand) (按需注入，随压缩衰减)
Layer 4  —  injected reminders      (harness 在 user 消息中塞 <reminder>)
Layer 5  —  identity re-injection   (context 被压扁后补回身份)
```

原则：

- **System prompt 只放"名字"，不放"内容"**：skill 列表用 `- git: Git workflow helpers` 一行占位，完整 body 等 LLM 调 `load_skill("git")` 再通过 tool_result 注入
- **Reminder 走 user 消息**：在 `messages[-1].content` 最前面插 `<reminder>...</reminder>`，比改 system prompt 更及时、更不干扰缓存
- **Identity 可以重注入**：压缩后若 `len(messages) <= 3`，插入一对 `<identity>...</identity>` + assistant 确认，让子 agent / teammate 认得自己

相关讨论见 `design docs/s05-skill-loading.md`（Layer 1/3 分离）、`s11-autonomous-agents.md`（identity re-injection）。

## 5. Planning：TodoWrite 与 Task Graph

Agent 在多步任务上会漂移 —— 忘记步骤、重复劳动、跳过检查。Harness 给它两套规划工具，由轻到重：

### 5.1 TodoWrite（session 内轻量 checklist）

```
TodoManager state
[ ] task A
[>] task B  <- 唯一 in_progress
[x] task C

约束：同一时刻只允许一个 in_progress
助推：rounds_since_todo >= 3 时，在下一条 user 消息前插
     <reminder>Update your todos.</reminder>
```

特征：纯内存、一问一答、压缩即失效。适合「refactor this file」这种单 session 多步任务。

细节见 `design docs/s03-todo-write.md`、`code-examples/s03_todo_write.py`。

### 5.2 Task Graph（跨 session 持久任务）

每个 task 是一个 JSON 文件，带 `status`、`blockedBy`、`owner`、`worktree`：

```
.tasks/
  task_1.json  {"id":1, "status":"completed"}
  task_2.json  {"id":2, "blockedBy":[1], "status":"pending"}
  task_3.json  {"id":3, "blockedBy":[1], "status":"pending"}
  task_4.json  {"id":4, "blockedBy":[2,3], "status":"pending"}

    +---+           +---+
    | 1 |----+----->| 2 |----+
    +---+    |      +---+    |   +---+
             |               +-->| 4 |
             |      +---+    |   +---+
             +----->| 3 |----+
                    +---+

什么是 ready？  pending + blockedBy == []
什么是 done？   status == completed，触发全局清依赖
```

特征：落盘、跨压缩/重启存活、天然 DAG、支持并行与多 agent 协作。task graph 是后续 section（background、teams、worktree）的协调底盘。

细节见 `design docs/s07-task-system.md`、`code-examples/s07_task_system.py`。

## 6. Context Management：三层压缩

Context 窗口有限。单次 `read_file` 一千行就是 ~4k tokens；跑几十次工具就能填满 100k+。Harness 必须能**在不打断 agent 的情况下腾出空间**。

```
Every turn
   |
   v
[Layer 1: micro_compact]               silent，每轮都跑
   把 3 轮之前的 tool_result 正文
   替换为 "[Previous: used <name>]"
   |
   v
tokens > 50k ?
   | no                             | yes
   v                                 v
continue                   [Layer 2: auto_compact]
                              transcript dump 到 .transcripts/
                              调 LLM 生成 summary
                              messages[:] = [{role:user, content:<summary>}]
                              |
                              v
                       [Layer 3: manual compact tool]
                              模型主动调用，走同一份 summarization
```

三件事缺一不可：

- **micro_compact**：频繁但无害，只替换旧 tool_result 正文，保留 tool_use/tool_result 的配对关系
- **auto_compact**：阈值触发，transcript 先落盘（`.transcripts/transcript_<ts>.jsonl`）再压缩，**不丢任何历史**
- **manual compact tool**：给模型一个主动释放的通道（它自己知道什么时候讲完了一段落）

关键设计决定：

- 压缩出来的 summary 必须还原为一条 user message，格式 `[Compressed]\n\n<summary>`，让下一轮 LLM 认得这是历史
- transcripts 是持久真相源，可用于事后 replay、审计、session 恢复
- 身份、skill 列表、todo 这类「永远有用」的信息，要么放 system prompt，要么在压缩后通过 identity re-injection 补回，不依赖 summary

细节见 `design docs/s06-context-compact.md`、`code-examples/s06_context_compact.py`。

## 7. Sub-agent：上下文隔离

主 agent 的 context 会被探索性工作污染 —— 为了回答「这个项目用什么测试框架」要读 5 个文件，结果这 5 个文件全部挤进主对话。解法是 `task` 工具，派生一个一次性子 agent：

```
Parent agent                     Subagent
+------------------+             +------------------+
| messages=[...]   |             | messages=[]      | <-- 全新
|                  |  dispatch   |                  |
| tool: task       | ----------> | while tool_use:  |
|   prompt="..."   |             |   call tools     |
|                  |  summary    |   append results |
|   result = "..." | <---------- | return last text |
+------------------+             +------------------+
```

核心约束：

- 子 agent 的 `messages[]` 不与父共享
- 子 agent 的 tool 集合里**不含 `task`**，禁止递归派生（防止失控膨胀）
- 返回值只有最后一轮的文本输出，当作一次普通 `tool_result` 回到父
- 加 safety limit（如 30 轮）防止死循环

适用场景：搜索、探索、问答、子目标完成后只关心结论。不适合需要逐步向用户展示过程的工作 —— 那种应该留在主 loop。

细节见 `design docs/s04-subagent.md`、`code-examples/s04_subagent.py`。

## 8. Skill：按需加载的领域知识

Skill = 一段「当 agent 需要做某类任务时应该先读的 playbook」。

```
Layer 1 (system prompt，一直在，~100 tokens/skill):
  Skills available:
    - git: Git workflow helpers
    - code-review: Review code before merge
    - mcp-builder: Build MCP servers

Layer 3 (tool_result，按需，~2000 tokens/skill):
  当 LLM 调 load_skill("git")，harness 返回：
  <skill name="git">
    Full git workflow instructions...
  </skill>
```

结构：每个 skill 是一个目录，含 `SKILL.md`，YAML frontmatter 里写 `name` + `description`，body 是完整说明。`SkillLoader` 启动时 `rglob("SKILL.md")` 扫出全部，description 拼到 system prompt，body 等 `load_skill` 调用再发。

AOS 的对应：Sidecar 启动时扫 `~/.aos/skills/` 目录（按 AOS 数据布局约定），同样做 Layer 1 / Layer 3 分层注入。macOS 原生操作、app 专用交互 pattern（如 Safari / Notes / Mail 的惯用写入方式）都适合做成 skill。

细节见 `design docs/s05-skill-loading.md`、`code-examples/s05_skill_loading.py`。

## 9. 并发执行：后台任务与 Teammate

单 loop 是串行的。Harness 有两种并发引入方式，语义不同：

### 9.1 Background tasks（并行**工具**）

```
Main thread                Background thread
+-----------------+        +-----------------+
| agent loop      |        | subprocess runs |
| ...             |        | ...             |
| [LLM call] <----+--------| enqueue(result) |
|  ^drain queue   |        +-----------------+
+-----------------+
```

- 每个 LLM 调用前 `drain_notifications()`，把完成的后台命令结果以
  `<background-results>\n[bg:id] output\n</background-results>`
  注入一条 user 消息
- daemon thread 做真正的 subprocess，main loop 从不阻塞
- 适合耗时 shell 操作（`npm install`、`pytest`、`docker build`）

细节见 `design docs/s08-background-tasks.md`、`code-examples/s08_background_tasks.py`。

### 9.2 Agent teams（并行**agent**）

```
.team/
  config.json           <- 团队名册 + 每人 status
  inbox/
    alice.jsonl         <- append-only 邮箱，读即清空
    bob.jsonl
    lead.jsonl

          +--------+    send("alice","bob","...")    +--------+
          | alice  | -----------------------------> |  bob   |
          | loop   |    bob.jsonl << {json_line}    |  loop  |
          +--------+                                +--------+
               ^                                         |
               |        BUS.read_inbox("alice")          |
               +---- alice.jsonl -> read + drain ---------+
```

- `spawn(name, role, prompt)` 创建持久 teammate，在新线程里跑一个自己的 agent loop
- MessageBus：append-only JSONL 邮箱，`read_inbox` 返回全部后清空（drain-on-read）
- 每个 teammate 在调 LLM 前先读自己的 inbox，把内容注入为
  `<inbox>...</inbox>` user 消息
- 身份持久：有 name、role、status（working/idle/shutdown）

Subagent (§7) 是**一次性的**，teammate 是**持续存在的**。区分清楚。

细节见 `design docs/s09-agent-teams.md`、`code-examples/s09_agent_teams.py`。

## 10. Team 协议：结构化握手

teammate 之间的高风险交互不能只靠自由文本，需要 request-response 协议，保证关键动作可追踪、可拒绝。

```
Shutdown Protocol            Plan Approval Protocol
==================           ======================

Lead             Teammate    Teammate           Lead
  |                 |           |                 |
  |--shutdown_req-->|           |--plan_req------>|
  | {req_id:"abc"}  |           | {req_id:"xyz"}  |
  |                 |           |                 |
  |<--shutdown_resp-|           |<--plan_resp-----|
  | {req_id,        |           | {req_id,        |
  |  approve:true}  |           |  approve:true}  |

共享 FSM：
  [pending] --approve--> [approved]
  [pending] --reject---> [rejected]

Trackers:
  shutdown_requests = {req_id: {target, status}}
  plan_requests     = {req_id: {from, plan, status}}
```

同一个 FSM 复用到：

- **优雅关停**：lead 请求 shutdown，teammate 可拒绝（如"让我把手头这个写完"）
- **高风险计划审批**：teammate 提交 plan，lead 决定是否放行执行

都是 `request_id` 关联 + `pending → approved|rejected` 三态机。扩展新协议只要复用这个模板。

细节见 `design docs/s10-team-protocols.md`、`code-examples/s10_team_protocols.py`。

## 11. 自主化：任务板 + 空闲轮询

让 teammate 自己找活干，而不是 lead 手动派发。

```
+-------+
| spawn |
+---+---+
    |
    v
+-------+   tool_use     +-------+
| WORK  | <------------- |  LLM  |
+---+---+                +-------+
    |
    | stop_reason != tool_use (或模型主动调 idle)
    v
+--------+
|  IDLE  |  poll every 5s for up to 60s
+---+----+
    |
    +---> read inbox         --> 有消息      --> WORK
    |
    +---> scan .tasks/       --> 有 unclaimed --> claim -> WORK
    |
    +---> 60s timeout                         --> SHUTDOWN
```

idle 循环做两件事：

- 看收件箱（lead 是否派活）
- 扫任务板（`scan_unclaimed_tasks()`：`pending + no owner + no blockedBy`）

并且在 idle 恢复时检查 `len(messages) <= 3`，如果是（压缩过了），先插回 identity block 再继续（见 §4）。

细节见 `design docs/s11-autonomous-agents.md`、`code-examples/s11_autonomous_agents.py`。

## 12. Worktree 隔离：执行平面

多个 agent 并行干活如果共享一个工作目录，必然相互踩踏。解法：task 管「做什么」，worktree 管「在哪里做」，按 task_id 绑定。

```
Control plane (.tasks/)           Execution plane (.worktrees/)
+------------------+              +------------------------+
| task_1.json      |              | auth-refactor/         |
|  status: in_prog <--------->    | branch: wt/auth-refactor
|  worktree: "..."        |       | task_id: 1             |
+------------------+              +------------------------+
| task_2.json      |              | ui-login/              |
|  status: pending <--------->    | branch: wt/ui-login
|  worktree: "..."        |       | task_id: 2             |
+------------------+              +------------------------+
                                  |
                          index.json (worktree registry)
                          events.jsonl (lifecycle log)

State machines:
  Task:     pending -> in_progress -> completed
  Worktree: absent  -> active      -> removed | kept
```

关键契约：

- `worktree_create(name, task_id=N)` 在 `.worktrees/<name>` 里 `git worktree add -b wt/<name> HEAD`，并把 task 的 `worktree` 字段写上、把 status 从 pending 提为 in_progress
- 所有后续 shell / 工具调用都以该 worktree 为 `cwd`
- `worktree_remove(name, complete_task=True)` 一步到位：删目录 + 置 task completed + 发 event
- 全过程写 `events.jsonl`：`worktree.create.before/after/failed`、`worktree.remove.*`、`worktree.keep`、`task.completed`
- 对话内存是易失的，**文件状态是真相源**。崩溃后靠 `.tasks/` + `.worktrees/index.json` 完整重建

细节见 `design docs/s12-worktree-task-isolation.md`、`code-examples/s12_worktree_task_isolation.py`。

## 13. Hooks / Lifecycle Events

learn-claude-code 没有抽象成统一的 hook 框架，但可以归纳出 harness 需要预留的切点：

| 切点 | 用途 | 在 learn-claude-code 的痕迹 |
|---|---|---|
| `before_llm_call(messages)` | 压缩、reminder 注入、inbox drain、背景结果 drain | s06 micro_compact、s03 reminder、s08 drain_notifications、s09 read_inbox |
| `after_llm_response(response)` | 记录 stop_reason、token 计数、trigger auto_compact | s06 `estimate_tokens(messages) > THRESHOLD` |
| `before_tool_exec(name, args)` | permission 检查、危险命令拦截、路径沙箱 | s01 dangerous 黑名单、s02 `safe_path` |
| `after_tool_exec(name, result)` | 截断、日志、事件广播 | `output[:50000]`，s12 `events.emit(...)` |
| `on_subagent_spawn / on_teammate_spawn` | 绑定身份、日志 | s04 / s09 |
| `on_task_status_change` | 触发 worktree teardown、广播到 lead | s12 `task.completed` |
| `on_idle / on_shutdown` | 归还资源、持久化状态 | s11 idle poll、s10 shutdown handshake |

AOS 在 Sidecar 端应把这些切点显式化，不要散落在 loop 代码里。外围扩展（日志、trace、UI 流式）全部靠订阅这些事件实现。

## 14. Memory / 持久化

learn-claude-code 的持久化策略一致而朴素 —— **每个关注点一个目录，每个单位一个文件**：

```
.transcripts/transcript_<ts>.jsonl   # 压缩前全历史
.tasks/task_<id>.json                # 任务单元
.worktrees/index.json                # 执行平面注册表
.worktrees/events.jsonl              # 生命周期事件流
.team/config.json                    # 团队名册
.team/inbox/<name>.jsonl             # 每人邮箱
skills/<name>/SKILL.md               # 领域知识
```

为什么是文件而不是数据库：

- 人手工可查、可编辑、可 diff
- agent 本身就擅长操作文件
- 崩溃 / 重启后无需 schema migration
- 备份 / sync（iCloud、rsync）天然

AOS 的对应：所有 agent 运行时状态写 `~/.aos/`（参见 tech stack 约定），保持同样的「目录即 namespace，文件即单位」的组织方式。

## 15. Session 管理

一个 AOS 会话的生命周期在 Sidecar 侧大致是：

```
session start
  |
  v
load ambient state
  (skill list, task graph, team roster, transcripts 索引)
  |
  v
  +----- agent loop (§2) ----+
  |                           |
  | 每轮：                     |
  |   drain background (§9.1) |
  |   drain inbox (§9.2)     |
  |   micro_compact (§6)      |
  |   check tokens            |
  |   LLM call                |
  |   before_tool_exec (§13)  |
  |   tool dispatch (§3)      |
  |   after_tool_exec (§13)   |
  |                           |
  +-- stop_reason == end_turn-+
        |
        v
    idle / shutdown (§11)
```

- Session 间的连续性靠**文件**承载：transcripts、task graph、team config
- 崩溃恢复 = 重读这些文件 + identity re-injection
- 压缩是 session 内的优化，不是跨 session 的手段（跨 session 依赖 task graph + skill）

## 16. Streaming 与中断（Cancellation）

learn-claude-code 为了教学清晰，用的是 non-streaming `messages.create`，没有涉及流式输出与中断。但 AOS 是面向用户交互的产品，必须补齐。落地要点：

- 用 Anthropic SDK 的 `messages.stream()` 或等价能力，得到 chunk 流
- harness 对 chunk 做两件事：
  - 转发到 Shell（`ui.*` RPC 通知，见 `docs/plans/rpc-protocol.md`）
  - 在本地 buffer 里重建完整 `response.content` 以便 append 到 `messages[]`
- **中断**：Shell 通过 RPC 发 `agent.cancel`，sidecar 关掉当前流的 reader，把已生成的部分作为 assistant 消息落地（保持 loop 不变形），然后退出本轮
- **工具中断**：执行中的 tool（尤其 computerUse、background subprocess）必须支持 cancel —— worktree / subprocess 用 kill，computerUse 走 Shell 侧的取消 RPC

这套 streaming + cancel 不是 learn-claude-code 的主题，但是 AOS 的必做项，设计时预留 hook：`on_llm_chunk`、`on_cancel`。

## 17. MCP 与外部工具协议

learn-claude-code 在 s05 的 skill 样例中提及 `mcp-builder` 这个 skill，但 section 主体不涉及 MCP 协议本身。原则上：

- MCP server 暴露的 tool 可以直接挂接到 §3 的 dispatch map 里（MCP client 作为 adapter，把 MCP tool schema 翻译成 LLM tools 声明，把 LLM tool_use 翻译成 MCP 调用）
- MCP 在 AOS 里是**外部工具接入渠道**，与 Sidecar 自己实现的工具（filesystem、planning、computerUse 代理）并列
- MCP 不承担 Shell ↔ Sidecar 的内部通信（那是 JSON-RPC 的事）

具体接入设计不在本指南范围，参考 `modelcontextprotocol.io` 与 AOS 后续的 MCP 集成计划。

## 18. AOS 建议落地顺序

按依赖关系分阶段。每阶段都是**可运行、可自测的最小 runtime**，不要跳阶段。

### 阶段 A：单 agent 内核（对齐 s01 + s02）

1. **Agent loop v0**：在 Sidecar 跑起来一个 `while stop_reason == "tool_use"` 循环，system prompt 写死，tools 只挂一个 `bash`。
2. **Tool dispatch 框架**：抽出 `{schema, handler}` + `dispatch map`。加入 `read_file` / `write_file` / `edit_file`，带 `safe_path` 沙箱。
3. **Shell ↔ Sidecar 打通**：`agent.submit` 进来、`ui.stream` / `ui.done` 出去。保证 Shell 能渲染 assistant 文本。

产出：Sidecar 能独立完成纯文件任务，Shell 能正确渲染一轮对话。

### 阶段 B：流式与中断（超出 learn-claude-code 但必须先做）

4. **Streaming**：改 non-stream 为 stream，把 chunk 按 `ui.stream` 推到 Shell。
5. **Cancellation**：接入 `agent.cancel`，loop 能干净收尾。
6. **Hooks 骨架**：把 §13 里那几个 before/after 切点变成显式函数表，后续所有扩展都挂在这里。

产出：用户体验达到"能用"门槛。

### 阶段 C：规划与上下文（对齐 s03 + s06）

7. **TodoWrite**：内存 TodoManager + nag reminder。面向单 session 任务。
8. **micro_compact**：每轮前替换旧 tool_result。零成本、无感。
9. **auto_compact + transcripts**：阈值触发，dump 到 `~/.aos/transcripts/`，summary 还回 messages。
10. **manual compact tool**。

产出：长会话不崩、token 预算可控。

### 阶段 D：领域知识与子任务（对齐 s04 + s05）

11. **Skill loader**：`~/.aos/skills/<name>/SKILL.md`，Layer 1 描述 + Layer 3 按需注入。把第一批 macOS app skill（Notes / Mail / Calendar 写入模式）做出来。
12. **Subagent (`task` tool)**：独立 `messages[]`、禁递归、只回文本。

产出：agent 具备领域化工作能力，主对话不被探索污染。

### 阶段 E：Computer Use 工具化（AOS 自己的事）

13. **把 AOSComputerUseKit 接入 tool dispatch**：tool schema 在 Sidecar 声明，handler 发 `computerUse.*` RPC 到 Shell，Shell 走 Accessibility + CGEvent。
14. **权限 prompt**：tool 执行前通过 `ui.*` 请求用户确认，高敏感操作走人机回路。

产出：agent 能操作真实 macOS app，读写闭环。

### 阶段 F：持久任务 + 并发（对齐 s07 + s08）

15. **Task graph**：`~/.aos/tasks/task_<id>.json`，`blockedBy` / `owner` / `worktree` 字段齐全。工具 `task_create/update/list/get`。
16. **Background tasks**：耗时 shell 操作派生 daemon 线程，notification queue drain 到 user 消息。

产出：跨 session 目标可留存，长耗时操作不再卡 loop。

### 阶段 G：多 agent 协作（对齐 s09 + s10 + s11）

17. **Teammate + MessageBus**：`~/.aos/team/` 下 config + JSONL inbox。每个 teammate 自跑 agent loop。
18. **Shutdown / plan approval 协议**：request-response + FSM。
19. **Autonomous idle loop**：空闲时扫 task board + 收件箱，identity re-injection。

产出：AOS 可以是团队，不只是单体。

### 阶段 H：执行隔离（对齐 s12）

20. **Worktree manager**：`~/.aos/worktrees/` + `git worktree` 绑定 task_id。`events.jsonl` 事件流。

产出：多 agent 并行不再互踩。

### 阶段 I：外部协议

21. **MCP client adapter**：把外部 MCP server 的 tool 接入 dispatch map。

产出：AOS agent 能复用生态工具。

---

阶段之间有依赖方向：B 必须先于任何用户可感的阶段；C 在 D 之前（skill 会拉 context，必须先有压缩）；E 可以与 D 并行；F 是 G/H 的前提；I 可以随时插队但不紧迫。

每个阶段结束都应该有一套对应的端到端脚本（模仿 learn-claude-code 的 `Try It` 段落），直接驱动 Sidecar，不经过 Shell，用来防回归。

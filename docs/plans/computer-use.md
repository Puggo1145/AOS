# Computer Use 实现方案

## 目标

为 AOS 提供**不抢前台焦点**的 macOS 应用操作能力。Agent 能够在用户正常使用电脑的同时，于后台读取目标 app 的 UI 状态并执行点击、输入、拖拽、快捷键等操作。

非目标（本阶段不做）：
- 跨平台（Linux / Windows）
- 视觉模型驱动的元素检测
- 沙盒 / 受 SIP 保护 app 的操作

## 技术选型（已锁定）

| 维度 | 决策 | 理由 |
|---|---|---|
| 实现语言 | Swift 6.2+ | macOS 原生 API 仅此可用 |
| 打包形态 | SwiftPM package | 无需 Xcode 工程，与 AOS shell 架构一致 |
| 屏幕捕获 | ScreenCaptureKit (`SCStream`) | 可抓非前台窗口，按 pid + window title 定位 |
| 事件投递 | `CGEvent.postToPid(pid)` 为主 | 定向进程投递不触发前台切换，已被官方 Codex Computer Use 验证 |
| 元素定位 | Accessibility API (AX) 为主 | 语义化、稳定、不依赖坐标；无 AX 时才回退坐标 |
| 对外接口 | in-process Swift API，通过 Shell RPC Dispatcher 暴露为 `computerUse.*` JSON-RPC 方法 | 与 OS Sense 共用 Shell 进程，权限与签名统一 |
| 权限模型 | Accessibility + Screen Recording | 运行时动态请求，无 entitlements |

参考实现：`playground/open-codex-computer-use`（READ-ONLY）。核心路径在 `packages/OpenComputerUseKit`。

## 模块结构

```
packages/
  AOSComputerUseKit/              # Swift package，核心能力库
    Sources/AOSComputerUseKit/
      ComputerUseService.swift    # 对外门面，编排所有操作
      InputSimulation.swift       # CGEvent 定向投递：click/drag/type/key
      AccessibilitySnapshot.swift # AX 树遍历 + SCStream 截图
      TreeRenderer.swift          # AX 树 → 文本序列化
      StateCache.swift            # AX snapshot stateId 缓存（TTL 30s）
      Permissions.swift           # Accessibility / ScreenRecording 校验
    Tests/AOSComputerUseKitTests/
```

**单一 Swift package，不输出独立可执行**。AOS Shell 直接作为依赖链接，通过 `ComputerUseService` public API 调用。

Kit 的单一职责：接收参数 → 操作 macOS → 返回结构化结果。不感知 JSON-RPC、Bun、agent loop。对外暴露由 Shell 侧 handler 承担。

## 核心实现

### 操作降级链路（点击 / 拖拽 / 输入均遵循）

执行顺序固定，前一级失败则进入下一级：

1. **AX 语义动作**  
   `AXUIElementPerformAction` 调用目标元素的 `AXPress` / `AXConfirm` / `AXOpen` / `AXShowMenu` 等动作。  
   适用：按钮、菜单项、checkbox、标准 control。

2. **AX 属性修改**  
   设置 `kAXMainAttribute` / `kAXFocusedAttribute` / `kAXSelectedAttribute` 等属性。  
   适用：窗口激活、焦点切换、选中状态变更。

3. **定向事件投递**  
   `CGEvent.postToPid(pid)` 向目标进程直投鼠标 / 键盘事件。坐标先由 screenshot pixel → window point 换算，再 `AXUIElementCopyElementAtPosition` 做 hit-test 校准。  
   适用：canvas、webview、第三方自绘控件，或 AX 动作不生效的场景。

4. **禁止全局 `CGEventPost`**  
   不提供全局 HID 事件投递。前三层都失败时直接返回错误，由 agent 决定如何处理。

键盘输入（`typeText`）跳过 1、2，直接用 `CGEvent.postToPid(pid)` 逐字符投递 Unicode keyDown/keyUp 事件。

### 屏幕与元素感知

**截图**：`SCStream` + `SCContentFilter(desktopIndependentWindow:)`。由 `CGWindowListCopyWindowInfo` 枚举目标 pid 的 on-screen windows，按 title hint 优先匹配，其次最大窗口。返回 PNG 二进制。

**AX 树**：从目标 app 的 `AXUIElementCreateApplication(pid)` 开始遍历。限制：最多 500 个元素、最深 16 层。每个元素输出一行文本：

```
<index> <role> "<title>" (<traits>) <description> [actions: AXPress,AXShowMenu]
```

截图与 AX 树同时返回给 agent。不做 OCR、不做视觉元素检测。

### AX 快照生命周期

`getAppState` 返回的 AX 树中每个元素带一个 `elementIndex`。后续 `click` 使用 `elementIndex` 的前提是提供 `stateId` 绑定到一次 snapshot：

- `getAppState(pid)` 执行完整 AX 遍历后，在 `StateCache` 中保存 `{stateId → [AXUIElement]}`，分配 UUID `stateId`，TTL 30s
- `click { pid, stateId, elementIndex }` 先 `StateCache.lookup(stateId)`：
  - stateId 不存在或已过期 → 返回 `ErrStateStale`
  - 校验目标元素的 `pid` 与请求 `pid` 一致、元素仍然 valid（`AXUIElementCopyAttributeValue` 可响应）→ 进入操作降级链路
  - app 窗口结构已显著变化（元素 invalid）→ 返回 `ErrStateStale`
- `click { pid, x, y }` 不依赖 stateId，每次独立 hit-test
- `StateCache` 不做 LRU；TTL 到期或显式 invalidate 时释放
- Agent 在 `ErrStateStale` 后必须重新 `getAppState` 才能继续语义化点击

### RPC 方法（暴露给 Bun）

Shell 的 `ComputerUseHandlers.swift` 把 Kit 的 public API 包装为 `computerUse.*` JSON-RPC 方法。完整 params / result / 错误码清单见 `rpc-protocol.md`。方法一览：

- `computerUse.listApps` — 枚举可操作的 on-screen app
- `computerUse.getAppState` — 返回 `{ stateId, axTree, screenshot }`，不切焦点，stateId TTL 30s
- `computerUse.click` — `{ pid, stateId, elementIndex }`（语义化）或 `{ pid, x, y }`（坐标）
- `computerUse.drag` — 起止坐标拖拽
- `computerUse.typeText` — Unicode 文本输入
- `computerUse.pressKey` — 快捷键组合
- `computerUse.scroll` — 滚轮事件
- `computerUse.doctor` — 返回 `{ accessibility, screenRecording, automation }` 权限状态

Bun 侧 tool registry 按 LLM provider 格式生成 tool schema，描述中明确声明"all tools operate in background without stealing focus"供 agent planner 参考。底层统一 `rpc.call("computerUse.xxx", params)`。

## 权限

运行时校验两类权限：

- **Accessibility**：`AXIsProcessTrusted()`
- **Screen Recording**：`CGPreflightScreenCaptureAccess()`

任一缺失时，AOS shell 调起权限引导 UI（不在本 package 内，属于 shell 层）。`doctor` 方法返回 `{ accessibility, screenRecording, automation }` 三项结构化状态；`automation` 字段反映 OS Sense 的 Finder adapter 状态，Computer Use 本身不使用 Automation 权限。

**不读 TCC.db**。仅以系统 API 返回的权限状态为准。

## 与 AOS 主进程的集成

```
┌────────────────────────────────────┐
│  AOS Shell (Swift, parent)         │
│  ┌──────────────────────────────┐  │
│  │  RPC Dispatcher              │  │
│  │  └─ ComputerUseHandlers      │  │
│  ├──────────────────────────────┤  │
│  │  AOSComputerUseKit (linked)  │  │  ← in-process 函数调用
│  └──────────────────────────────┘  │
└─────────────┬──────────────────────┘
              │ spawns + stdio JSON-RPC
              ▼
┌────────────────────────────────────┐
│  Bun Sidecar (TS)                  │
│  Agent → tool impl                 │
│       → rpc.call("computerUse.*")  │
└────────────────────────────────────┘
```

- Kit 作为 Swift 依赖直接链接进 Shell，无独立子进程
- Bun 通过 Shell↔Bun 的 JSON-RPC 通道发起 `computerUse.*` 请求
- Shell 的 `ComputerUseHandlers` 每个请求在独立 Swift Task 里 async 调用 Kit 方法，handler 之间互不阻塞
- 每 method 的 timeout 和并发模型由 `rpc-protocol.md` 统一定义
- Kit 内部的四层降级链路对 Bun 透明

## 实现阶段

### Stage 1：Kit 核心（可独立验证）
- `AOSComputerUseKit` 完整实现 `ComputerUseService` + `InputSimulation` + `AccessibilitySnapshot` + `Permissions`
- Swift Testing 单元测试覆盖 AX 树序列化、坐标换算、权限状态判定
- 对 TextEdit、Finder、Safari 做 fixture-based smoke test（基于真实 app 截图 + AX 快照做断言）

### Stage 2：Shell RPC handlers
- `ComputerUseHandlers.swift` 实现 8 个 `computerUse.*` method 的 async handler
- `AOSRPCSchema` 定义各 method 的 params / result Codable 类型，`sidecar/src/rpc-types.ts` 手写对应 TS 类型，fixture conformance test 保证一致
- `StateCache` 实现 + stateId 生命周期校验
- `ComputerUseHandlers` 集成 per-method timeout（见 rpc-protocol.md）
- Bun 侧 tool registry 按 LLM provider 格式包装 tool，execute 走 RPC client
- e2e 测试：从 Bun 发起 `rpc.call("computerUse.click", ...)` 到 Kit 真实点击的完整链路

### Stage 3：覆盖率验证
- 在 Notion、Figma、Linear、VS Code、Chrome 上跑一轮固定 scenario（打开文档、点击按钮、输入文本、切换 tab）
- 记录每个 app 的成功率

### Stage 4：shell 集成
- Shell 的权限引导流（Accessibility / Screen Recording）完整串联 Kit 的 `Permissions` 校验
- Bun 在 agent 调用 Computer Use 前通过 `computerUse.doctor` 做前置自检，权限缺失直接给用户反馈而不是 tool 失败
- Notch UI 增加"正在后台操作 X app"的状态指示（由 Bun 的 `ui.status` 驱动）

## 验证标准

Stage 1 完成判定：
- 能对 TextEdit 后台完成"打开新文档 → 输入文本 → 保存"的完整链路，过程中前台 app 始终不变
- `ComputerUseService.getAppState(...)` 调用前后 `NSWorkspace.frontmostApplication` 不变
- 所有操作路径无 `CGEventPost(tap: .cghidEventTap)` 调用（grep 校验）

Stage 2 完成判定：
- Bun 侧 `rpc.call("computerUse.click", ...)` 端到端能触发 Kit 点击并返回结构化结果
- conformance test（Swift + TS 两侧 fixture roundtrip）全部 byte-equal
- stateId 过期场景返回 `ErrStateStale`（-32100）
- 操作全部失败场景返回 `ErrOperationFailed`（-32101）附带四层状态
- screenshot 超 1MB base64 返回 `ErrPayloadTooLarge`（-32001）
- 注入延迟超过 method timeout 返回 `ErrTimeout`（-32002）

Stage 3 完成判定：
- 在 5 个目标 app 上固定 scenario 的综合成功率 ≥ 80%
- 失败路径均由 agent 收到明确错误码，无静默失败

## 已知风险

| 风险 | 缓解 |
|---|---|
| 第三方 app AX 暴露度差异大 | Stage 3 显式测量各 app 成功率 |
| ScreenCaptureKit 在某些 app（全屏游戏、DRM 内容）会黑屏 | `doctor` 工具返回截图是否有效 |
| macOS 版本升级后 TCC / AX 行为变化 | `Permissions` 模块做版本探测，不依赖私有 API |
| `CGEvent.postToPid` 对需要 global modifier state 的快捷键有限制 | 快捷键通过 AX `AXMenuItemCmdChar` 系列属性优先触发，而非合成事件 |
| `StateCache` 内存占用随 stateId 数量增长 | TTL 30s 自动释放；单 pid 仅保留最新 stateId，新 `getAppState` 覆盖旧缓存 |
| App 窗口状态在 stateId TTL 内变化导致 elementIndex 错位 | Click 前校验目标 AXUIElement 仍 valid，否则返 `ErrStateStale` |

## 不做的事

- 不做全局 `CGEventPost` fallback
- 不读 TCC.db
- 不做 element detection / OCR
- 不做跨平台抽象层
- 不做操作录制回放
- 不输出独立 MCP 进程

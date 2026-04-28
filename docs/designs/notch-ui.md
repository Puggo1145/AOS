# Notch UI 设计

## 目标

定义 AOS Shell 的 Notch UI 视觉与交互契约。这一层是用户与 agent 的唯一入口：

- 提供 closed / popping / opened 三态视觉，绑定到屏幕物理刘海
- 闭合态显示前台 app icon 与 agent 状态颜文字，作为「agent 在线感」的最小持续表达
- 展开态作为 prompt 输入面板，承载 context chip 选取、流式 assistant 文本与状态指示
- 与 `AOSOSSenseKit.SenseStore.context` 单向绑定（live mirror），与 `AgentService` 双向绑定（事件 + submit）

## 非目标

- 不做拖拽接收 (drop)
- 不做 settings / preferences UI
- 不做对话历史（current turn 之外的内容不持久化、不渲染）
- 不做 Spotlight 风格命令调色板
- 不做键盘快捷键唤起（本轮仅 hover / click 入口）
- 不做多面板同时显示（同一时刻最多一个 NotchWindow）

## 状态机

参考 `docs/guide/notch-dev-guide.md` §4 的 closed / popping / opened 三态范式，AOS 收敛如下：

```
closed ──hover into hot rect──▶ popping ──click in hot rect──▶ opened
   ▲                                │                            │
   │                          leave hot rect                     │
   │                          (mouseLocation outside)            │
   │◀───────────────────────────────┘                            │
   │                                                              │
   └─── click outside notchOpenedRect / click in deviceNotchRect ─┘
   └─── ESC keyDown when window is key                            │
   └─── window resignKey (focus loss)                            ─┘
```

| 触发 | from | to | 触发源 |
|---|---|---|---|
| 鼠标进入 `deviceNotchRect.insetBy(inset)` | closed | popping | global+local `mouseMoved` |
| 鼠标离开同一矩形 | popping | closed | 同上 |
| `leftMouseDown` 落在 `deviceNotchRect.insetBy(inset)` | closed / popping | opened | global+local `mouseDown` |
| `leftMouseDown` 落在 `notchOpenedRect` 之外 | opened | closed | 同上 |
| `leftMouseDown` 落在 `deviceNotchRect.insetBy(inset)` | opened | closed | 等价于「再点一次刘海收起」 |
| `keyDown` 是 `ESC` | opened | closed | local `keyDown` monitor，且 `AgentService.cancel()` 同时调用 |
| `NSWindow.resignKey` | opened | closed | window 注册 delegate |

`opened` 期间 `popping` 通道不再生效。`popping` 不会自动升 `opened`，必须显式 click。

`closed → popping` 与 `popping → closed` 由 `NotchViewModel.notchPop()` / `notchClose()` 串行化（@MainActor），确保单一写者。

## 几何

唯一真值来源：`NSScreen` 的 `safeAreaInsets` + `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`（参见 `docs/guide/notch-dev-guide.md` §2.1）。`NotchViewModel` 持有以下 published 属性：

```swift
@Published var screenRect: CGRect          // 当前 NSScreen.frame
@Published var deviceNotchRect: CGRect     // 物理刘海 origin/size
let panelSize = CGSize(width: 720, height: 240)
let inset: CGFloat                         // 有刘海 -4，无刘海 0
```

派生 rect 全部计算性质，不缓存：

```swift
var notchOpenedRect: CGRect {
    .init(
        x: screenRect.midX - panelSize.width / 2,
        y: screenRect.maxY - panelSize.height,
        width: panelSize.width,
        height: panelSize.height
    )
}

var headlineOpenedRect: CGRect {
    // 展开态顶部对齐物理刘海高度的「头部条」，宽度跟随 panel
    .init(
        x: notchOpenedRect.minX,
        y: screenRect.maxY - deviceNotchRect.height,
        width: panelSize.width,
        height: deviceNotchRect.height
    )
}

var closedBarRect: CGRect {
    // 整条 closed bar 与 deviceNotchRect 同高，宽度 = 刘海宽度 + 两侧方块
    .init(
        x: deviceNotchRect.minX - deviceNotchRect.height,
        y: deviceNotchRect.minY,
        width: deviceNotchRect.width + deviceNotchRect.height * 2,
        height: deviceNotchRect.height
    )
}
```

NotchWindow 自身覆盖屏幕顶部一整条（高度 = `panelSize.height`），SwiftUI 内部按上述派生 rect 摆放。窗口 frame 不随状态变化——状态切换只动 SwiftUI 内层。

## 三态布局详细规格

### closed

视觉为一条贴着物理刘海的「卫星 bar」：

```
┌────────────┬────────────────┬────────────┐
│  app icon  │  device notch  │  emoji txt │
│  (h × h)   │  (notchW × h)  │  (h × h)   │
└────────────┴────────────────┴────────────┘
   ↑                                ↑
   左方块：deviceNotchRect.height 等边正方形
           内容 = SenseStore.context.app.icon
   右方块：同等正方形
           内容 = AgentStatus → 颜文字 (字号 = h × 0.55，等宽字体)
```

| 区域 | 尺寸 | 渲染 |
|---|---|---|
| 左方块 | `h × h`（h = `deviceNotchRect.height`） | `AppIconView` 绑定 `SenseStore.context.app.icon`；圆角 = h/4；padding 4pt |
| 中段 | `notchW × h` | 纯黑 `Color.black`；shape 沿用 `NotchShape`（外凸圆角 → 内凹过渡，参见 `docs/guide/notch-dev-guide.md` §6） |
| 右方块 | `h × h` | `StatusEmojiView` 绑定 `AgentService.status`；与左方块对称；颜文字水平/垂直居中 |

整条 bar 的 cornerRadius：左方块右下、右方块左下与中段过渡圆角 = `h / 6`，与 NotchShape 的"反向圆弧"挖剪在同一 `compositingGroup` 内完成。

### popping

不切换布局内容。在 closed 基线上做几何与缩放微调：

| 字段 | closed | popping |
|---|---|---|
| 整体 scale | 1.0 | 1.04 |
| 中段高度 | `h` | `h + 4` |
| cornerRadius | `h / 6` | `h / 6 + 2` |

动画：`Animation.interactiveSpring(duration: 0.5, extraBounce: 0.25, blendDuration: 0.125)`，与 NotchDrop 风格一致。`hapticSender` 在进入 `popping` 时发一次 `.levelChange`，throttle 0.5s（参见 `docs/guide/notch-dev-guide.md` §7.4）。

### opened

panel 尺寸固定 720 × 240，cornerRadius 32。布局：

```
┌──────────────────────────────────────────────────────────────┐
│  ┌───────────┐   ┌──────────────────────────────────────┐    │
│  │           │   │  context chips row (h ≈ 32)          │    │
│  │  emoji    │   ├──────────────────────────────────────┤    │
│  │  64pt     │   │  assistantText (流式)                │    │
│  │           │   │                                      │    │
│  │  ≈160w    │   ├──────────────────────────────────────┤    │
│  │           │   │  TextField (prompt input)            │    │
│  └───────────┘ │ └──────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────┘
```

HStack（spacing 0）：

| 区 | 宽度 | padding | 内容 |
|---|---|---|---|
| 左 statusEmoji | 160 | leading 24 / vertical 24 | `Text(emoji).font(.system(size: 64, weight: .regular, design: .monospaced))`，垂直居中 |
| 右 VStack | 剩余 (≈559) | leading 16 / trailing 24 / vertical 16 | 见下 |

右 VStack（spacing 12）：

1. **context chips row**：`ContextChipsView`，高度 32（chip 自身 24 + 上下 padding 4），horizontal scroll，左对齐
2. **assistantText**：`Text(assistantText)`；`.font(.system(size: 14))`；`.frame(maxWidth: .infinity, alignment: .leading)`；`.frame(maxHeight: .infinity, alignment: .top)`；超长 wrap，无 scroll（本轮不做对话历史，单 turn 文本可控）
3. **AgentInputField**：`TextField`，下文详述

panel 背景：`Color.black`，cornerRadius 32，叠加 `NotchShape` 的顶部反向圆弧过渡到 `headlineOpenedRect`。

`opened` 进入 / 离开过渡参考 `docs/guide/notch-dev-guide.md` §7.2：scale + opacity + offset(y: -panelSize.height/2)，统一 `vm.animation`。

## Edge highlight 交互

仅在 `closed` / `popping` 启用。`opened` 关闭。

规格：

- 几何：白色径向渐变，圆心 = 鼠标在 NotchView 坐标系内的 local position；半径 24pt；颜色 `white opacity 0.6 → 0`（gradient stops `[0.0: 0.6, 1.0: 0.0]`）
- mask：以 `NotchShape` 的 1pt stroke 作为 mask，让径向只显示在边缘 stroke 像素上
- 跟随：`mouseLocation` 来自 `EventMonitors.mouseLocation`（global + local），节流 16ms (≈60fps)
- 淡出：鼠标离开 `deviceNotchRect.insetBy(dx: -28, dy: -28)` 时，opacity 在 200ms 内 `easeOut` 至 0；再次进入 hot zone 时立即恢复（无淡入延迟）

实现提示（不入 design 强制，仅记录给实现方）：

- `Canvas { ctx, size in ... }` 内部画 `RadialGradient`
- 外层 `compositingGroup()` + `blendMode(.sourceAtop)` 让 mask 干净
- mask 用 `NotchShape().stroke(lineWidth: 1)`

## Context chips 区契约

chip 列表是 `SenseStore.context` 的纯 SwiftUI 投影，无任何 chip-specific 业务逻辑。组成：

```
chips = behaviors[] + windowChip
```

| 来源 | 数量 | 渲染 |
|---|---|---|
| `SenseStore.context.behaviors: [BehaviorEnvelope]` | 0..n | 默认 chip = `Text(envelope.displaySummary)`（参见 `docs/designs/os-sense.md` "Notch UI 渲染契约"） |
| 派生 window chip | 0..1 | citationKey `"general.window"`；displaySummary `"<App> · <WindowTitle>"`，由 `SenseContext.app.name` 与 `SenseContext.window?.title` 拼接，缺失时用 `app.name` 兜底 |

window chip 的派生规则（在 `ContextChipsView` 内部计算，不写入 `SenseStore`）：

```swift
let windowChipSummary: String? = {
    guard let app = ctx.app else { return nil }
    if let title = ctx.window?.title, !title.isEmpty {
        return "\(app.name) · \(title)"
    }
    return app.name
}()
```

**degraded path（design 内显式定义，非 placeholder）**：当 OS Sense Stage 0 下 `behaviors` 永远为空时，window chip 是唯一 chip。后续 GeneralProbe / Adapter 入包后，`behaviors` 自然填充，window chip 仍稳定渲染——chip 区永远至少有一个 chip 可被引用。参见 `docs/designs/os-sense.md` §"加新 adapter 的成本"。

chip 选中状态：本轮所有 chip **默认选中、不可取消**（degraded path 下用户没有有意义的选取动作可做）。submit 时把当前所有 chip 投影到 `CitedContext`：

- `behaviors` 非空 → 投影到 `CitedContext.behaviors`
- 仅 window chip → 投影到 `CitedContext.app` + `CitedContext.window`（`behaviors` 字段省略，参见 `docs/designs/rpc-protocol.md` "二进制 payload 规则"）

后续 stage 增加多 chip 选取时，在 `ContextChipsView` 内加 selection state + tap，无需触动 SenseStore / RPC schema。

## 输入区

`AgentInputField` 包装一个 `TextField`：

| 属性 | 值 |
|---|---|
| 背景 | `.clear` |
| 边框 | 无 (`textFieldStyle(.plain)`) |
| 字号 | `.system(size: 14)` |
| 光标 | 系统默认（白色，自带闪烁） |
| placeholder | `"Tell me what you want to do"` |
| `.onSubmit` | 调 `AgentService.submit(prompt:, citedContext:)` |
| 提交后行为 | 清空文本；`.focused` 保持 true |
| ESC | 由 NotchViewModel 的 keyDown monitor 捕获，关闭 panel + `AgentService.cancel()`，TextField 不自定义处理 |

`citedContext` 由 NotchViewModel 在 submit 时从 `SenseStore.context` 投影。投影发生在 Shell 进程内，`SenseContext` 的 live model 不直接序列化（参见 `docs/designs/os-sense.md` "与 AOS 主进程集成"）。

assistantText 渲染于输入框上方：`AgentService.assistantText` 由 `ui.token` notification 累加（参见 `docs/designs/rpc-protocol.md` §"流式语义"）。新 turn 开始时由 `AgentService` 重置为空。

## AgentStatus → 颜文字映射（canonical table）

| AgentStatus | 颜文字 | 触发 |
|---|---|---|
| `idle` | `:)` | 默认；turn 结束 1s 后自动回归 |
| `listening` | `:o` | **view-local**：opened 态且 TextField focused 时本地覆盖 `AgentService.status` 的 display 值 |
| `working` | `:/` | `ui.status { status: "working" }`（模型流式输出中） |
| `waiting` | `:?` | `ui.status { status: "waiting" }`，仅在 waiting 持续 >250ms 时显示（短工具不闪一下） |
| `done` | `:D` | `ui.status { status: "done" }`，由 AgentService 持有 1s 后回 `idle` |
| `error` | `:(` | `ui.error` notification |

**listening 注释**：`listening` 不是 `AgentService.status` 的合法值，仅是 `NotchView` 在「opened + 输入框 focused」条件下对显示层的本地覆盖。`AgentService.status` 不会因为输入框 focus 而变化，避免 view 状态污染 service 状态。view 层伪代码：

```swift
let displayStatus: AgentStatus = (vm.status == .opened && inputFocused)
    ? .listening
    : agentService.status
```

颜文字字体统一 monospaced，避免不同 emoji 占宽抖动。

## 数据流图（ASCII）

```
┌─────────────── CompositionRoot (AppDelegate) ───────────────┐
│                                                              │
│   ┌──────────────┐   ┌──────────────────┐   ┌────────────┐  │
│   │ SenseStore   │   │ SidecarProcess   │   │ RPCClient  │  │
│   │ (@Observable)│   │ (Process spawn)  │◀─▶│  NDJSON    │  │
│   └──────┬───────┘   └────────┬─────────┘   └─────┬──────┘  │
│          │                    │                   │         │
│          │              spawn / stderr            │         │
│          │                                        │         │
│          │           ┌────────────────────────────┘         │
│          │           ▼                                      │
│          │    ┌──────────────┐                              │
│          │    │ AgentService │ ── ui.token / ui.status /    │
│          │    │ (@Observable)│    ui.error subscriptions    │
│          │    └──────┬───────┘                              │
│          │           │                                      │
│          ▼           ▼                                      │
│        ┌────────────────────────┐                           │
│        │ NotchViewModel         │                           │
│        │  - observes both       │                           │
│        │  - state machine       │                           │
│        │  - geometry            │                           │
│        └──────────┬─────────────┘                           │
│                   │                                          │
│                   ▼                                          │
│        ┌────────────────────────┐                           │
│        │ NotchView (SwiftUI)    │                           │
│        │  ClosedBarView         │                           │
│        │  OpenedPanelView       │                           │
│        │  EdgeHighlightOverlay  │                           │
│        │  ContextChipsView      │                           │
│        │  AgentInputField       │                           │
│        └────────────────────────┘                           │
└──────────────────────────────────────────────────────────────┘
```

绑定方向严格单向：

- `SenseStore` → ViewModel → View（read-only）
- `AgentService.submit` ← View（user gesture）
- `AgentService.status / assistantText` → ViewModel → View（read-only）

ViewModel 不写 `SenseStore`、不写 RPCClient；`AgentService` 是写侧的唯一接口。

## 包边界

所有 Notch UI 代码在 `Sources/AOSShell/Notch/` 与 `Sources/AOSShell/Notch/Components/`。依赖方向：

```
AOSShell/Notch/  ──depends on──▶  AOSOSSenseKit (SenseStore, SenseContext, BehaviorEnvelope)
                 ──depends on──▶  AOSRPCSchema (CitedContext, ui.* params)
                 ──depends on──▶  AOSShell/Agent (AgentService)

AOSOSSenseKit   ──must NOT import──▶ AOSShell/Notch/*
AOSRPCSchema    ──must NOT import──▶ AOSShell/Notch/*  (also no SwiftUI)
```

`AOSRPCSchema` 与 `AOSOSSenseKit` 都不应出现 SwiftUI / AppKit UI 类型。NotchViewModel 的 input（如 `BehaviorEnvelope`）来自 SenseKit 的 Codable 类型；不允许在 SenseKit 中定义 SwiftUI `View` / `Color`。

## 风险 / 已知问题

| 风险 | 影响 | 缓解 |
|---|---|---|
| 多屏切换 / 外接显示器插拔 | NotchWindow frame 错位 | 订阅 `NSApplication.didChangeScreenParametersNotification` 重建 NotchWindowController；选 `NSScreen.buildin` |
| 外接屏无物理刘海 | `notchSize` 为 zero，几何不成立 | 仅在 `NSScreen.buildin` 上挂 NotchWindow；外接屏不显示 |
| Accessibility 权限缺失 | `WindowIdentity.windowId` 为 nil，但 title 可由 `NSRunningApplication.localizedName` 兜底 | window chip 仍渲染（用 app name + 空 title），引用时 `CitedContext.window.windowId` 字段 omit |
| 长 prompt / 长 assistantText | panel 高度固定 240，溢出不可见 | 本轮 assistantText 单纯 wrap；超出区域被裁剪。后续 stage 引入 scroll |
| TextField focus 与 NotchWindow key window 协作 | window 失焦自动 close 可能与 IME 候选窗冲突 | `resignKey` close 在 IME 输入会话期间应推迟（本轮不实现，记录为已知问题） |
| Edge highlight 高频重绘 | 60fps mouseMoved 影响 CPU | mouseLocation `throttle 16ms`；highlight 仅在 closed/popping 启用 |

## 不做的事

- 不接收文件 / URL drop（`onDrop` 完全不挂）
- 不做 settings / preferences UI（任何配置 UI）
- 不做 history / 多 turn 渲染
- 不做 Spotlight 风格命令调色板 / 模糊匹配
- 不做键盘快捷键唤起（如 Cmd+Space 风格 hot key）
- 不做 chip 富渲染（favicon / 文件图标），仅 `displaySummary` 文本
- 不做多 NotchWindow 同时显示
- 不做 panel 大小 / 位置自适应（720 × 240 固定）
- 不做对话气泡 / Markdown 渲染（assistantText 是纯文本）
- 不做语音输入 / TTS

# Background Click

本文记录 AOS 当前已经验证稳定的 general AppKit background click 链路。
目标是在不影响用户当前前台窗口的情况下，对后台目标窗口投放鼠标左键：

- 目标窗口可以获得 AppKit 输入路由所需的 focus / active 状态。
- 用户当前 frontmost app / window 不被切走。
- 鼠标事件进入目标 pid/window。
- 投放后目标窗口不留在被 raise 到前面的状态。

本文只描述 general AppKit path。Chromium / Electron web content 使用单独的
SkyLight route，见 `docs/research/bgclick-chromium.md`。

## Core Idea

最终稳定方案不是找到一个“绝对不会触发 raise 的 mouse post API”。实测和 Codex
Computer Use 二进制分析都说明：mouse down/up 仍可能触发 WindowServer / AppKit
的窗口顺序补偿。Codex 的关键不是 prevent every raise，而是：

1. 用不 raise 的方式把目标窗口准备成可接收输入。
2. 用 pid-scoped mouse event 把点击投进目标进程。
3. 观察/修复点击造成的 z-order 副作用，把原先盖在目标上面的窗口放回去。

AOS 目前在短生命周期 CLI 里实现了同一模型的同步版本：投放阶段立即 repair，并在
点击后用短时间 dense polling 捕捉 delayed raise。

## Chain

### 1. Standard Focus Without Raise

文件：

- `Sources/AOSComputerUseKit/Windows/SkyLightWindowFocuser.swift`

点击前和显式 `focus-window` 使用同一个 `focusWindowWithoutRaising` 路径，只对目标
进程的 PSN 发送一个 target-side focus event record：

```text
SLPSPostEventRecordTo(targetPSN, focus(windowId, marker: focus))
```

关键点：

- 不调用 `_SLPSSetFrontProcessWithOptions`，避免触发 raise / Space follow。
- 不再向用户当前 front process 发送 defocus event。早期 CUA/yabai 风格
  `front defocus + target focus` 能帮助某些 mouse dispatch，但会让用户当前窗口
  出现 deactive / refocus 闪动。
- 当前 click 链路不再有单独的 `SkyLightMouseClickFocuser`。`post-left-click`
  先走这条标准 focus-without-raise 路径。
- 当前 standard target-side focus 已在多个 App 上验证：目标能进入输入路由状态，
  同时用户 frontmost app 保持不变。

这一步解决的是 AppKit routing，不负责投放鼠标，也不负责 z-order repair。

### 2. Pid-scoped Mouse Event Delivery

文件：

- `Sources/AOSComputerUseKit/Input/MouseEventPoster.swift`

当前 general path 使用 public per-pid route：

```text
CGEvent.postToPid(pid)
```

投放顺序：

```text
mouseMoved -> leftMouseDown -> leftMouseUp
```

每个 event 都带上目标窗口语义：

- `event.location = screenPoint`
- `mouseEventButtonNumber = 0`
- `mouseEventSubtype = 3`
- `mouseEventClickState = 1` for down/up
- `mouseEventWindowUnderMousePointer = windowId`
- `mouseEventWindowUnderMousePointerThatCanHandleThisEvent = windowId`
- `CGEventSetWindowLocation(event, windowLocalPoint)`
- `SLEventSetIntegerValueField(event, 0, mouse event number)`
- `SLEventSetIntegerValueField(event, 40, pid)`
- `SLEventSetIntegerValueField(event, 51, windowId)`
- `SLEventSetIntegerValueField(event, 58, click group)`
- `SLEventSetIntegerValueField(event, 91, windowId)`
- `SLEventSetIntegerValueField(event, 92, windowId)`

重要修正：

- 不 dual-post。早期同时走 SkyLight + public `postToPid` 会让 AppKit target 收到重复
  `leftMouseDown`。
- general AppKit target 用 public `CGEvent.postToPid` 更稳定；SkyLight mouse post
  留给后续 Chromium trust-path 研究。
- 不走 HID stream，因此不会移动真实鼠标指针。

### 3. Immediate Stage Repair

文件：

- `Sources/AOSComputerUseKit/ComputerUseCore.swift`
- `Sources/AOSComputerUseKit/Windows/WindowOrderGuardian.swift`
- `Sources/AOSComputerUseKit/Windows/AXWindowRaiser.swift`

在 mouse poster 每个阶段之后，core 立即运行一次 order repair：

```text
afterMouseMoved -> repair
afterTargetDown -> repair
afterTargetUp   -> repair
```

`WindowOrderGuardian` 在点击前采样当前 WindowServer order，并只保护满足这些条件的窗口：

- layer 0
- on-screen
- normal-size
- 点击前位于 target 上方
- 几何上和 target bounds 有重叠

只保护 overlapping windows 是必要的。多屏环境里，global window rank 可能变化但视觉上
不互相遮挡；盲目恢复所有 globally-above windows 会引入无关 flicker。

repair primitive 当前使用 AX：

```text
AXUIElementPerformAction(axWindow, "AXRaise")
```

`AXWindowRaiser` 通过 `_AXUIElementGetWindow` 把 AX window 精确匹配到 `CGWindowID`，
只 raise 原本盖住 target 的具体窗口。

### 4. Delayed Order Guard

mouse up 之后，WindowServer / AppKit 仍可能在几十到数百毫秒后执行 delayed raise。
因此短生命周期 CLI 不能只做 0ms repair。

当前 production guard：

```text
interval: 5ms
window:   300ms
```

来源：

- Codex Computer Use 二进制里的 `WindowOrderingObserver` 有 `ContinuousClock.sleep`
  retry loop。
- 反汇编可见 attempt cap `0x28`，即 40 次。
- Swift `Duration` literal 解码约为 5ms。

Codex 是常驻进程，能在观察到 order change 后开始 5ms retry。AOS CLI 是短命命令，
只能从点击前/点击后开始轮询，所以 guard window 放宽到 300ms。

### 5. Target Deactivate After Dispatch

文件：

- `Sources/AOSComputerUseKit/Windows/SkyLightWindowFocuser.swift`
- `Sources/AOSComputerUseKit/ComputerUseCore.swift`

pid-scoped mouse event 投放后，目标窗口可能停留在“后台 active/key”的状态。这个状态
不会改变 `NSWorkspace.frontmostApplication`，但如果下一次继续对这个 active target 投放
鼠标事件，WindowServer / AppKit 可能瞬间把它补偿 raise 到前台，造成闪动。

因此 `postLeftClick` 在完整投放链路收口时执行 target-side deactive：

```text
SLPSPostEventRecordTo(targetPSN, focus(windowId, marker: defocus))
```

关键点：

- 只对目标 pid/window 发 `.defocus`，不对用户原前台窗口发 defocus。
- 先恢复原 front window focus，再 deactive target，然后进入 delayed order repair guard。
  Chrome / Electron 可能在 target-side deactivation cleanup 后才执行 delayed order
  compensation；deactivation 必须被同一个 guard window 覆盖，不能放在 guard 之后。
- 如果目标窗口本来就是点击前的前台 active 窗口，则跳过 deactive；正常前台点击不应被降为 inactive。
- deactive 不负责 z-order repair，只撤掉目标窗口残留的 active/key 状态，避免下一次后台投放触发 raise 闪动。

## Why This Works

这条链路把四个问题拆开处理：

1. **Input routing**：standard target-side `SLPSPostEventRecordTo` focus record
   让目标 AppKit 窗口相信自己可接收输入。
2. **Event delivery**：pid-scoped `CGEvent.postToPid` 把鼠标事件送进目标进程，不碰全局 HID cursor。
3. **Visual order preservation**：`WindowOrderGuardian + AXRaise` 把点击造成的 delayed raise 副作用压回去。
4. **Active-state cleanup**：target-side defocus 撤掉后台目标残留的 active/key 状态，避免下一次投放被系统补偿 raise。

因此用户看到的效果是：

- 当前使用的窗口始终 frontmost。
- 目标后台窗口可以响应鼠标点击。
- 目标窗口不会停留在被 raise 到前面的状态。
- 目标后台窗口不会在点击链路结束后继续保持 active/key 状态。
- 在已验证的 AppKit apps 上没有可见 flicker。

## CLI Surface

启动坐标 probe：

```zsh
.build/debug/AOSComputerUseCLI open-coor-test
```

向窗口 local coordinate 投放：

```zsh
.build/debug/AOSComputerUseCLI post-left-click --pid <pid> --window-id <windowId> --coor <x,y>
```

`--coor` 是目标窗口 top-left local point，CLI 会转换为 screen point 后走同一条
background click core path。

## Validation Targets

当前保留两个独立 pid 的 AppKit probe：

- `AOSCoordinateTarget`
  - 画 top-left 坐标网格。
  - 记录 mouse move/down/up 和 local monitor 事件。
  - 用于验证坐标转换和事件是否进入目标进程。

## Known Limits

- Chromium / Electron web content is not part of this AppKit route. Its current
  working route is documented in `docs/research/bgclick-chromium.md`.
- Safari / WebKit remains out of scope for pixel background clicks.
- CLI 版本用同步 300ms guard 模拟常驻 observer。长期形态应迁入 AOS app 进程，做真正
  的 `WindowOrderingObserver`，减少命令返回延迟。
- repair 依赖 Accessibility permission，因为当前 primitive 是 `AXRaise`。
- 目标窗口必须是当前 Space 上可见的 layer-0 window；隐藏、最小化、跨 Space 的窗口
  不在当前已验证范围内。

## Implementation Map

- `SkyLightWindowFocuser`
  - standard target-side focus record for mouse routing and explicit focus.
  - target-side defocus record for post-dispatch background active cleanup.

- `MouseEventPoster`
  - create/stamp/post AppKit-route pid-scoped move/down/up events.

- `WindowOrderGuardian`
  - capture protected overlapping windows before click.
  - detect target crossing protected windows after click.

- `AXWindowRaiser`
  - map `CGWindowID -> AXUIElement`.
  - perform `AXRaise` on protected windows.

- `ComputerUseCore.postLeftClick`
  - orchestrates focus, event post, immediate repair, delayed guard, target deactive cleanup.

- `AOSComputerUseCLI`
  - exposes `post-left-click` and `open-coor-test`.

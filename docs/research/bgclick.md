# Background Click

本文记录 AOS 当前已经验证稳定的 general AppKit background mouse event 链路。
目标是在不影响用户当前前台窗口的情况下，对后台目标窗口投放坐标鼠标事件：

- 目标窗口可以获得 AppKit 输入路由所需的 focus / active 状态。
- 用户当前 frontmost app / window 不被切走。
- 鼠标事件进入目标 pid/window。
- 投放后目标窗口不留在被 raise 到前面的状态。

本文只描述 general AppKit path。Browser web content 使用单独的 SkyLight route，
见 `docs/research/bgclick-chromium.md`。

## Core Idea

最终稳定方案不是找到一个“绝对不会触发 raise 的 mouse post API”。实测和 Codex
Computer Use 二进制分析都说明：mouse down/up 仍可能触发 WindowServer / AppKit
的窗口顺序补偿。Codex 的关键不是 prevent every raise，而是：

1. 用不 raise 的方式把目标窗口准备成可接收输入。
2. 用 pid-scoped mouse event 把点击投进目标进程。
3. 观察点击造成的 z-order 副作用；只在它威胁用户当前 active/front 窗口状态时做 focus cleanup。

AOS 目前在短生命周期 CLI 里实现了同一模型的同步版本：投放阶段立即检查 active/front
状态，并在点击后用短时间 dense polling 捕捉 delayed raise。

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
- 当前 mouse event 链路不再有单独的 mouse-specific focuser。`left-click`
  先走这条标准 focus-without-raise 路径。
- 当前 standard target-side focus 已在多个 App 上验证：目标能进入输入路由状态，
  同时用户 frontmost app 保持不变。

这一步解决的是 AppKit routing，不负责投放鼠标，也不负责 z-order preservation。

### 2. Pid-scoped Mouse Event Delivery

文件：

- `Sources/AOSComputerUseKit/Input/MouseEventPoster.swift`

当前 general path 使用 public per-pid route：

```text
CGEvent.postToPid(pid)
```

AppKit route 只支持左/右键 click。投放顺序：

```text
mouseMoved -> mouseDown(button) -> mouseUp(button)
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

### 3. Immediate Active-State Guard

文件：

- `Sources/AOSComputerUseKit/ComputerUseCore.swift`
- `Sources/AOSComputerUseKit/Windows/WindowOrderGuardian.swift`

在 mouse poster 每个阶段之后，core 立即运行一次 active-state guard：

```text
afterMouseMoved -> guard
afterTargetDown -> guard
afterTargetUp   -> guard
```

`WindowOrderGuardian` 在点击前采样当前 WindowServer order，并只观察满足这些条件的窗口：

- layer 0
- on-screen
- normal-size
- 点击前位于 target 上方
- 几何上和 target bounds 有重叠

只观察 overlapping windows 是必要的。多屏环境里，global window rank 可能变化但视觉上
不互相遮挡；把 non-overlapping windows 纳入判断会引入无关噪声。

AOS 不再尝试在后台做完美 z-order preservation。实测中 Chrome/AppKit target 被系统
raise 后，如果再用 `AXRaise` 或 `SLSOrderWindow` 修复全部窗口顺序，最容易影响用户窗口。
当前策略是：允许 target 在后台压过非 active cover，但持续保证用户点击前的 active app/window
不被留下切走。`WindowOrderGuardian` 只报告 target 是否越过了原本覆盖它的 overlapping
window，core 用这个信号决定是否恢复原 front window focus / activation。

### 4. Delayed Active-State Guard

mouse up 之后，WindowServer / AppKit 仍可能在几十到数百毫秒后执行 delayed raise。
因此短生命周期 CLI 不能只做 0ms guard。

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

### 5. App Session Cleanup

文件：

- `Sources/AOSComputerUseKit/Windows/SkyLightWindowFocuser.swift`
- `Sources/AOSComputerUseKit/ComputerUseCore.swift`

pid-scoped mouse event 投放后，目标窗口会作为当前 app session 保持“后台 active/key”
状态。这个状态用于让输入框 focus、caret、右键菜单等 transient UI 在视觉 snapshot 和
后续操作之间继续可见。

`ComputerUseCore` 暴露两个显式 session interface：

```text
startAppSession(pid:windowId:)
stopAppSession()
```

`startAppSession` 是唯一能开始或切换 current session 的入口。任意
`postMouseEvent` / `postKeyboardEvent` 都必须在 active app session 内按 windowId 投放；
事件投放使用 current session pid 校验 window ownership。

`stopAppSession` 或显式切换到不同 pid session 只释放 session lease 和视觉 overlay，
不再执行 target-side deactive。后续验证发现 target-side defocus 可能让目标窗口在
session 结束后停留在无法响应真实用户鼠标点击/拖拽的 inactive 状态。

关键点：

- session 只记录 pid，不记录 target window id。
- `stopAppSession` 不枚举 session pid 窗口，也不发送 `.defocus`。
- 单次 event 投放期间，active-state guard 仍保护投放前 front window 的 order/focus，
  但不会因为 target app 仍 active 就 deactive 或 reactivate original app。

## Why This Works

这条链路把四个问题拆开处理：

1. **Input routing**：standard target-side `SLPSPostEventRecordTo` focus record
   让目标 AppKit 窗口相信自己可接收输入。
2. **Event delivery**：pid-scoped `CGEvent.postToPid` 把鼠标事件送进目标进程，不碰全局 HID cursor。
3. **Order drift detection**：`WindowOrderGuardian` 只观察 target 是否越过原 overlapping cover，不直接重排任何窗口。
4. **App session cleanup**：`stopAppSession` 只释放 AOS 的 session ownership 和 overlay；
   不再用 private defocus 修改目标窗口的真实交互状态。

因此用户看到的效果是：

- 当前使用的窗口始终 frontmost。
- 目标后台窗口可以响应鼠标点击。
- 目标窗口可能在后台压过非 active cover，但不会把用户当前 active/front 窗口留下切走。
- 目标后台窗口会在 app session 打开期间保持 active/key 状态，直到显式 `stopAppSession`
  或切换到不同 target。
- 在已验证的 AppKit apps 上没有可见 flicker。

## CLI Surface

启动坐标 probe：

```zsh
.build/debug/AOSComputerUseCLI interactive
```

然后在 Command 菜单选择 `open-coor-test`。

进入 interactive host 后，先显式开始 app session，再向当前 session 下的窗口 local coordinate 投放：

1. 启动 `.build/debug/AOSComputerUseCLI interactive`。
2. 在 Command 菜单选择 `start-app-session`，按 App / Window prompt 选择目标。
3. 选择 `left-click` 或 `right-click`，在 Window 菜单选择当前 session 的目标窗口，并在 prompt 输入 `x,y` 和可选 `count`。
4. 选择 `drag` 时，在 Window 菜单选择目标窗口，按 prompt 输入 start/end `x,y` 和 button。
5. 最后选择 `stop-app-session`。

CLI 坐标参数是目标窗口 top-left local point，CLI 会转换为 screen point，然后构造
对应的 `BackgroundMouseEvent` 走同一条 background mouse event core path。
`left-click` / `right-click` 的 `count` 默认为 1；大于 1 时，同一坐标会生成连续
down/up click sequence，并把第 N 次目标 down/up 的 `.mouseEventClickState` 设为 N。
`drag` 是 web-content-only command；AppKit route 只接受 `left-click` 和
`right-click`。

`start-app-session` / `stop-app-session` 是 core app session API 的 CLI surface。
鼠标事件投放不再接收 pid，也不会自动切换 target session；调用方必须先在同一个
`ComputerUseCore` lifetime 内显式 `start-app-session`。事件投放使用 current session
pid 校验 window ownership，`stop-app-session` 释放当前 session 和 overlay，不向
target window 发送 defocus。成对 start/stop 需要调用方复用同一个
`ComputerUseCore` lifetime；当前 CLI 只保留 interactive host 来持有这个有状态 core。

在 CLI 中执行 `.build/debug/AOSComputerUseCLI interactive` 后，通过 Command 菜单选择
`start-app-session` 和 `stop-app-session`。

## Validation Targets

当前保留两个独立 pid 的 AppKit probe：

- `AOSCoordinateTarget`
  - 画 top-left 坐标网格。
  - 记录 mouse move/down/up 和 local monitor 事件。
  - 用于验证坐标转换和事件是否进入目标进程。

## Known Limits

- Browser web content is not part of this AppKit route. Its current working
  route is documented in `docs/research/bgclick-chromium.md`.
- Safari validation found that WebKit page content needs the same SkyLight
  web-content route as Chromium/Electron: explicitly classifying
  `com.apple.Safari` as `webContent` makes page clicks work, and Safari's
  AppKit chrome such as sidebar/back/forward controls still responds.
- Caveat: Safari support is an explicit known-browser bundle-id rule, not a
  general WebKit rule. Do not classify arbitrary apps as `webContent` merely
  because they link WebKit or contain a `WKWebView`; many native AppKit apps
  embed web views but do not need the browser event trust path, and the
  SkyLight route has broader private-API side effects than the AppKit route.
- Current classification logic is conservative:
  Electron/CEF/Chromium runtime evidence, known Chromium-family browser bundle
  ids, known Electron bundle ids, and explicit Safari bundle id use
  `webContent`; everything else defaults to `appKit`.
- CLI 版本用同步 300ms guard 模拟常驻 observer。长期形态应迁入 AOS app 进程，做真正
  的 `WindowOrderingObserver`，减少命令返回延迟。
- 当前方案不追求完美保持所有后台窗口的相对顺序；如果 target 被系统 raise 到 non-active
  cover 上方，AOS 接受这个后台顺序变化。
- 目标窗口必须是当前 Space 上可见的 layer-0 window；隐藏、最小化、跨 Space 的窗口
  不在当前已验证范围内。

## Implementation Map

- `SkyLightWindowFocuser`
  - standard target-side focus record for mouse routing and explicit focus.
  - target-side defocus record remains a diagnostic primitive, not app-session cleanup.

- `BackgroundMouseEvent`
  - describes coordinate mouse behavior separately from the delivery path.
  - currently models click and drag intent.

- `MouseEventPoster`
  - creates/stamps/posts pid-scoped mouse events for the selected route.
  - AppKit route currently posts left/right click through public
    `CGEvent.postToPid`.
  - Web-content route posts left/right click and drag sequences through
    SkyLight, preserving the evidence-backed off-edge left primer before the
    target event.

- `WindowOrderGuardian`
  - capture protected overlapping windows before click.
  - report whether target crossed a previously covering protected window.

- `ComputerUseCore`
  - exposes `startAppSession` / `stopAppSession`.
  - orchestrates validation, app session, focus, event post, immediate guard,
    and delayed guard for background mouse events.

- `AOSComputerUseCLI`
  - exposes the current diagnostic commands, including `start-app-session`,
    `stop-app-session`, `left-click`, `right-click`, `drag`, and
    `open-coor-test`.
  - mouse-event commands construct `BackgroundMouseEvent` values before calling
    `ComputerUseCore.postMouseEvent`.

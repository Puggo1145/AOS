# Computer Use 设计

## 目标

为 AOS 提供**不抢前台焦点**的 macOS 应用操作能力。Agent 能够在用户正常使用电脑的同时，于后台读取目标 app 的 UI 状态并执行点击、输入、拖拽、快捷键等操作，全过程 `NSWorkspace.frontmostApplication` 不变、用户的真实光标不动、目标窗口的 z-rank 不变。

## 技术选型

| 维度 | 决策 | 理由 |
|---|---|---|
| 实现语言 | Swift 6.2+ | macOS 原生 API 仅此可用 |
| 打包形态 | SwiftPM package | 无需 Xcode 工程，与 AOS shell 架构一致 |
| 屏幕捕获 | ScreenCaptureKit (`SCStream`) | 抓非前台窗口，按 pid + windowId 定位 |
| 鼠标 / 键盘投递 | SkyLight `SLEventPostToPid`（auth-signed）→ `CGEvent.postToPid` → HID tap（仅 frontmost） | 三层路径覆盖 Chromium、AppKit、OpenGL viewport |
| 焦点抑制 | AXEnablementAssertion + SyntheticAppFocusEnforcer + SystemFocusStealPreventer | 三层叠加保证 frontmost app 全程不变 |
| 元素定位 | Accessibility API (AX) 为主 | 语义化、稳定；无 AX 时才回退坐标 |
| 状态键 | `(pid, windowId)` | 同 pid 多窗口的 elementIndex 不互相污染 |
| 对外接口 | in-process Swift API，通过 Shell RPC Dispatcher 暴露为 `computerUse.*` JSON-RPC 方法 | 与 OS Sense 共用 Shell 进程，权限与签名统一 |
| 权限模型 | Accessibility + Screen Recording | 运行时动态请求，无 entitlements |

参考实现：`playground/cua/libs/cua-driver`（READ-ONLY）。核心 SPI 桥接、focus suppression 三层、Chromium AX 激活、Spaces 检测、focus-without-raise 点击配方均参考其方案。

## 模块结构

```
packages/
  AOSComputerUseKit/
    Sources/AOSComputerUseKit/
      ComputerUseService.swift           # 对外门面，编排所有操作
      Focus/
        AXEnablementAssertion.swift      # 写 AXManualAccessibility / AXEnhancedUserInterface
        SyntheticAppFocusEnforcer.swift  # 写 AXFocused / AXMain，做完还原
        SystemFocusStealPreventer.swift  # 监听 didActivateApplication，反向夺回焦点
        FocusGuard.swift                 # 编排上面三层
      Input/
        SkyLightEventPost.swift          # SLEventPostToPid + SLSEventAuthenticationMessage SPI 桥接
        FocusWithoutRaise.swift          # yabai 式 PSN 事件记录（不重排的 AppKit 激活）
        MouseInput.swift                 # NSEvent-bridged CGEvent 鼠标合成
        KeyboardInput.swift              # CGEvent 键盘合成（Unicode + 虚拟键码）
        AXInput.swift                    # AX 动作分发 + hit-test 自校准
      Capture/
        WindowCapture.swift              # SCStream 单窗口 / 全屏捕获
        ScreenInfo.swift                 # backingScale 解析
      Apps/
        AppEnumerator.swift              # 可操作 app 列表
      Windows/
        WindowEnumerator.swift           # CGWindowList → WindowInfo
        WindowCoordinateSpace.swift      # window-pixel ↔ screen-point 换算
        SpaceDetector.swift              # SLS SPI 检测窗口是否在当前 Space
      AppState/
        AccessibilitySnapshot.swift      # AX 树遍历 + Chromium 激活
        TreeRenderer.swift               # AX 树 → Markdown
        StateCache.swift                 # (pid, windowId) → snapshot 缓存
      Permissions/
        Permissions.swift                # AXIsProcessTrusted / SCShareableContent 探测
    Tests/AOSComputerUseKitTests/
```

单一 Swift package，不输出独立可执行。AOS Shell 直接作为依赖链接，通过 `ComputerUseService` public API 调用。

Kit 单一职责：接收参数 → 操作 macOS → 返回结构化结果。不感知 JSON-RPC、Bun、agent loop。对外暴露由 Shell 侧 handler 承担。

## 核心实现

### 焦点抑制（FocusGuard）

每个会触发 AppKit / Chromium 反应的操作都包在 `FocusGuard.withFocusSuppressed(pid:element:)` 里，三层叠加：

1. **AXEnablementAssertion** — 在目标 app root 写 `AXManualAccessibility = true` 和 `AXEnhancedUserInterface = true`。Chromium-family（Slack、Discord、VS Code、Cursor、Chrome、Edge、Notion、Linear、Figma desktop 等所有 Electron）默认关闭 web AX tree 当作省电优化，必须写入这两个属性才会构建完整树。每次 snapshot 重写一次，因为 Chromium 在 backgrounding / tab 切换时会重置该属性。Native AX app 写入会被静默拒绝，进入负缓存避免重复尝试。

2. **SyntheticAppFocusEnforcer** — 在 AX 动作之前向目标 window 写 `AXFocused=true` 和 `AXMain=true`，向元素写 `AXFocused=true`，让 AppKit 内部状态机相信"我有焦点"。动作完成后还原原值。最小化窗口跳过此层（写 AXFocused 会触发 Chrome 自动 deminiaturize）。

3. **SystemFocusStealPreventer** — 监听 `NSWorkspace.didActivateApplicationNotification`。如果目标 app 在 AX 动作过程中通过 `NSApp.activate(ignoringOtherApps:)` 自激活，0ms 同步把焦点抢回操作前的 frontmost app，在 WindowServer 合成下一帧之前完成，用户感受不到 flash。

`FocusGuard` 自动获取并保留前序 frontmost app 引用，操作结束后无论成功失败都还原 enforcer 状态，suppression handle 也保证 cleanup。

### 事件投递路径

**鼠标 → 后台目标**：双路径并发投递。

1. `SLEventPostToPid`（SkyLight 私有 SPI）经过 `CGSTickleActivityMonitor` → `IOHIDPostEvent`，事件被 Chromium 识别为 live input。
2. `CGEvent.postToPid` 公共 API，作为 Chromium 之外 AppKit app 的兜底。

事件由 `+[NSEvent mouseEventWithType:...]` 构造再桥接到 `CGEvent`。Chromium 渲染进程在 IPC 边界过滤纯 raw-CGEvent 构造的事件，必须走 NSEvent-bridge 才能被 web 内容接收。两个路径并发投递，事件可能在目标进程到达两次，无可观察副作用（不动用户光标）。

后台左键单 / 双击采用 **focus-without-raise + off-screen primer 配方**：

1. `FocusWithoutRaise.activateWithoutRaise(targetPid, targetWid)` — 通过 `_SLPSGetFrontProcess` / `GetProcessForPID` / `SLPSPostEventRecordTo` 三个 SPI 投递 248 字节合成事件记录，把目标标记为 AppKit-active（`isActive` 翻 true、AX 事件触发、`SLEventPostToPid` 路由按 active 处理），但 WindowServer 不重排窗口、不触发 Space follow。
2. 50ms 等待焦点事件 settle。
3. `mouseMoved` 至目标坐标。
4. 屏幕外 `(-1, 1441)` primer 左键 down/up 对（满足 Chromium user-activation gate，无 DOM hit）。
5. 目标坐标真实左键 down/up 对。

每个事件附窗口本地坐标（`CGEventSetWindowLocation` 私有 SPI）和 SkyLight raw-field（f0 / f3 / f7 / f51 / f58 / f91 / f92），通过 `SLEventPostToPid` 不附 auth message 投递（鼠标走 IOHIDPostEvent 路径，附 auth message 会 fork 到 direct-mach 路径绕过 Chromium 订阅的 `cgAnnotatedSessionEventTap`）。

修饰键点击 / 三击 / 拖拽 / 中键 / 右键走标准 NSEvent-bridge 双路径并发投递，跳过 primer。

**鼠标 → frontmost 目标**：`CGEventPost(tap: .cghidEventTap)` 配前置 `mouseMoved`。OpenGL / GHOST viewport（Blender、Unity、游戏引擎）在 event-source 层过滤所有 per-pid 路径，HID tap 是唯一可达的路径。目标已在前台时 HID tap 不构成抢焦点。

**键盘**：始终走 per-pid 路径。`SLEventPostToPid` 附 `SLSEventAuthenticationMessage` 包装（Chromium 在 macOS 14+ 拒收未签名键盘事件），SPI 缺失则降级 `CGEvent.postToPid`。`typeText` 用 `CGEventKeyboardSetUnicodeString` 逐字符投递 Unicode keyDown / keyUp，30ms 间隔（IME / autocomplete 兼容）。

**SkyLight SPI 全部通过 `dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)` + `dlsym` 解析**，缓存解析结果，任一符号缺失自动降级到下一层。无 entitlements 依赖。

### 操作降级链路

每次操作（click / drag / scroll / typeText 含义化路径）外层包 `FocusGuard.withFocusSuppressed`，内层按以下顺序执行，前一级失败则下一级：

1. **AX 语义动作** — `AXUIElementPerformAction` 调用 `AXPress` / `AXShowMenu` / `AXConfirm` / `AXOpen` / `AXPick` / `AXCancel` 等。先调 `AXUIElementCopyActionNames` 验证目标 advertised actions 包含请求动作，否则跳过本层（perform 会返回 success 但实际是 no-op）。
2. **AX 属性修改** — 设置 `kAXMainAttribute` / `kAXFocusedAttribute` / `kAXSelectedAttribute` / `kAXValueAttribute` 等。
3. **定向事件投递** — 走"事件投递路径"鼠标后台双路径。坐标先由 screenshot pixel → window point 换算，再 `AXUIElementCopyElementAtPosition` 做 hit-test 校准。

`pressKey` / `typeText` 跳过 1、2，直接走第 3 层键盘路径。

三层都失败返回 `ErrOperationFailed`，附带每层的 status code，由 agent 决定下一步。

### 屏幕与元素感知

**截图** — `SCStream` + `SCContentFilter(desktopIndependentWindow:)`。每次 capture 用窗口 frame ∩ NSScreen.frame 最大者解析 backing scale，多显示器 / 混合 1x/2x 场景下尺寸正确。返回 PNG / JPEG 二进制 + `(width, height, scaleFactor)`，必要时按 `maxImageDimension` 等比缩放并附 `originalWidth / originalHeight`。

**Window 选择规则** — `selectFrontmostWindow(forPid:)`：先取 layer 0 且 `isOnScreen` 且 on-current-Space 中 zIndex 最高者；fallback 取 layer 0 中面积最大者（覆盖 hidden-launched / 全部最小化场景）。`captureWindow` 与 `WindowCoordinateSpace.screenPoint(...)` 共用此规则，截图与坐标换算 anchor 一致。

**AX 树遍历** — 从 `AXUIElementCreateApplication(pid)` 开始，按 `windowId` 过滤到目标 window 子树（外加 menu bar）。限制：最多 500 元素、最深 25 层。每个元素分配 `elementIndex` 并产出一行 Markdown：

```
[<index>] <role> "<title>" (<subrole>) <description> actions=[AXPress,AXShowMenu]
```

**AX → CGWindowID 桥接** 通过私有 SPI `_AXUIElementGetWindow` 解析（自 macOS 10.9 稳定，yabai / Hammerspoon / Accessibility Inspector 均使用）。该 `@_silgen_name` 桥接归属于独立的 **`AOSAXSupport` Swift package**（共享底层 AX SPI），`AOSComputerUseKit` 与 `AOSOSSenseKit` 都依赖它，避免读侧（OS Sense）反向依赖写侧（Computer Use）：

```swift
// AOSAXSupport/Sources/AOSAXSupport/AXSPI.swift
@_silgen_name("_AXUIElementGetWindow")
public func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError
```

### Chromium / Electron AX 激活

每个 pid 第一次 snapshot 时执行：

1. `AXEnablementAssertion.assert(pid, root)` 写入 `AXManualAccessibility` 和 `AXEnhancedUserInterface` 两个属性。
2. 创建 `AXObserver`，`AXObserverAddNotification` 订阅 `kAXFocusedUIElementChangedNotification` 等若干 notification（callback 为 no-op，仅靠 observer 存在性向 Chromium 信号"有 AX client 在听"）。
3. 把 observer 的 runloop source 挂到 **Shell 进程的 main runloop**（`CFRunLoopGetMain`）。Chromium AX pipeline 只在该 source 持续被 service 期间保持开启，挂到临时 task runloop 会在 idle 时被 Chromium 拆掉树。
4. `CFRunLoopRunInMode(.defaultMode, 0.5, false)` 同步 pump 500ms，等 Chromium 把 web AX tree 构建完后再 walk。

后续 snapshot 跳过 observer 注册和 runloop pump，但 enablement 属性每次都重写一次。Observer 引用存在 `StateCache` 的 per-pid 表里保持 retain，进程退出时随之释放。

### Spaces 检测

通过 `SLSGetActiveSpace` + `SLSCopySpacesForWindows` SPI 检测目标 window 是否在用户当前 Space。在另一 Space 的窗口，AX 子系统会静默把树砍成菜单栏（即使 `SCShareableContent` 仍返回 backing store，agent 拿到的截图也仅是缓存）。

`getAppState` 在目标 window 不在当前 Space 时返回 `ErrWindowOffSpace`，附 `currentSpaceID` 和 `windowSpaceIDs`。Agent 可提示用户切 Space 或选择别的窗口。

### 坐标空间换算

外部 API 的 `(x, y)` 始终是 **window-local screenshot pixels**（`getAppState` 返回 PNG 的 top-left 像素坐标）。Kit 内部转换：

```
screen_point.x = windowBounds.x + image_pixel.x / backingScale
screen_point.y = windowBounds.y + image_pixel.y / backingScale
```

`backingScale` 用窗口 frame 与 `NSScreen.frame` 最大相交者的 `backingScaleFactor`（与 `WindowCapture` 同源），保证截图采样与坐标换算的 scale 互相抵消。

`(pid, windowId)` 一致性强校验：传入的 `windowId` 必须属于 `pid`，否则返回 `ErrWindowMismatch`。

### AX hit-test 自校准

语义化点击的可视坐标 / fallback 坐标使用 element 的 `AXPosition + AXSize` 几何中心。如果该 center 经 `AXUIElementCopyElementAtPosition` hit-test 不能解析回目标元素或其后代，按 5×5 网格（跳过四角）扫描 17 个 fallback 点，取第一个能 hit-test 命中的点。Voice Memos 底栏 / IINA 工具面板这类复合控件 AX center 落在 padding 上时仍可被点中。

如果 grid 全部失败（元素被遮挡或边界报错），AX 动作仍会被分发（不需要坐标），坐标 fallback 不可用。

### AX 快照生命周期

`getAppState({pid, windowId, captureMode?})` 必传 `windowId`（先 `listWindows({pid})` 选）。Kit 内部：

- 完成 AX 遍历后，在 `StateCache` 中按 `(pid, windowId)` 保存 `[elementIndex → AXUIElement]`，分配 UUID `stateId`，TTL 30s
- 同 `(pid, windowId)` 的新 snapshot 直接覆盖旧缓存（不做 LRU，单 key 仅保留最新）
- `click({pid, windowId, stateId, elementIndex})`：
  - 命中且 element 仍 valid → 进入操作降级链路
  - stateId 不存在 / 已过期 / element invalid → `ErrStateStale`
  - `(pid, windowId)` 与 stateId 记录不一致 → `ErrWindowMismatch`
- `click({pid, windowId, x, y})` 不依赖 stateId，每次独立 hit-test
- 永远不隐式选窗口；agent 必须显式传 `windowId`

## RPC 方法

Shell 的 `ComputerUseHandlers.swift` 把 Kit public API 包装为 `computerUse.*` JSON-RPC 方法。完整 params / result / 错误码清单见 `rpc-protocol.md`。

| 方法 | 说明 |
|---|---|
| `computerUse.listApps` | 枚举可操作的 on-screen app |
| `computerUse.listWindows` | `{pid}` → 所有 layer-0 窗口及其 `windowId` / `bounds` / `isOnScreen` / `onCurrentSpace` |
| `computerUse.getAppState` | `{pid, windowId, captureMode?}` → `{stateId, axTree?, screenshot?}`，stateId TTL 30s |
| `computerUse.click` | `{pid, windowId, stateId, elementIndex, action?}`（语义化）或 `{pid, windowId, x, y, count?, modifiers?}`（坐标） |
| `computerUse.drag` | 起止坐标拖拽 |
| `computerUse.typeText` | Unicode 文本输入 |
| `computerUse.pressKey` | 单键 / 快捷键组合 |
| `computerUse.scroll` | 滚轮事件 |
| `computerUse.doctor` | `{accessibility, screenRecording, automation, skyLightSPI}` 权限和 SPI 解析状态 |

`captureMode` 三档：

- `som`（默认）— AX 树 + 截图
- `vision` — 仅截图，跳过 AX walk（无 Accessibility 权限也可用，节省 token）
- `ax` — 仅 AX 树，跳过截图（无 Screen Recording 权限也可用）

Bun 侧 tool registry 按 LLM provider 格式生成 tool schema，描述中明确声明 "all tools operate in background without stealing focus" 供 agent planner 参考。底层统一 `rpc.call("computerUse.xxx", params)`。

## 权限

运行时探测一律走 Shell 级 **`PermissionsService`**（OS Sense / Computer Use / 权限引导 UI 共用同一份 `PermissionState`）：

- **Accessibility**：`AXIsProcessTrusted()`
- **Screen Recording**：以 `SCShareableContent.current` 为真值（异步、低频、缓存结果），可选用 `CGPreflightScreenCaptureAccess` 作为 fast-path cache hint。`PermissionsService` 内部封装这一策略——历史上 `CGPreflightScreenCaptureAccess` 在子进程上下文有 false negative，统一服务可以避免双源探测漂移
- 探测时机：Shell 启动时跑一次；用户从 System Settings 回到应用、或调用方显式 invalidate 时重测
- `doctor` 方法不重新探测，直接读 `PermissionsService` 当前缓存

任一缺失时，AOS shell 调起权限引导 UI（属于 shell 层）。`doctor` 方法返回结构化状态：

- `accessibility: bool`
- `screenRecording: bool`
- `automation: bool` — OS Sense Finder adapter 用，Computer Use 本身不依赖
- `skyLightSPI: { postToPid, authMessage, focusWithoutRaise, windowLocation, spaces, getWindow }` — 每项 bool 表示对应 SPI 是否成功 dlsym 解析

不读 TCC.db。仅以系统 API 和 SPI 解析结果为准。

## 与 AOS 主进程的集成

```
┌────────────────────────────────────┐
│  AOS Shell (Swift, parent)         │
│  ┌──────────────────────────────┐  │
│  │  RPC Dispatcher              │  │
│  │  └─ ComputerUseHandlers      │  │
│  ├──────────────────────────────┤  │
│  │  AOSComputerUseKit (linked)  │  │  ← in-process 函数调用
│  │   └─ AXObservers 挂在 Shell  │  │
│  │      的 main runloop 上       │  │
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
- AXObserver 挂在 Shell 的 main runloop（SwiftUI shell 自带常驻 runloop），保证 Chromium AX 树持续开启
- Bun 通过 Shell↔Bun 的 JSON-RPC 通道发起 `computerUse.*` 请求
- Shell 的 `ComputerUseHandlers` 每个请求在独立 Swift Task 里 async 调用 Kit 方法，handler 之间互不阻塞
- 每 method 的 timeout 和并发模型由 `rpc-protocol.md` 统一定义

## 已知风险

| 风险 | 缓解 |
|---|---|
| SkyLight SPI 在 macOS 升级后 ABI 变化 | dlsym 解析失败自动降级到下一层路径，`doctor` 暴露每个 SPI 状态供前置自检 |
| 第三方 app AX 暴露度差异大 | Stage 4 显式测量各 app 成功率；坐标 fallback 兜底 |
| ScreenCaptureKit 在全屏游戏 / DRM 内容会黑屏 | `doctor` + `getAppState` 返回截图有效性 |
| 目标 window 在另一 Space 时 AX 树被砍空 | `SpaceDetector` 检测并返回 `ErrWindowOffSpace`，不做 SPI 迁移 |
| Chromium 在 backgrounding / tab 切换重置 AXEnhancedUserInterface | 每次 snapshot 重写 enablement 属性 |
| Chromium 渲染进程过滤 raw-CGEvent 事件 | 鼠标走 NSEvent-bridge 构造，键盘附 `SLSEventAuthenticationMessage` |
| 最小化窗口写 AXFocused 触发 Chrome deminiaturize | `FocusGuard` 显式跳过最小化窗口的 synthetic focus 层 |
| `StateCache` 内存随 stateId 增长 | TTL 30s 自动释放；单 `(pid, windowId)` 仅保最新 |
| App 窗口结构在 stateId TTL 内变化导致 elementIndex 错位 | Click 前校验目标 AXUIElement 仍 valid，否则返 `ErrStateStale` |

## 不做的事

- 不做 Space 迁移（`CGSMoveWindowsToManagedSpace` 等 SPI 在 macOS 14+ 对非 WindowServer 客户端是 silent no-op）
- 不向非 frontmost 进程使用全局 HID tap（会 warp 用户真实光标）
- 不读 TCC.db
- 不做 element detection / OCR
- 不做跨平台抽象层
- 不做操作录制回放
- 不输出独立 MCP 进程

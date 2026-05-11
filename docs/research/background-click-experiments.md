# Background Click Experiments

本文档记录 `post-left-click --pid --window-id` 的实验过程，避免上下文压缩后丢失关键观测。

## 目标

在目标窗口处于后台时，向目标窗口中心投放左键点击：

- 不移动真实鼠标指针。
- 不把目标窗口 raise 到用户窗口前面。
- 不让用户当前前台窗口发生可见 focus 变化。
- 先只验证 general app 路径，不考虑 Chromium renderer gate。

## 已知失败路径

1. `CGEvent.postToPid` 投递 `leftMouseDown/up`。
   - 结果：点击会触发窗口 raise。

2. `focusWindowWithoutRaise` 后接 `SLEventPostToPid`。
   - focus 本身不 raise。
   - 一旦投放 mouse event，目标窗口仍然 raise。

3. `SLEventPostToPid` 加 offscreen primer `(-1, -1)`。
   - 目标窗口仍然 raise。

4. CUA/yabai 风格 click preparer：`previous defocus` + `target focus`，跳过 key-window begin/end。
   - 用户复测仍然 raise。

## 当前诊断假设

单元测试只能证明事件构造和调用顺序，不能证明 WindowServer 的 z-order 没变化。下一步必须做 live trace：

- 每个阶段都采样 `CGWindowListCopyWindowInfo` 的 front-to-back order。
- 同时记录 `NSWorkspace.shared.frontmostApplication`。
- 把阶段拆开：`before`、focus 后、mouseMoved 后、primer down/up 后、target down 后、target up 后。

只有定位到具体触发 raise 的阶段后，才继续修改私有字段或投递路径。

## CUA 参考链路

`playground/cua/libs/cua-driver/Sources/CuaDriverCore/Input/MouseInput.swift` 的 left click general path：

1. `FocusWithoutRaise.activateWithoutRaise(targetPid, targetWid)`
2. sleep 50ms
3. `NSEvent.mouseEvent(... windowNumber: targetWindowID, timestamp: 0).cgEvent`
4. `mouseMoved` at target
5. offscreen `leftMouseDown/up` at `(-1, -1)`
6. target `leftMouseDown/up`
7. 每个 event：
   - screen location
   - `mouseEventButtonNumber = 0`
   - `mouseEventSubtype = 3`
   - `mouseEventClickState = 1`
   - `mouseEventWindowUnderMousePointer = targetWindowID`
   - `mouseEventWindowUnderMousePointerThatCanHandleThisEvent = targetWindowID`
   - `CGEventSetWindowLocation(windowLocalPoint)`
   - raw SkyLight field `40 = target pid`
8. `SLEventPostToPid(pid, event, attachAuthMessage: false)`

## 实验日志

### 2026-05-10

- 添加计划中的 `trace-postLeftClick` CLI，用真实 WindowServer order 验证每个阶段。
- 注意：测试启动 app 时避免 `open -a`，因为 CUA 文档明确指出 LaunchServices 会 activate 目标。需要启动测试 app 时优先使用 `/Applications/CuaDriver.app/Contents/MacOS/cua-driver call launch_app ...`。

### 双屏坐标

当前机器有两块屏幕。`NSScreen.screens` 观测到：

- 主屏：`{{0, 0}, {1512, 982}}`
- 第二屏：`{{-608, 982}, {2560, 1440}}`

目标窗口大多在第二屏，`CGWindowListCopyWindowInfo` 给出的 Quartz/global
坐标会出现负 `y`，例如 Calculator：

```text
X = 551, Y = -1118, Width = 230, Height = 408
```

因此窗口中心 screen point 是 `x + width / 2, y + height / 2`，例如
`(666, -914)`。CUA/Codex Computer Use 的 CLI 坐标不是这个坐标系：它们的
`x/y` 是窗口截图像素坐标，Retina 下通常是 point 的 2 倍。之前用
`x=88,y=266` 点 Calculator 实际只点到了 `x=44,y=133` points 附近，导致像
Delete；正确点按钮 `5` 的 screenshot pixel 是约 `x=176,y=532`。

### 当前 runner / TCC 身份

Codex 里的 shell 命令不是 Ghostty。当前命令由 Codex desktop 的 integrated
command runner 启动，TCC 责任身份是被执行的二进制本身：

- `.build/debug/AOSComputerUseCLI`
- 或 `/Users/puggo/Desktop/projects/aos/AOS.app/Contents/MacOS/AOS`

这两个在当时的临时 diagnostic 入口下都不是 AX trusted：

```text
AOS.app computer-use-cli ax-trusted -> {"axTrusted":false}
SLPSPostEventRecordTo -> OSStatus 1002
```

用户本机的 Ghostty 和 AOS 有 AX 权限，但这个权限不会自动转移给 Codex runner
里直接执行的 debug CLI。这个差异会影响 `SLPSPostEventRecordTo` 和后台 mouse
delivery 的 live 验证。

### Codex Computer Use 对照

用 Codex Computer Use 插件点同一个 AppKit probe：

- `NSWorkspace.shared.frontmostApplication` 仍然是 Codex。
- probe 内部 `NSEvent.addLocalMonitorForEvents` 和 `NSView.mouseDown` 收到真实
  mouse event。
- target window 最终排到 Codex 下方一位；它没有超过当前 frontmost Codex，但
  会高于其他后台窗口。

probe 记录到的成功事件字段：

```text
mouseMoved target:
  type=5 window=380579 locWin=(260,167) cgLoc=(-240,-285)
  f0=8 f1=1 f2=255 f3=0 f7=3 f40=43598 f41=42455
  f43=501 f44=20 f50=248 f51=380579 f55=5 f58=<same group>
  f91=380579 f92=380579 f102=63 f108=0

primer down/up in titlebar:
  cgLoc=(-470,-434), window-local ~= (30,16)
  f55=1 for down, f55=2 for up, f108=1 only on down

target down/up:
  cgLoc=(-240,-285), window-local ~= (260,165)
  same f58 group, f55 down/up, f108 down/up
```

关键结论：

- Codex Computer Use 的成功路径不是全局 HID tap；listen-only
  `cgAnnotatedSessionEventTap` / `cgSessionEventTap` / `cghidEventTap` 都没有看到
  mouse events。
- 但目标进程内部确实收到了 AppKit mouse events，所以不是单纯 AXPress。
- 成功链路需要一个有效的 CPS/AppKit focus 前置状态；仅补齐事件字段、或者在
  Codex runner 里调用 `SLEventPostToPid`，事件仍然不会进入 target AppKit。

### AOS 当前实现调整

代码已改为更贴近成功日志和 CUA recipe：

- click 专用 preparer 使用 `prev defocus + target focus` 的
  `SLPSPostEventRecordTo` recipe。
- 不再使用 `_SLPSSetFrontProcessWithOptions(kCPSNoWindows)`；它不 raise，但会把
  `NSWorkspace.frontmostApplication` 切到 target，而且实测仍不送达 mouse。
- mouse stream 只走 `SLEventPostToPid`，不再追加 `CGEvent.postToPid` public pair。
- decoy pair 放到窗口 titlebar 区域 `(30, 16)`，避免击中 content view。
- 补齐 raw fields：`f0/f2/f40/f43/f44/f50/f51/f55/f58/f59/f91/f92/f102/f108`。

当前 live 验证在 Codex runner 中仍卡在：

```text
focus unavailable: SLPSPostEventRecordTo failed: OSStatus 1002
```

这更像是 TCC/责任进程身份问题，而不是坐标或事件字段问题。若在已授权的 AOS
app 进程内运行，下一步应复测 `trace-postLeftClick` 的完整链路。

### Ghostty 身份验证方式

直接运行 Ghostty 二进制不可靠：

```text
/Applications/Ghostty.app/Contents/MacOS/ghostty -e ...
```

Ghostty 自己的 help 明确说明 macOS 上不能这样启动 terminal emulator，必须走
LaunchServices：

```text
open -na /Applications/Ghostty.app --args -e /bin/zsh /tmp/script.zsh
```

用这个方式启动的临时 Ghostty 能稳定执行 `.build/debug/AOSComputerUseCLI`，并且
`SLPSPostEventRecordTo` 不再返回 `OSStatus 1002`。因此 live trace 应通过这个
临时 Ghostty 窗口跑，而不是 Codex runner 直接跑。

### delayed raise 根因

给事件补齐 Codex Computer Use 成功日志里的 sender pid 字段后：

- raw field `40 = target pid`
- raw field `41 = sender pid`

`SLEventPostToPid` 能在已授权 Ghostty 身份下完成投递，但最初的 trace 发现 raise
不是同步发生在 `targetUp` 当下，而是在之后的 AppKit/WindowServer 激活补偿阶段。

无 post-click restore 的 fresh Calculator trace：

```text
before              target rank 3, frontmost Ghostty
afterTargetUp       target rank 4/3，仍在 Ghostty/Codex 后面
afterTargetUp250ms  target rank 1，Calculator 跳到所有窗口前面
afterTargetUp10s    target rank 1
```

因此真正要防的是点击完成后约 250ms 的 delayed raise，不只是 `down/up` dispatch
的同步阶段。

### 失败假设：target-only focus

把 click preparer 从 CUA/yabai 的 `front defocus + target focus` 临时改成
`target focus only` 后，结果更差：

```text
before         target rank 2
afterTargetDown target rank 1
afterTargetUp   target rank 1
```

这说明 `front defocus + target focus` 不是唯一的 raise 根因；它反而能避免某些
状态下的同步 `targetDown` raise。

### 已否定假设：只恢复当前 frontmost window

之前的“可工作 general path”结论是错误的，验证指标不够严格：

- 当时只确认 target 没有超过当前 frontmost window。
- 用户把 WeChat 叠在 Safari 上，然后向后台 Safari 投放点击，Safari 仍然 raise 到
  WeChat 前面。
- 因此现有实现只能保护“当前用户窗口”，不能保护完整 background z-order。

这个现象说明：`SLEventPostToPid` click 仍会触发 AppKit/WindowServer 的窗口顺序补偿。
只在 click 后恢复原 frontmost window 不够；必须恢复点击前 target 上方的所有相关窗口。

此前 fresh Calculator 验证只能证明“没有超过 Ghostty”：

```text
before                 target rank 2, frontmost Ghostty
afterTargetUp          target rank 3, frontmost Ghostty
afterFocusRestore      target rank 3, frontmost Ghostty
afterTargetUp250ms     target rank 2, frontmost Ghostty
afterTargetUp1s/3s/10s target rank 2, frontmost Ghostty
```

AppKit probe 验证点击实际送达：

```text
mouseDown window=380782 local=210.0,156.0 click=1
mouseUp   window=380782 local=210.0,156.0 click=1
```

同一次 probe trace：

```text
before                 target rank 2, frontmost Ghostty
afterTargetUp          target rank 3, frontmost Ghostty
afterFocusRestore      target rank 3, frontmost Ghostty
afterTargetUp250ms     target rank 2, frontmost Ghostty
afterTargetUp1s/3s/10s target rank 2, frontmost Ghostty
```

这个 trace 没有证明 target 仍低于其它后台窗口；WeChat-over-Safari 复测证明它会破坏
target 与其它 background windows 的相对顺序。

### Codex Computer Use binary analysis

Codex Computer Use bundle:

```text
/Users/puggo/.codex/plugins/cache/openai-bundled/computer-use/1.0.780/Codex Computer Use.app
```

主二进制：

```text
Contents/MacOS/SkyComputerUseService
```

二进制里没有直接暴露 `SLEventPostToPid`、`SLPSPostEventRecordTo`、`SLSOrderWindow`
等私有符号名，说明私有 API 可能通过 `dlsym` 拼接、封装在别处，或者根本不是这条路径。
但它有一组强相关的窗口顺序修复证据。

关键日志字符串：

```text
[SystemFrontmostApplicationTracker] Frontmost application changed: app=%s.
Failed to handle order change: %@
Raised "%s" over "%s" affter %ld attempts
Failed to raise "%s": %@
"%s" (%u) changed order while %s is frontmost
```

关键类型和字段：

```text
AccessibilitySupport.WindowOrderingObserver
WindowOrderingObserver.State
observedWindowIDs
AccessibilitySupport.SystemFrontmostApplicationTracker
AccessibilitySupport.ApplicationWindow
ApplicationWindow.cgWindow
ApplicationWindow.axWindow
ApplicationWindow.axApplication
AccessibilitySupport.SystemFocusStealPreventer
AccessibilitySupport.SyntheticAppFocusEnforcer
disallowedThiefProcesses
thiefPID
victimPID
```

`otool -ov` 确认：

- `ApplicationWindow` 同时持有 CG window、AX window、AX application。
- `SystemFrontmostApplicationTracker` 持有当前 frontmost app 和 observer 列表。
- `WindowOrderingObserver` 持有 `state`；字符串表里有 `observedWindowIDs`。

当前最可信假设：

1. Codex click 也会让目标窗口发生 order change。
2. `WindowOrderingObserver` 观察 layer-0 window order 或 WindowServer 事件。
3. 当某个 window 在 “X is frontmost” 的条件下 changed order，它判断这是 synthetic
   click 导致的非预期 raise。
4. 它把原本在 target 上方的 window raise 回 target 上方，并记录：
   `Raised "%s" over "%s" affter %ld attempts`。

这更像是“点击后侦测并修复 z-order”，不是“找到一个天然不 raise 的 mouse event
delivery API”。

### 下一步实现假设：order guardian

AOS 后台点击链路应拆成两个独立部分：

1. Event delivery：继续使用当前能送达 AppKit 的 `focus without raise + SLEventPostToPid`
   路径。
2. Order repair：点击前记录 target 上方的 layer-0 windows；点击后持续采样
   250ms/1s/3s。如果 target 越过任何原本在它上方的窗口，就把那些窗口按原顺序 raise
   回 target 上方。

严格验证条件：

- 前台 app 从始至终不变。
- 前台 window 从始至终不变。
- target click 确实送达。
- 点击前所有 `rank < targetRank` 的窗口，点击后仍然在 target 前面。

待验证的 repair 机制：

- `AXRaise`：Codex 二进制包含 `AXRaise` action string，且 `ApplicationWindow`
  有 `axWindow`；这是最直接候选，但还不能确认 Codex 的 order repair 一定用它。
- 私有 SLS/CGS order API：如果 `AXRaise` 也引发 focus/activation 副作用，需要继续找
  非激活的 WindowServer order API。

不要再把“恢复 current frontmost window”当作完成标准；用户的 WeChat-over-Safari
场景才是当前正确验收标准。

### Codex order repair 反汇编补充

`WindowOrderingObserver` 附近的反汇编进一步确认它不是单纯记录日志，而是在做一个
“观察 order -> 重采样 -> 尝试 raise -> 延迟重试”的 repair loop。

关键地址和证据：

```text
0x10058aa40 -> log: "%s" (%u) changed order while %s is frontmost
0x10058aaec -> CGWindowListCreate
0x10058ab08..0x10058ac64 -> 遍历 CGWindowListCreate 返回的窗口数组，提取 window id
0x10058ad90 / 0x10058b7b8 -> 调用内部 repair 函数，失败后进入 Failed to raise 路径
0x10058b2bc -> ContinuousClock.now / sleep until，说明有异步延迟重试
0x10058b428 / 0x10058bc34 -> log: Raised "%s" over "%s" affter %ld attempts
0x10058bd70 -> log: Failed to raise "%s": %@
```

这和实测的 delayed raise 时间线吻合：target click 后不是只在 `mouseUp` 同步 raise，
还有 250ms 左右的 WindowServer/AppKit 补偿。因此 AOS 也需要点击后短时间持续
guard order，而不是只在 `targetUp` 后做一次 restore。

二进制里还存在通用 AX action wrapper：

```text
0x1004edbbc -> AXUIElementPerformAction
0x1004edd1c -> AXUIElementPerformAction
```

字符串表里 `AXPress / AXPick / ... / AXRaise / AXShowMenu` 连续出现。结合
`ApplicationWindow.axWindow`，`AXRaise` 仍是 repair primitive 的强候选；但目前没有
从 `WindowOrderingObserver` 的 repair call site 直接追到 `AXUIElementPerformAction`
的证据，不能把它写死为已确认结论。

### SLSOrderWindow direct probe

本机 SkyLight 里能通过 `dlsym` 找到这些符号：

```text
SLSOrderWindow true
CGSOrderWindow true
SLSMainConnectionID true
CGSMainConnectionID true
```

但直接在当前 Codex runner 进程里调用：

```swift
typealias Main = @convention(c) () -> UInt32
typealias Order = @convention(c) (UInt32, UInt32, Int32, UInt32) -> Int32
let cid = SLSMainConnectionID()
SLSOrderWindow(cid, 375156, 1, 380386)
```

返回：

```text
status 1000
```

换 `CGSMainConnectionID` / `CGSOrderWindow` 组合也一样返回 `1000`。所以当前不能假设
“直接 SLSOrderWindow 就能修复”。可能原因包括调用签名、order mode、connection
权限/责任进程、或目标窗口状态不满足要求；这些都还没有被证明。

### 当前结论修正

general AppKit event delivery 已经能让后台窗口收到中心左键，但**没有满足**完整
background z-order preservation。当前实现最多恢复 current frontmost window；用户的
WeChat-over-Safari 复测证明 target 仍会越过其它后台窗口。

下一步必须实现并验证 order guardian：

1. 点击前采样完整 layer-0 front-to-back order。
2. 记录 `target` 之前所有应保持在它上方的 windows。
3. 点击后在 250ms/1s/3s 窗口内持续采样。
4. 一旦 target 越过任意 protected window，使用待验证的 non-activating order
   primitive 把 protected window 放回 target 上方。
5. 验收以 WeChat-over-Safari 场景为准，而不是只检查 target 没有超过当前 frontmost。

### 2026-05-11 implementation: AXRaise order guardian

本轮实现采用 Codex 二进制分析指向的 repair 模型，而不是继续寻找“不触发 raise 的
mouse delivery”：

- `WindowOrderGuardian`：点击前记录 `target` 前面的 layer-0/on-screen/normal-size
  windows，点击后如果 target 越过这些 protected windows，就按原 front-to-back 顺序
  修复。
- `AXWindowRaiser`：通过 `AXUIElementCreateApplication(pid)` 读取
  `kAXWindowsAttribute`，用 `_AXUIElementGetWindow` 匹配 `CGWindowID`，然后对对应
  AX window 执行 `AXRaise`。
- `ComputerUseCore.postLeftClick`：保留现有 `focus without raise + SLEventPostToPid`
  事件投放；点击后按 `0ms / 250ms / 1s / 3s` repair order，并在发生 repair 后重新
  focus 原 front window without raise。
- `trace-postLeftClick`：每个延迟采样点前先 repair，再记录 WindowServer order，方便
  验证最终和 delayed order。

单元测试新增两个关键 case：

- target click 后越过 protected windows 时，必须 raise `protectedBack` 再 raise
  `protectedFront`，恢复原顺序。
- 原本就在 target 后面的窗口即使仍在 target 后面，也不能被错误 repair。

验证命令：

```text
swift test --filter WindowClickTests
swift test
```

结果：`WindowClickTests` 6 个 case 通过；全量 `swift test` 280 个 tests 通过，1 个
existing known issue。

### 2026-05-11 live verification

直接从 Codex runner 执行 CLI 仍不可用：

```text
AXIsProcessTrusted() -> false
AOSComputerUseCLI trace-postLeftClick --pid 78260 --window-id 380386
=> focus unavailable: SLPSPostEventRecordTo failed: OSStatus 1002
```

通过已有 AX 权限的 Ghostty 启动同一个 CLI 后可以验证真实桌面 order：

```text
AXIsProcessTrusted() -> true
```

目标：Safari `pid 78260`, `window 380386`, center `134,-592`。测试时窗口 order：

```text
before: frontmost Ghostty, target rank 6, above 5
afterFocus: frontmost Ghostty, target rank 6, above 5
afterTargetDown: frontmost Ghostty, target rank 1, above 0
afterTargetUp: frontmost Ghostty, target rank 1, above 0
afterFocusRestore: frontmost Ghostty, target rank 6, above 5
afterTargetUp250ms: frontmost Ghostty, target rank 6, above 5
afterTargetUp1s: frontmost Ghostty, target rank 6, above 5
afterTargetUp3s: frontmost Ghostty, target rank 6, above 5
afterTargetUp10s: frontmost Ghostty, target rank 6, above 5
```

这个 trace 说明两个事实：

1. `SLEventPostToPid` mouse down/up 仍然会让 WindowServer 把 Safari 临时 raise 到
   rank 1；这个路径不是 prevent-raise。
2. `AXRaise` order guardian 能在点击后把 Safari 压回原来的 protected windows 之后；
   frontmost application 全程保持 Ghostty。

生产命令 `post-left-click` 也通过 Ghostty 路径验证：

```text
BEFORE
#5 WeChat(pid 41620, wid 375156)
#6 Ghostty(pid 39830, wid 375128)
#7 Safari(pid 78260, wid 380386)

POST_START
Posted left click to window 380386 at 134,-592 (pid 78260).
POST_EXIT=0

AFTER_RETURN
#5 WeChat(pid 41620, wid 375156)
#6 Ghostty(pid 39830, wid 375128)
#7 Safari(pid 78260, wid 380386)

AFTER_1S
#5 WeChat(pid 41620, wid 375156)
#6 Ghostty(pid 39830, wid 375128)
#7 Safari(pid 78260, wid 380386)

AFTER_4S
#5 WeChat(pid 41620, wid 375156)
#6 Ghostty(pid 39830, wid 375128)
#7 Safari(pid 78260, wid 380386)
```

当前结论：

- 对 general AppKit path，后台点击链路已经跑通：命令返回后和 delayed 采样里，target
  没有停留在前面，原先盖在它上面的窗口仍在它上面。
- 这不是“点击永不触发 raise”，而是和 Codex 二进制线索一致的“触发后立即修复”。
- 剩余风险是极短窗口内的 visual flicker：trace 在 `afterTargetDown/afterTargetUp`
  能看到 target rank 1。当前生产路径在 `post-left-click` 返回前修复；如果需要证明
  屏幕上完全不可见闪动，下一步应把 repair hook 推进到 mouse post stage 内部，或继续
  寻找真正 non-raising 的 WindowServer order primitive。

### 2026-05-11 follow-up: prior result is not Codex-quality

User retest showed two critical gaps:

1. Final order restoration is not enough. The target visibly raises and is moved
   back later.
2. The previous `SkyLightMouseClickFocuser` defocuses the user's front process,
   so the user's active window visibly deactivates and reactivates.

This means the prior implementation is only a repair proof, not the desired
Codex Computer Use behavior.

Important validation caveat: automated live verification through
`open -na /Applications/Ghostty.app ...` is contaminated. It creates new
Ghostty windows and may trigger macOS permission prompts; both can change active
application state and WindowServer order. Codex Computer Use MCP also refuses to
operate Ghostty directly, so future live validation must be run manually from an
already-open, already-trusted Ghostty terminal.

Additional experiments before stopping automatic Ghostty launches:

- Titlebar primer + broad raw fields: target raises immediately at
  `afterTargetDown/afterTargetUp`.
- CUA-like off-screen primer `(-1,-1)` + minimal raw field 40: immediate
  mouseDown raise disappears, but delayed raise still appears around
  250ms unless order repair catches it.
- Removing the Chromium primer for the general path (`mouseMoved -> down -> up`)
  still keeps immediate mouseDown from raising when using the CUA defocus/focus
  handoff. It also cuts the visible defocus window substantially because the
  old 100ms primer delay is gone.
- Reducing focus settle from 50ms to 5ms still works in the contaminated live
  trace. This suggests the old 50ms delay is too conservative for the general
  path.
- Dense order repair at 8ms intervals catches some delayed raises quickly, but
  the contaminated trace still observed a Safari delayed raise at `AFTER_1S`
  after a 40-iteration/320ms guard window. A short guard is not sufficient.

Current experimental code state:

- Mouse event general path is now `mouseMoved -> targetDown -> targetUp` with
  only raw SkyLight field 40 stamped, no Chromium off-screen primer.
- Focus preparer is being tested as target-only focus (no front-process
  defocus) to avoid deactivating the user's window. This still needs manual live
  verification because the earlier target-only test included the Chromium
  primer and raised immediately.
- Repair polling uses dense 8ms intervals in the live schedule.

Manual validation command to run in the existing trusted Ghostty terminal:

```zsh
cd /Users/puggo/Desktop/projects/aos
swift build
.build/debug/AOSComputerUseCLI trace-postLeftClick --pid 78260 --window-id 380386
```

What to check:

- `frontmost` should remain the user's current app for every stage.
- `target rank` must not jump to `1` at `afterTargetDown` or `afterTargetUp`.
- User-visible front window chrome must not gray out. If it still grays out,
  target-only focus is not enough and the solution needs a real focus-preventer
  primitive rather than SLPS defocus/focus.

Manual validation result from trusted Ghostty:

```text
before:          frontmost Ghostty, target rank 4
afterFocus:      frontmost Ghostty, target rank 4
afterMouseMoved: frontmost Ghostty, target rank 4
afterTargetDown: frontmost Ghostty, target rank 4
afterTargetUp:   frontmost Ghostty, target rank 4
afterFocusRestore: frontmost Ghostty, target rank 4
afterTargetUp250ms: frontmost Ghostty, target rank 1
afterTargetUp1s:    frontmost Ghostty, target rank 2
afterTargetUp3s:    frontmost Ghostty, target rank 4
afterTargetUp10s:   frontmost Ghostty, target rank 4
```

Interpretation:

- `target-only focus + no Chromium primer` fixes the immediate mouseDown raise.
- It also avoids stealing `frontmost`; the user window stayed Ghostty for every
  stage.
- Remaining bug is delayed WindowServer/AppKit raise after mouseUp. It can
  appear around 250ms and may require multiple repairs before the full protected
  order is restored.

Follow-up code change:

- `trace-postLeftClick` now continuously repairs during the 0-250ms,
  250ms-1s, and 1s-3s windows instead of doing one repair at each sample point.
- `post-left-click` now uses a 250ms live order-guardian window with 8ms polling.
  The longer 3s/10s observation windows stay in `trace-postLeftClick` for
  diagnosis instead of blocking the production command.
- Added a regression test for repeated delayed raise: if the target crosses the
  same protected windows again on a later sample, the guardian must repair them
  again.

### 2026-05-11 two-display validation correction

The previous trace output used global `target rank` from `CGWindowListCopyWindowInfo`.
That is useful but not sufficient on a two-display setup:

- Safari / WeChat / Codex were on the secondary display.
- Ghostty / Cursor were on the Mac display.
- A target can change global rank relative to windows on another display without
  visually covering them.

The correct visible invariant is narrower:

1. `NSWorkspace.frontmostApplication` should remain the user's active app.
2. Every layer-0 window that geometrically overlapped the target and was above
   it before the click must remain above it.
3. Non-overlapping windows should not be repaired, even if they were globally
   above the target, because raising them back can introduce unrelated flicker.

Implementation adjustment:

- `WindowOrderGuardian` now protects only windows that overlap the target bounds
  and were above the target before the click.
- `trace-postLeftClick` still prints global `target rank`, but also prints:
  - `overlap-above`: currently overlapping windows above the target.
  - `protected-covered`: windows that overlapped and were above the target in
    the `before` snapshot but are now below the target.

For live validation, `protected-covered 0` is the important z-order condition.
`target rank 1` can still be meaningful if all windows are on the same display
and overlap the target, but it is not the right generic metric across displays.

User then moved all relevant app windows to the secondary display. That makes
the experiment cleaner because global rank and visible overlap are more likely
to agree, but the trace should still be judged primarily by `protected-covered`.

Manual validation after moving all app windows to the secondary display:

```text
before:             frontmost Ghostty, target rank 3, above 2, overlap-above 1, protected-covered 0
afterFocus:         frontmost Ghostty, target rank 3, above 2, overlap-above 1, protected-covered 0
afterMouseMoved:    frontmost Ghostty, target rank 3, above 2, overlap-above 1, protected-covered 0
afterTargetDown:    frontmost Ghostty, target rank 3, above 2, overlap-above 1, protected-covered 0
afterTargetUp:      frontmost Ghostty, target rank 3, above 2, overlap-above 1, protected-covered 0
afterFocusRestore:  frontmost Ghostty, target rank 3, above 2, overlap-above 1, protected-covered 0
afterTargetUp250ms: frontmost Ghostty, target rank 3, above 2, overlap-above 1, protected-covered 0
afterTargetUp1s:    frontmost Ghostty, target rank 3, above 2, overlap-above 1, protected-covered 0
afterTargetUp3s:    frontmost Ghostty, target rank 3, above 2, overlap-above 1, protected-covered 0
afterTargetUp10s:   frontmost Ghostty, target rank 3, above 2, overlap-above 1, protected-covered 0
```

Observed order in that run:

```text
#1 Ghostty
#2 Codex
#3 Safari target
#4 WeChat
```

Interpretation:

- The target-only focus + minimal general mouse path did not trigger immediate
  target raise at `afterTargetDown` / `afterTargetUp`.
- `frontmost` remained Ghostty for every stage.
- The one protected overlapping window stayed above Safari through all delayed
  sampling windows.
- This run validates the Codex-over-Safari protected case. It does not validate
  the original WeChat-over-Safari case because WeChat was below Safari in this
  specific order.

Manual validation of the original WeChat-over-Safari case:

Setup:

- Ghostty was moved back to the Mac display for easier command entry.
- WeChat was visibly above Safari on the secondary display.
- WeChat was not focused or active before the command.
- Target remained Safari `pid 78260`, `window 380386`, center `134,-592`.

Trace:

```text
before:             frontmost Ghostty, target rank 3, above 2, overlap-above 1, protected-covered 0
afterFocus:         frontmost Ghostty, target rank 3, above 2, overlap-above 1, protected-covered 0
afterMouseMoved:    frontmost Ghostty, target rank 3, above 2, overlap-above 1, protected-covered 0
afterTargetDown:    frontmost Ghostty, target rank 3, above 2, overlap-above 1, protected-covered 0
afterTargetUp:      frontmost Ghostty, target rank 3, above 2, overlap-above 1, protected-covered 0
afterFocusRestore:  frontmost Ghostty, target rank 3, above 2, overlap-above 1, protected-covered 0
afterTargetUp250ms: frontmost Ghostty, target rank 3, above 2, overlap-above 1, protected-covered 0
afterTargetUp1s:    frontmost Ghostty, target rank 3, above 2, overlap-above 1, protected-covered 0
afterTargetUp3s:    frontmost Ghostty, target rank 3, above 2, overlap-above 1, protected-covered 0
afterTargetUp10s:   frontmost Ghostty, target rank 3, above 2, overlap-above 1, protected-covered 0
```

Observed order in that run:

```text
#1 Ghostty
#2 WeChat
#3 Safari target
#4 Codex
```

User-visible observation:

- During the run, Safari became focus/active for routed input.
- Safari did not visibly raise above WeChat.
- After the run, Safari still had not raised above WeChat.
- The user did not observe any Safari raise flicker.

Current conclusion for the general AppKit path:

- The target-only focus preparer avoids stealing the user's frontmost app.
- The minimal `mouseMoved -> leftMouseDown -> leftMouseUp` SkyLight path avoids
  immediate mouseDown/mouseUp raise in the verified WeChat-over-Safari setup.
- The overlap-based order guardian stayed at `protected-covered 0` through the
  delayed sampling windows.
- This satisfies the current `post-left-click --pid --window-id` background-click
  goal for non-Chromium/general apps, subject to a final production-command
  check with `post-left-click` rather than the diagnostic trace command.

### 2026-05-11 CLI cleanup

After several successful manual `post-left-click` runs, the production command
no longer needs the intentionally conservative 3s synchronous guard window:

- CLI command renamed from `postLeftClick` to `post-left-click`.
- The old camelCase command is intentionally not accepted.
- Production `post-left-click` guard window first reduced to 250ms with 8ms polling,
  then reduced again to 0ms. The production command now performs only the
  immediate post-click repair pass and does not wait for delayed polling.
- Diagnostic `trace-postLeftClick` keeps the longer 3s/10s observation windows.

Verification:

```text
swift test --filter ComputerUseCLITests --filter WindowClickTests
swift test
```

Result: both targeted tests and full test suite passed. Full suite result:
`283 tests in 43 suites passed with 1 known issue`.

### 2026-05-11 coordinate target CLI

Added a dedicated coordinate-click probe to make background event delivery easier
to verify without manually choosing application windows:

- New SwiftPM executable: `AOSCoordinateTarget`.
- `AOSComputerUseCLI open` launches `AOSCoordinateTarget` as a separate process
  with its own pid and AppKit window.
- The target window draws a top-left-origin coordinate grid and writes AppKit
  mouse events to `~/.aos/run/coordinate-target-events.jsonl`.
- `AOSComputerUseCLI test --coor <x,y>` reads the last opened target state,
  converts the local window coordinate to a screen point, and calls the same
  `ComputerUseCore.postLeftClick` background click chain used by production.
- `ComputerUseCore.postLeftClick(pid:windowId:point:)` was added for explicit
  screen-space click points; the center-click helper delegates to it.

Usage:

```zsh
swift build
.build/debug/AOSComputerUseCLI open
.build/debug/AOSComputerUseCLI test --coor 120,80
tail -n 5 ~/.aos/run/coordinate-target-events.jsonl
```

Verification:

```text
swift test --filter ComputerUseCLITests
swift test --filter ComputerUseCLITests --filter WindowClickTests
swift test
```

Result: full suite passed with `287 tests in 43 suites` and 1 existing known
issue.

### 2026-05-11 coordinate target delivery gap

Manual run:

```text
.build/debug/AOSComputerUseCLI test --coor 120,80
Posted coordinate test click
- target pid 36632, window 382572
- local 120,80
- screen 432,-1097
- events /Users/puggo/.aos/run/coordinate-target-events.jsonl
```

Observation:

- The target window did not raise, which confirms the order-guardian path still
  behaves correctly.
- The coordinate target did not visually update, and
  `~/.aos/run/coordinate-target-events.jsonl` was still 0 bytes.
- Running the same command from the Codex runner failed earlier at
  `SLPSPostEventRecordTo failed: OSStatus 1002`, so live end-to-end validation
  must still be run from the already trusted Ghostty/AOS terminal.

Interpretation:

- The bug is not in the target view's drawing path alone: no event reached the
  target's `mouseDown` / `mouseUp` logging path.
- CUA's implementation notes explicitly call out a split between the two
  cursor-neutral pid-routed mouse paths: SkyLight is useful for Chromium-style
  trust, while ordinary AppKit targets often drain the public
  `CGEvent.postToPid` path. The current AOS implementation was only posting via
  `SLEventPostToPid`.

Code changes from this finding:

- `AOSCoordinateTarget` now installs a local AppKit mouse monitor and records
  `localMonitor:*` events to the same JSONL file. This distinguishes "event
  entered the target process but did not dispatch to the view" from "event never
  entered the target process".
- `AOSCoordinateTarget`'s canvas accepts first mouse and first responder status
  so the probe itself does not filter an inactive-window click before the event
  can be observed.
- `AOSComputerUseCLI test --coor` now snapshots the event-log byte offset before
  posting, waits briefly for new JSONL records, and fails loudly when the target
  records no event. A successful command prints the recorded event rows.
- `MouseEventPoster` now posts each stamped move/down/up event through both
  `SLEventPostToPid` and public `CGEvent.postToPid`. Both are pid-scoped and
  cursor-neutral; this is not a HID fallback and should not move the user's
  cursor.

Retest command:

```zsh
swift build
.build/debug/AOSComputerUseCLI open
.build/debug/AOSComputerUseCLI test --coor 120,80
```

Expected useful outcomes:

- If the command prints `recorded ... localMonitor:leftMouseDown`, the event is
  entering the target process.
- If it also prints `mouseDown` / `mouseUp`, the view dispatch path is working.
- If it exits with `coordinate target recorded no mouse events after post`, the
  current pid-routed event route still is not entering AppKit from the trusted
  terminal.

Verification after the instrumentation / dual-post change:

```text
swift test --filter WindowClickTests --filter ComputerUseCLITests
swift test
```

Result: full suite passed with `288 tests in 43 suites` and 1 existing known
issue.

### 2026-05-11 correction: coordinate target raise after successful delivery

User retest after the dual-post instrumentation:

```text
.build/debug/AOSComputerUseCLI test --coor 120,80
Posted coordinate test click
- target pid 42677, window 382673
- local 120,80
- screen 516,231
- events /Users/puggo/.aos/run/coordinate-target-events.jsonl
- recorded 5 event(s)
- localMonitor:mouseMoved local 120,80 screen 516,751 window 382673
- localMonitor:leftMouseDown local 120,80 screen 516,751 window 382673
- mouseDown local 120,80 screen 516,751 window 382673
- localMonitor:leftMouseDown local 120,80 screen 516,751 window 382673
- mouseDown local 120,80 screen 516,751 window 382673
```

Interpretation:

- The coordinate target can receive background AppKit mouse events.
- The duplicate `leftMouseDown` / `mouseDown` rows prove the temporary dual-post
  route posted the same down through two pid-scoped channels. That route is not
  acceptable as production behavior.
- The missing `mouseUp` in the printed output was partly a CLI observation bug:
  `test --coor` returned as soon as any event appeared. It now waits briefly for
  a `mouseUp` / `leftMouseUp` row before printing the event batch.
- The user-visible target raise came back because production order repair had
  been reduced to a single 0ms pass. That is too short for the public pid route:
  AppKit / WindowServer can still perform a delayed order compensation after the
  CLI has already returned and exited.

Code correction:

- `MouseEventPoster` now posts each stamped move/down/up exactly once through
  the public `CGEvent.postToPid` route. It keeps the rich window-local and raw
  pid/window fields, but does not dual-post through SkyLight.
- `ComputerUseCore.postLeftClick` passes a stage observer into the mouse poster.
  After `mouseMoved`, `leftMouseDown`, and `leftMouseUp`, it immediately runs one
  order repair pass. This is the closest short-lived CLI equivalent to Codex's
  in-process `WindowOrderingObserver`.
- Production `post-left-click` / `test --coor` now keep a 250ms post-click guard
  window with 8ms polling. This is intentionally shorter than the earlier
  multi-second diagnostic trace, but long enough to catch the delayed raise class
  observed around the 250ms mark.

Verification so far:

```text
swift test --filter WindowClickTests --filter ComputerUseCLITests
```

Result: targeted tests passed (`26 tests in 2 suites`).

### 2026-05-11 deeper Codex binary analysis

The Codex Computer Use service contains a richer focus/order system than AOS
currently has. Relevant classes from ObjC/Swift metadata:

```text
AccessibilitySupport.EventTap
  ivars: onEventReceived, eventTypes, location, options,
         shouldAutoreenable, eventTapMachPort, monitoringTask

AccessibilitySupport.SyntheticAppFocusEnforcer
  ivars: pid, frontmostApplicationTracker, frontmostApplicationObserver,
         clickEventTap, _state

AccessibilitySupport.SystemFocusStealPreventer
  ivars: disallowedThiefProcesses, systemState,
         systemProcessNotificationTap, viewBridgeKeyboardTap

AccessibilitySupport.SystemFrontmostApplicationTracker
  ivars: observers, excludeCurrentApp, applicationObserver,
         currentFrontmostApp

AccessibilitySupport.WindowOrderingObserver
  ivars: state
```

`WindowOrderingObserver` disassembly confirms the repair architecture:

```text
0x10058aa40  log "\"%s\" (%u) changed order while %s is frontmost"
0x10058aaec  CGWindowListCreate
0x10058ab08  CFArrayGetCount / CFArrayGetValueAtIndex loop
0x10058ac28  objc_msgSend windowNumber extraction from window dictionaries
0x10058ad90  call repair routine
0x10058b2bc  ContinuousClock.now
0x10058b3ac  ContinuousClock.sleep(until:)
```

The repair routine at `0x10058e078` has a direct `AXRaise` path:

```text
0x10058e740  classify repair primitive
0x10058e748  compare class == 4
0x10058e760  call 0x1004eda44
0x1004edbbc  AXUIElementPerformAction
```

This confirms the earlier hypothesis: Codex does not rely solely on finding a
mouse posting API that never raises. It has a live observer that detects order
changes while the user app remains frontmost, then repairs with
`AXUIElementPerformAction("AXRaise")` and retries after a short sleep.

The binary also has a separate focus-steal layer:

```text
SyntheticAppFocusEnforcer
SystemFocusStealPreventer
focusThiefAlsoStoleTypingFocus
clickEventTap
systemProcessNotificationTap
viewBridgeKeyboardTap
```

Current AOS state relative to Codex:

- AOS matches the order-repair primitive (`AXRaise`) and now runs immediate
  per-stage repair plus a short delayed guard.
- AOS does not yet implement Codex's full focus-steal prevention layer. The
  current target-only SLPS focus preparer avoids defocusing the user's front app
  in the verified Safari/WeChat traces, but there is not yet a persistent
  `SystemFocusStealPreventer` equivalent.
- Because AOSComputerUseCLI is a short-lived process, a 0ms guard is not
  equivalent to Codex. Codex's observer remains alive after event dispatch; the
  CLI must either wait briefly, spawn a detached repair helper, or move this
  feature into the long-lived AOS app process.

### 2026-05-11 retry cadence correction

Further disassembly of `WindowOrderingObserver` exposed the retry cadence:

```text
0x10058b2bc  ContinuousClock.now
0x10058b2c4  load Swift Duration literal
0x10058b3ac  ContinuousClock.sleep(until:)
0x10058b66c  cmp attemptCount, #0x28
```

The duration literal at `0x100a89b90` decodes to 5ms
(`0x0011c37937e08000` attoseconds), and `0x28` is 40 attempts. This means Codex
does roughly 5ms-spaced retries after detecting an order change, for about
200ms of observer-driven repair.

AOS does not yet have that persistent event-driven observer in the CLI process,
so the production guard now uses the same 5ms cadence but a slightly wider
300ms window. The wider window is deliberate: the CLI starts polling before the
delayed AppKit/WindowServer raise is observable, while Codex starts its retry
loop after its `WindowOrderingObserver` has already seen the order change.

Local validation limitation in this Codex session:

- Direct `.build/debug/AOSComputerUseCLI test --coor 120,80` from the Codex
  command runner still fails with `SLPSPostEventRecordTo failed: OSStatus 1002`
  because this runner is not the trusted Ghostty/AOS TCC identity.
- New `open -na /Applications/Ghostty.app --args -e ...` attempts created
  Ghostty processes but did not execute the script or write output; this is not
  a reliable automated validation path.
- `screencapture` from the runner produced a black image, so screen observation
  from this identity is also not reliable.

The next trustworthy live check must still be launched from the already-open,
already-authorized Ghostty or AOS process.

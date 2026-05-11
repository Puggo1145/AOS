# Focus Without Raise 研究记录

本文记录 AOS 在 `AOSComputerUseKit` 中跑通的 macOS window focus-without-raise 实现原理。目标是给定 `pid + CGWindowID`，让目标窗口进入可接收后台输入的 focused/key-window 状态，同时不改变窗口 z-order，不触发 Space follow。

参考来源：

- `playground/yabai/src/window_manager.c`
- `playground/cua/libs/cua-driver/Sources/CuaDriverCore/Input/FocusWithoutRaise.swift`
- AOS 实现：`Sources/AOSComputerUseKit/Windows/SkyLightWindowFocuser.swift`

## 结论

跑通后的实现需要两组 SkyLight event record，全部投递到 **目标 PSN**：

1. `focus` event：切换输入路由层，让目标 app/window 可以响应定向鼠标和键盘事件。
2. `key-window` event：补齐 AppKit/WindowServer 的 key-window 状态，让窗口 chrome 更接近完整 focus，例如红绿灯不再保持纯后台灰态。

关键点：

- **不调用 `_SLPSSetFrontProcessWithOptions`**。这个 API 更接近系统前台 app/window 激活，会带来 raise 或 Space follow 风险，不适合作为 AOS 的 background computer-use primitive。
- **不再向前一个 front PSN 投递 `defocus` event**。yabai 只在同 PSN 内切换窗口时才会投递 defocus（一个 app 内同一时间只能有一个 key window）；跨 app 时它走 `_SLPSSetFrontProcessWithOptions`，那条路径会顺带把上一个 app 切到 inactive。AOS 因为跳过了 `_SLPSSetFrontProcessWithOptions`，如果还坚持发 defocus，等于无条件让上一个 app 失去 key 状态而没有任何东西把它重新拉回来。手工实验已确认 WindowServer 允许两个跨 app 的窗口同时处于 active key-window 状态（在 focus-without-raise 后手动点回原窗口，两个窗口都保持 active）。因此只要不发那条 defocus，原窗口就不会被 deactive。

## 目标行为

实现成功后，目标窗口具备这些性质：

- 可以在后台响应定向鼠标事件，例如 hover、click。
- 可以在后台响应定向键盘事件。
- 窗口进入更完整的 key-window/focused 状态，视觉 chrome 不再停留在完全后台状态。
- 窗口不被 raise。
- 当前 Space 不被切换到目标窗口所在 Space。

该能力仍不是完整的用户前台切换。系统菜单栏、全局前台 app 语义、Dock 激活状态等不应该依赖它。

## API 与权限

AOS 当前暴露的入口：

```swift
try await ComputerUseCore.focusWindowWithoutRaise(pid: pid, windowId: windowId)
```

CLI 入口：

```bash
.build/debug/AOSComputerUseCLI focus-window --pid <pid> --window-id <id>
```

实现前置条件：

- 目标 `windowId` 必须属于给定 `pid`。`ComputerUseCore` 先通过 `WindowEnumerator.window(forId:)` 校验 ownership，失败则直接抛错。
- 运行 CLI 或宿主进程的 terminal/app 需要 Accessibility permission。缺失时 fail fast。
- 需要能解析并调用 SkyLight/HIServices 私有符号：
  - `GetProcessForPID`
  - `SLPSPostEventRecordTo`

不再需要 `_SLPSGetFrontProcess`：当前实现完全不读取前一个 front PSN，也不会向它投递任何事件。

## 事件顺序

最终顺序如下（全部针对 **目标 PSN**）：

```text
GetProcessForPID(targetPid, &targetPSN)

SLPSPostEventRecordTo(targetPSN, focusEvent(windowId))
SLPSPostEventRecordTo(targetPSN, keyWindowEvent(windowId, phase: begin))
SLPSPostEventRecordTo(targetPSN, keyWindowEvent(windowId, phase: end))
```

注意这里刻意没有：

```text
_SLPSGetFrontProcess(...)
SLPSPostEventRecordTo(previousPSN, focusEvent(..., marker: defocus))
_SLPSSetFrontProcessWithOptions(...)
AXRaise
SLSOrderWindow
```

- 跳过 `_SLPSSetFrontProcessWithOptions`、`AXRaise`、`SLSOrderWindow`：这些操作都会把语义推向“用户可见的前台激活 / 重排窗口”，不是 AOS 需要的后台操作 primitive。
- 跳过对 previousPSN 的 defocus：那条事件就是之前实现里让原窗口被 deactive 的唯一原因。省略后，原 app 维持原本的 key-window 状态。

## Focus Event Record

这组事件来自 yabai/cua 的 focus-without-raise path，用于更新目标 app/window 的输入路由状态。AOS 只投递 marker = `0x01`（focus）的版本到目标 PSN，永远不投递 marker = `0x02`（defocus）。

buffer 大小固定为 `0xf8` bytes，关键字段：

| Offset | Value | 含义 |
|---:|---:|---|
| `0x04` | `0xf8` | event record size/opcode high |
| `0x08` | `0x0d` | focus event opcode |
| `0x3c...0x3f` | little-endian `CGWindowID` | 目标 window id |
| `0x8a` | `0x01` | focus target（AOS 唯一使用的值） |
| `0x8a` | `0x02` | defocus previous（**AOS 不再使用** —— 它会让原窗口失去 key 状态而无任何路径把它恢复） |

伪代码：

```swift
var bytes = [UInt8](repeating: 0, count: 0xf8)
bytes[0x04] = 0xf8
bytes[0x08] = 0x0d
bytes[0x8a] = 0x01
writeLittleEndianWindowId(windowId, into: &bytes, at: 0x3c)

SLPSPostEventRecordTo(targetPSN, bytes)
```

单独做到这一步时，实测目标窗口已经可以响应后台鼠标 hover。这说明输入路由层已经生效。但窗口红绿灯仍可能保持灰色，说明 key-window/chrome 状态还不完整。

## Key-Window Event Record

这组事件来自 yabai 的 `window_manager_make_key_window`。AOS 补上它以后，实测窗口成功进入更完整的 focus-without-raise 状态。

buffer 同样是 `0xf8` bytes，关键字段：

| Offset | Value | 含义 |
|---:|---:|---|
| `0x04` | `0xf8` | event record size/opcode high |
| `0x08` | `0x01` | key-window begin |
| `0x08` | `0x02` | key-window end |
| `0x3a` | `0x10` | key-window event marker |
| `0x3c...0x3f` | little-endian `CGWindowID` | 目标 window id |
| `0x20...0x2f` | `0xff` | yabai 保留字段，必须对齐原布局 |

伪代码：

```swift
func keyWindowEvent(windowId: CGWindowID, phase: UInt8) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 0xf8)
    bytes[0x04] = 0xf8
    bytes[0x08] = phase       // 0x01 begin, 0x02 end
    bytes[0x3a] = 0x10
    bytes[0x20..<0x30] = 0xff
    writeLittleEndianWindowId(windowId, into: &bytes, at: 0x3c)
    return bytes
}

SLPSPostEventRecordTo(targetPSN, keyWindowEvent(windowId, phase: 0x01))
SLPSPostEventRecordTo(targetPSN, keyWindowEvent(windowId, phase: 0x02))
```

这一步是本次排查中发现的缺口：只有 focus/defocus 时，后台输入能通，但 AppKit/WindowServer 的 key-window 外观层不完整；补上 begin/end 后，窗口进入了更完整的 focus-without-raise 状态。

## 与 yabai 的差异

yabai 的相关流程大致是：

```text
if target PSN == previously-focused PSN:
    SLPSPostEventRecordTo(previousFocusedPSN, focusEvent(prevWid, marker: defocus))
    usleep(40_000)
    SLPSPostEventRecordTo(targetPSN,        focusEvent(targetWid, marker: focus))
_SLPSSetFrontProcessWithOptions(targetPSN, targetWid, kCPSUserGenerated)
make_key_window begin/end event (to targetPSN)
```

AOS 的流程是：

```text
SLPSPostEventRecordTo(targetPSN, focusEvent(targetWid, marker: focus))
SLPSPostEventRecordTo(targetPSN, keyWindowEvent(targetWid, phase: begin))
SLPSPostEventRecordTo(targetPSN, keyWindowEvent(targetWid, phase: end))
```

差异说明：

- AOS 不调用 `_SLPSSetFrontProcessWithOptions`，因为它会把目标 app/window 推向系统 front process 激活，实测或历史参考都显示存在 raise 和 Space follow 风险。
- AOS 完全不投递 defocus 事件。yabai 的 defocus 只覆盖“同 app 内换窗口”这一条 case，跨 app 时它走 `_SLPSSetFrontProcessWithOptions` 隐式 deactive 上一个 app；AOS 既不发 defocus 也不调 `_SLPSSetFrontProcessWithOptions`，所以原窗口的 key-window 状态保留下来，不会被 deactive。
- AOS 保留 yabai 的 `make_key_window` event，因为它补齐 key-window 状态，但目前验证不会主动 raise。
- AOS 增加 `pid + windowId` ownership 校验，避免对不属于目标 pid 的 window 投递 focus event。
- AOS 不做 fallback。私有符号缺失、权限缺失、OSStatus 非 `noErr` 都直接抛 `ComputerUseError.focusUnavailable`。

## `_SLPSSetFrontProcessWithOptions` 的定位

`_SLPSSetFrontProcessWithOptions` 不是 AOS 当前 focus-without-raise 的必要步骤。

它的语义更接近：

```text
set target ProcessSerialNumber as system front process with a target window/mode
```

yabai 会用：

- `kCPSUserGenerated`：激活目标 app/window。
- `kCPSNoWindows`：在没有下一个窗口可 focus 时，把 Finder 设置成无窗口 front process。

对 AOS 来说，`kCPSUserGenerated` 的副作用过强；`kCPSNoWindows` 又不能完成目标窗口的后台输入激活。因此当前实现跳过它。

## 风险与边界

这是私有 API 路径，存在这些边界：

- macOS 版本升级可能改变 event record 语义或权限要求。
- 该路径需要 Accessibility permission。
- 该路径适合后续定向输入，不保证所有全局前台语义。
- 不应和全局 HID event posting 混用；全局事件仍可能进入用户当前前台 app。
- 如果目标窗口被最小化、隐藏、销毁，或者 app 自身拒绝后台事件，focus 成功也不保证输入有效。

## 测试覆盖

AOS 当前用单元测试锁定两组 event record layout 以及投递行为：

- `builds the SLPS focus event record layout`：focus event marker 固定为 `0x01`，永不构造 `0x02`。
- `builds the SLPS key-window event record layout`。
- `focuses only the target PSN and never posts a defocus event`：注入 mock 的 `resolveProcessPSN` / `postEventRecord`，断言 focuser 只投递 3 条事件，并且每条事件的 PSN 都等于 target PSN，且不存在任何 `bytes[0x8a] == 0x02` 的 defocus 事件。该测试是“不 deactive 原窗口”这个行为的回归防线：一旦有人改回去发 defocus，它会立刻失败。
- `focuser fails fast without accessibility permission`：缺权限时不会触发 PSN 解析或事件投递。

并覆盖：

- pid/window ownership validation。
- pid mismatch 时不会调用 focuser。
- CLI `focus-window --pid --window-id` 参数解析。

手动验证项：

- focus 前：目标后台窗口可见但未 active，部分 UI 不响应 hover，红绿灯为后台灰态。
- 只发 focus event（无 defocus、无 key-window）后：后台 hover 生效，但红绿灯仍灰。
- 补上 key-window begin/end 后：目标窗口成功 focus without raise。
- 验证没有 raise、没有 Space follow，并且 **原前台窗口仍维持 active 状态**（visual chrome 不切回灰）。


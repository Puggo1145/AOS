# Focus Without Raise

本文记录 Notch Agent 当前 `ComputerUseKit` 中实际使用的 window
focus-without-raise primitive。目标是给定 `pid + CGWindowID`，让目标窗口进入
可接收定向输入的状态，同时不改变窗口 z-order、不触发 Space follow、不 deactive 用户
当前前台窗口。

实现文件：

- `Sources/ComputerUseKit/Windows/SkyLightWindowFocuser.swift`
- `Sources/ComputerUseKit/ComputerUseCore.swift`

## Current Primitive

当前 focus primitive 只向目标进程的 PSN 投递 target-side records：

```text
GetProcessForPID(targetPid, &targetPSN)
SLPSPostEventRecordTo(targetPSN, focus(windowId, marker: 0x01))
SLPSPostEventRecordTo(targetPSN, keyWindow(windowId, phase: begin))
SLPSPostEventRecordTo(targetPSN, keyWindow(windowId, phase: end))
```

它刻意不做这些事：

```text
_SLPSGetFrontProcess(...)
SLPSPostEventRecordTo(previous front PSN, defocus record)
_SLPSSetFrontProcessWithOptions(...)
AXRaise
SLSOrderWindow
```

核心不变量：

- 不读取 previous front PSN。
- 不向用户当前 front PSN 投递 defocus。
- 不调用 `_SLPSSetFrontProcessWithOptions`。
- 不 raise，不 order target window。
- 私有符号缺失、权限缺失、OSStatus 非 `noErr` 都直接抛错。

## Why Target Only

yabai 的完整 window switching path 会在部分场景中向 previous PSN 发 defocus，并通过
`_SLPSSetFrontProcessWithOptions` 完成系统前台窗口切换。Notch Agent 的 background computer
use path不能使用这套完整切换语义：

- previous-PSN defocus 会让用户当前窗口失去 key/active 状态。
- `_SLPSSetFrontProcessWithOptions(kCPSUserGenerated)` 会把目标推向可见前台激活，
  可能 raise 或 follow Space。
- `_SLPSSetFrontProcessWithOptions(kCPSNoWindows)` 不能完成 Chrome 等目标所需的
  后台输入激活。

WindowServer 允许跨 app 的多个窗口短时间同时处于 active/key-like 状态。Notch Agent 利用这点：
只给目标窗口补足输入路由状态，让用户当前 front window 保持自己的状态。

## Event Record Layout

event record 固定为 `0xf8` bytes。业务路径的 focus record 只使用 marker `0x01`。
marker `0x02` 保留为低层诊断 primitive，绝不发给 previous PSN，也不再用于
app-session cleanup。focus record 之后还会发送 target-side key-window begin/end
records，用于让 AppKit 窗口的 key/main visual state 立即跟上。

Focus/defocus record:

| Offset | Value | Meaning |
|---:|---:|---|
| `0x04` | `0xf8` | event record size/opcode high |
| `0x08` | `0x0d` | focus event opcode |
| `0x3c...0x3f` | little-endian `CGWindowID` | target window id |
| `0x8a` | `0x01` | focus target |
| `0x8a` | `0x02` | defocus target diagnostic primitive |

Key-window record:

| Offset | Value | Meaning |
|---:|---:|---|
| `0x04` | `0xf8` | event record size/opcode high |
| `0x08` | `0x01` / `0x02` | key-window begin / end opcode |
| `0x20...0x2f` | `0xff` | key-window event payload |
| `0x3a` | `0x10` | key-window event marker |
| `0x3c...0x3f` | little-endian `CGWindowID` | target window id |
| `0x8a` | `0x00` | no focus/defocus marker on key-window records |

Pseudo-code:

```swift
var bytes = [UInt8](repeating: 0, count: 0xf8)
bytes[0x04] = 0xf8
bytes[0x08] = 0x0d
bytes[0x8a] = 0x01
writeLittleEndianWindowId(windowId, into: &bytes, at: 0x3c)

SLPSPostEventRecordTo(targetPSN, bytes)

var keyBytes = [UInt8](repeating: 0, count: 0xf8)
keyBytes[0x04] = 0xf8
keyBytes[0x3a] = 0x10
for offset in 0x20..<0x30 {
    keyBytes[offset] = 0xff
}
writeLittleEndianWindowId(windowId, into: &keyBytes, at: 0x3c)

keyBytes[0x08] = 0x01
SLPSPostEventRecordTo(targetPSN, keyBytes)
keyBytes[0x08] = 0x02
SLPSPostEventRecordTo(targetPSN, keyBytes)
```

## Public API

```swift
try await ComputerUseCore.focusWindowWithoutRaise(pid: pid, windowId: windowId)
```

CLI:

Launch `.build/debug/ComputerUseCLI interactive`, select `focus-window`,
then select the target app/window in the palette prompts.

`ComputerUseCore` validates that `windowId` belongs to `pid` before it calls the
focuser. A pid/window mismatch fails before any private event is posted.

## Background Click Integration

`ComputerUseCore.postMouseEvent` uses this same target-side focus step before
event delivery. The outer mouse-event chain is responsible for dispatch,
active-state guarding, and front-window restore. App-session cleanup no longer
posts target-side defocus; live validation showed that private event can leave
the target window stuck inactive for real user clicks and drags after control
returns to the user.

Chromium / Electron mouse delivery builds on this same focus primitive. Its
browser-specific event sequence is documented in `docs/research/bgclick-chromium.md`.

## Tests

Relevant coverage:

- `validates pid ownership before focusing the window`
- `does not focus a window owned by another pid`
- `builds the SLPS focus event record layout`
- `builds the SLPS key-window event record layout`
- `focuses only the target PSN with target-side key window events`
- `focuser bubbles key-window post failures with exact posted prefix`
- `deactivates only target PSN with one target-side defocus event` (low-level
  diagnostic primitive only)
- `focuser bubbles private SPI failures`

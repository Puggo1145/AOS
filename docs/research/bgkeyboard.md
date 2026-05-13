# Background Keyboard

This document records AOS's current background keyboard event path. It builds
on the same front-window preservation contract as `docs/research/bgclick.md`,
but keyboard delivery is separate from mouse delivery.

## Goal

Given a visible target window, AOS can deliver keyboard input to the target
process while preserving the user's current front app/window:

- Type Unicode text into the target's currently focused field.
- Press a single key with optional modifiers.
- Press a shortcut such as `command+shift+s`.
- Keep the app session open after dispatch, then clear target-side background
  active state when the session stops.

## Event Model

File:

- `Sources/AOSComputerUseKit/Input/BackgroundKeyboardEvent.swift`

The model is intentionally separate from the poster implementation:

```swift
BackgroundKeyboardEvent.text("hello", delayMilliseconds: 30)
BackgroundKeyboardEvent.keyPress(key: "return")
BackgroundKeyboardEvent.keyPress(key: "delete", count: 5)
BackgroundKeyboardEvent.hotkey(modifiers: [.command], key: "c")
```

Supported key names match the CUA driver vocabulary: `return`, `tab`,
`escape`, arrows, `space`, `delete`, `home`, `end`, `pageup`, `pagedown`,
`f1`-`f12`, letters, and digits.

## Delivery Route

File:

- `Sources/AOSComputerUseKit/Input/KeyboardEventPoster.swift`

Keyboard events are pid-scoped. AOS creates `CGEvent` keyboard down/up events
and posts them to the target pid through:

```text
SLEventPostToPid(pid, event)
```

Before posting, AOS attaches a SkyLight authentication envelope:

```text
SLSEventAuthenticationMessage.messageWithEventRecord(eventRecord, pid, version: 0)
SLEventSetAuthenticationMessage(event, message)
```

This mirrors the CUA keyboard route that reaches Chromium/Electron keyboard
pipelines when public `CGEvent.postToPid` is insufficient. Unlike CUA, AOS
does not silently fall back to the public route: missing private symbols,
missing event records, or missing auth messages fail loudly as
`ComputerUseError.keyboardEventUnavailable`.

## Text Input

Text input posts one key-down/key-up pair per Swift `Character`. Each event has
virtual key code `0` and carries its UTF-16 payload through:

```text
CGEventKeyboardSetUnicodeString
```

This avoids layout-specific key mapping and supports accents, symbols, and
emoji. The per-character delay is clamped to 0...200ms; the CLI default is
30ms.

## Shortcut Input

Single key presses and hotkeys use virtual key codes from HIToolbox's `kVK_*`
values. A single key press can specify a positive repeat count, which posts
one key-down/key-up pair per count. Modifiers are represented as `CGEventFlags`
on the key down/up event:

- `command`
- `shift`
- `option`
- `control`
- `function`

Hotkeys require at least one modifier and exactly one final non-modifier key.
Unknown key names fail before any event is posted.

## Core Chain

File:

- `Sources/AOSComputerUseKit/ComputerUseCore.swift`

`ComputerUseCore.postKeyboardEvent` runs this chain:

1. Require an active app session and validate current session pid/window ownership.
2. Reuse the target app session, whose state records only the app pid.
3. Start the same `WindowOrderGuardian` / order-change guard used by mouse.
4. Focus the target window without raising it.
5. Post the keyboard event to the target pid.
6. Keep the target app session open so focus/caret state remains visible for
   follow-up observation or input.
7. Run the delayed active-state guard while allowing the target app to remain
   active.

`stopAppSession()` runs the cleanup path: read the current frontmost window,
enumerate current windows for the session pid, and deactivate only session
windows that are not frontmost.

Keyboard dispatch does not validate coordinates because the event goes to the
target process's focused element rather than a point inside the window.

## CLI Surface

启动 `.build/debug/AOSComputerUseCLI interactive` 后，在 palette 中执行：

1. 选择 `start-app-session`，按 App / Window prompt 选择目标。
2. 选择 `type-text`，在 Window 菜单选择当前 session 的目标窗口，并按 prompt 输入 text 和可选 delay。
3. 选择 `press-key`，在 Window 菜单选择目标窗口，并按 prompt 输入 key、可选 modifiers、可选 count。
4. 选择 `hotkey`，在 Window 菜单选择目标窗口，并按 prompt 输入 keys CSV，例如 `cmd,c`。
5. 最后选择 `stop-app-session`。

显式 session 命令也暴露在 CLI 中：

在 CLI 中执行 `.build/debug/AOSComputerUseCLI interactive` 后，通过 Command 菜单选择
`start-app-session` 和 `stop-app-session`。

成对 start/stop 需要同一个 `ComputerUseCore` lifetime；当前 CLI 只保留 interactive
host 来持有这个有状态 core。

CLI modifier aliases:

- `cmd` / `command`
- `shift`
- `option` / `alt`
- `ctrl` / `control`
- `fn` / `function`

## Known Limits

- The target window must be visible and owned by the requested pid.
- Keyboard input goes to the target process's current focused element; AOS does
  not yet provide element-index pre-focus for keyboard events.
- Minimized windows are not supported for keyboard commit events.
- Validation is unit-level. Live app validation should cover at least a native
  AppKit text field and a Chromium/Electron text field before treating a target
  class as production-stable.

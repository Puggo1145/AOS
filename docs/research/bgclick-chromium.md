# Chromium Background Click

This document is the source of truth for the Chromium / Electron background
click path that currently works in AOS.

## Goal

Given a visible Chromium-family or Electron window, AOS must deliver a left
click into the target web content while preserving the user's front window and
cursor ownership:

- The target app receives the click.
- The user's original front app/window is restored and remains the user's
  active working context.
- Background z-order drift against non-active cover windows is accepted.
- Any transient target active state is cleaned up after dispatch.

## Current Implementation Path

Entry point:

```swift
try await ComputerUseCore.postLeftClick(pid: pid, windowId: windowId, point: screenPoint)
```

The CLI accepts window-local `--coor x,y`, resolves the target window bounds,
and converts that local coordinate to the screen-space `point` consumed by
`ComputerUseCore`.

Production flow:

1. `ComputerUseCore.performPostLeftClick` validates pid/window ownership and
   rejects points outside the target window.
2. It snapshots the original front layer-0 window.
3. It creates `WindowOrderGuardian` from the current visible window order.
4. It starts `WindowOrderChangeObserver` so order changes can trigger the
   active-state guard immediately.
5. It performs target-side focus without raise.
6. It posts the Chromium / Electron mouse event sequence.
7. It runs the active-state guard after observable mouse-post stages.
8. It restores original front focus, deactivates only the target window, and
   reactivates the original front app if needed.
9. It runs the delayed active-state guard for 300ms at 5ms cadence.

## Route Selection

`MouseClickDeliveryClassifier` selects the Chromium / Electron route when the
target process is one of the known Chromium-family bundle identifiers, one of
the known Electron bundle identifiers, or its app bundle contains:

```text
Contents/Frameworks/Electron Framework.framework
```

The current route includes Chrome, Chrome Canary, Edge, Brave, Arc, Vivaldi,
Opera, Slack, VS Code, Discord, Notion, and Figma.

## Focus Without Raise

Chromium needs a pre-click target focus state for the pid-routed mouse events
to reach web content. AOS uses `SkyLightWindowFocuser.focusWindowWithoutRaising`
for this.

The focus call posts one target-side SkyLight/HIServices event record:

```text
SLPSPostEventRecordTo(targetPSN, focus(windowId, marker: 0x01))
```

Important invariants:

- Never post a defocus event to the user's original front PSN.
- Never call `_SLPSSetFrontProcessWithOptions`.
- Never raise or order the target window as part of focus.
- Let private-symbol or OSStatus failures bubble up.

After the click has been dispatched, cleanup uses a target-side defocus only:

```text
SLPSPostEventRecordTo(targetPSN, focus(windowId, marker: 0x02))
```

That clears the target's background active/key state without deactivating the
user's original front window.

## Chromium Mouse Sequence

The working delivery recipe is implemented in
`MouseEventPoster.postChromiumElectronLeftClick`.

All events are created as `NSEvent.mouseEvent`, bridged to `CGEvent`, stamped
with target pid/window fields, then posted through SkyLight:

```text
SLEventPostToPid(pid, event)
```

Each event is stamped with:

- `event.location` = screen coordinate for that event.
- `CGEventSetWindowLocation` = window-local coordinate.
- `.mouseEventButtonNumber` = 0.
- `.mouseEventSubtype` = 3.
- `.mouseEventClickState` = 1.
- `.mouseEventWindowUnderMousePointer` = target window id.
- `.mouseEventWindowUnderMousePointerThatCanHandleThisEvent` = target window id.
- private field `40` = target pid.
- private fields `51`, `91`, `92` = target window id.

The sequence is:

```text
mouseMoved(target point)
sleep 15ms
leftMouseDown(primer point)
sleep 1ms
leftMouseUp(primer point)
sleep 100ms
leftMouseDown(target point)
sleep 1ms
leftMouseUp(target point)
```

The primer point is intentionally just outside the left edge of the target
window while still stamped as target-window local state:

```text
screen: x = window.x - 1, y = window.y + window.height - 1
local:  x = -1,          y = window.height - 1
```

The target move and target down/up use the real click coordinate. The whole
gesture uses one `uptimeSeconds()` timestamp for the SkyLight post path.

The off-edge primer is part of the current working Chromium delivery contract.
Do not remove it unless a replacement has live Chrome evidence showing event
delivery and window-order stability.

## Window Order Preservation

The target may transiently become active or attempt to rise after mouse
dispatch. AOS no longer attempts to repair background z-order. It protects the
user's active/front window state and treats any non-active background-window
reordering as acceptable.

Before dispatch it records every normal visible window that:

- is layer 0,
- is on screen,
- is at least 64x64,
- overlaps the target window,
- was above the target before the click.

Those are the protected windows for diagnostics only. `protected-covered`
reports when Chrome crosses above them, but the guard does not reorder Chrome or
the protected windows.

AOS deliberately does not use `AXRaise` or `SLSOrderWindow` in this path. The
guard only restores original front focus and reactivates the original front app
when Chrome remains active.

`WindowOrderChangeObserver` observes the target window so target order changes
can trigger the guard immediately.

The active-state guard runs at three points:

- immediately from `WindowOrderChangeObserver`,
- after mouse stages that can affect order or active state: `afterMouseMoved`,
  `afterTargetDown`, and `afterTargetUp`,
- during the delayed guard: 0ms, then every 5ms until 300ms.

The active-state guard also checks whether the target app is still active. If
it is, AOS reactivates the original front app.

## Verified Behavior

Live Chrome validation used:

```bash
.build/debug/AOSComputerUseCLI measure-left-click-window-order \
  --pid 45785 \
  --window-id 384636 \
  --coor 90,310 \
  --runs 20 \
  --duration-ms 500 \
  --interval-ms 1 \
  --pre-click-delay-ms 100 \
  --between-runs-ms 100
```

Result from the earlier z-order-preservation prototype:

```text
Runs: 20, protected-covered-observed 0/20
Summary: max active contiguous 15ms, max rank1 contiguous 0ms, max protected-covered contiguous 0ms
```

Stress validation at a text-input point used:

```bash
.build/debug/AOSComputerUseCLI measure-left-click-window-order \
  --pid 45785 \
  --window-id 384636 \
  --coor 500,490 \
  --runs 100 \
  --duration-ms 500 \
  --interval-ms 1 \
  --pre-click-delay-ms 50 \
  --between-runs-ms 50
```

Result from the earlier z-order-preservation prototype:

```text
Runs: 100, protected-covered-observed 0/100
Summary: max active contiguous 0ms, max rank1 contiguous 0ms, max protected-covered contiguous 0ms
```

Chrome received the clicks and typed text into the target web content while no
active-window disturbance was observed. The current simplified implementation
does not use target lowering, so `protected-covered-observed` is now diagnostic
only rather than a pass/fail criterion.

## Success Criteria

For this route to be considered stable in a scenario:

- The target receives the click.
- `max rank1 contiguous` remains `0ms` when the target was not originally front.
- The original front app remains or is restored as active.
- `protected-covered-observed` is reported for diagnosis, but background cover
  drift by non-active windows is accepted.

`measure-left-click-window-order` is the regression diagnostic for this path.
Use short per-run windows, for example `--duration-ms 500`; that option is per
run, not total duration.

## Files

- `Sources/AOSComputerUseKit/ComputerUseCore.swift`
  - Orchestrates validation, target focus, mouse dispatch, cleanup, and the
    active-state guard.
- `Sources/AOSComputerUseKit/Input/MouseEventPoster.swift`
  - Implements Chromium/Electron route classification, event stamping, and the
    SkyLight mouse sequence.
- `Sources/AOSComputerUseKit/Windows/SkyLightWindowFocuser.swift`
  - Posts target-side focus/defocus event records without raising.
- `Sources/AOSComputerUseKit/Windows/WindowOrderGuardian.swift`
  - Defines protected windows and protected-covered diagnostics.
- `Sources/AOSComputerUseCLI/ComputerUseCLI.swift`
  - Provides `post-left-click`, `post-left-click --trace`,
    `observe-window-order`, and `measure-left-click-window-order`.

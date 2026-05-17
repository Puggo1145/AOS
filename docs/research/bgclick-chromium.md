# Web Content Background Click

This document is the source of truth for the web-content background click path
that currently works in Notch Agent. It was first validated on Chromium / Electron and
now also covers Safari through an explicit known-browser bundle-id rule.

## Goal

Given a visible known-browser or Electron window, Notch Agent must deliver a left click
into the target web content while preserving the user's front window and cursor
ownership:

- The target app receives the click.
- The user's original front app/window is restored and remains the user's
  active working context.
- Background z-order drift against non-active cover windows is accepted.
- Any transient target active state is cleaned up after dispatch.

## Current Implementation Path

Entry point:

```swift
try await ComputerUseCore.postMouseEvent(
    pid: pid,
    windowId: windowId,
    event: .click(button: .left, point: screenPoint)
)
```

The CLI accepts window-local `--coor x,y`, resolves the target window bounds,
converts that local coordinate to the screen-space `point`, and constructs
`BackgroundMouseEvent.click(button: .left, point:)` for `ComputerUseCore`.

Production flow:

1. `ComputerUseCore.performPostMouseEvent` validates pid/window ownership and
   rejects points outside the target window.
2. It snapshots the original front layer-0 window.
3. It creates `WindowOrderGuardian` from the current visible window order.
4. It starts `WindowOrderChangeObserver` so order changes can trigger the
   active-state guard immediately.
5. It starts or reuses the target app session and performs target-side focus
   without raise.
6. It posts the web-content mouse event sequence.
7. It runs the active-state guard after observable mouse-post stages.
8. It keeps the target app session open until `stopAppSession` or an automatic
   switch to a different target releases the session lease and overlays.
9. It runs the delayed active-state guard for 300ms at 5ms cadence while
   allowing the target app to remain active.

## Route Selection

`BackgroundMouseEventDeliveryClassifier` selects the `webContent` route from Chromium /
Electron runtime evidence first, then falls back to known browser or Electron
bundle identifiers. The
runtime checks are:

```text
Contents/Frameworks/Electron Framework.framework
Contents/Frameworks/Chromium Embedded Framework.framework
3+ Chromium resource markers under Contents/Frameworks:
  chrome_100_percent.pak, chrome_200_percent.pak, icudtl.dat,
  resources.pak, v8_context_snapshot.*.bin
```

Bundle identifier checks remain as fallback coverage for known Chromium-family
browsers, explicit Safari support, and non-standard Electron packages.
`get-app-type` reports both the selected type and reason, such as
`electronFramework`, `chromiumEmbeddedFramework`,
`chromiumRuntimeResources`, `chromiumBrowserBundleId`, `safariBundleId`,
`knownElectronBundleId`, or `appKitDefault`.

The Safari rule is intentionally bundle-id based. Do not infer this route from
generic WebKit framework presence or arbitrary `WKWebView` usage; those are
common in native AppKit apps and are not evidence that the app needs the
browser web-content event path.

## Focus Without Raise

Chromium needs a pre-click target focus state for the pid-routed mouse events
to reach web content. Notch Agent uses `SkyLightWindowFocuser.focusWindowWithoutRaising`
for this.

The focus call posts target-side SkyLight/HIServices event records:

```text
SLPSPostEventRecordTo(targetPSN, focus(windowId, marker: 0x01))
SLPSPostEventRecordTo(targetPSN, keyWindow(windowId, phase: begin))
SLPSPostEventRecordTo(targetPSN, keyWindow(windowId, phase: end))
```

Important invariants:

- Never post a defocus event to the user's original front PSN.
- Never call `_SLPSSetFrontProcessWithOptions`.
- Never raise or order the target window as part of focus.
- Let private-symbol or OSStatus failures bubble up.

When the app session stops, cleanup no longer uses target-side defocus. Live
validation showed that private event can leave the target window stuck inactive
for real user clicks and drags after Notch Agent releases control.

## Web Content Mouse Sequence

The working delivery recipe is implemented in `MouseEventPoster`'s
web-content SkyLight route.

Mouse events are created as `NSEvent.mouseEvent` and bridged to `CGEvent`.
All events are stamped with target pid/window fields, then posted through
SkyLight:

```text
SLEventPostToPid(pid, event)
```

Each event is stamped with:

- `event.location` = screen coordinate for that event.
- `CGEventSetWindowLocation` = window-local coordinate.
- `.mouseEventButtonNumber` = the event button number. The off-edge primer is
  always a left-button pair.
- `.mouseEventSubtype` = 3.
- `.mouseEventClickState` = 0 for move events; target down/up events use the
  current click count, starting at 1.
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
leftMouseDown(target point, clickState: 1)
sleep 1ms
leftMouseUp(target point, clickState: 1)
```

For right-click and drag, the target down/drag/up events use the requested
button while the primer remains left-button.
For `left-click` / `right-click` calls with `count > 1`, the primer still runs
once, then the target down/up pair repeats at the requested coordinate with
click states `1...count`.

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
dispatch. Notch Agent no longer attempts to repair background z-order. It protects the
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

Notch Agent deliberately does not use `AXRaise` or `SLSOrderWindow` in this path. The
guard only restores original front focus and reactivates the original front app
when Chrome remains active.

`WindowOrderChangeObserver` observes the target window so target order changes
can trigger the guard immediately.

The active-state guard runs at three points:

- immediately from `WindowOrderChangeObserver`,
- after mouse stages that can affect order or active state: `afterMouseMoved`,
  `afterTargetDown`, and `afterTargetUp`,
- during the delayed guard: 0ms, then every 5ms until 300ms.

While an app session is open, the active-state guard treats target-active state
as allowed and only reacts to order/focus violations. `stopAppSession` releases
the session without running a defocus cleanup pass.

## Verified Behavior

Live Chrome validation used:

1. Launch `.build/debug/ComputerUseCLI interactive`.
2. Select `start-app-session`, then select pid `45785` and window `384636`.
3. Select `measure-left-click-window-order`, choose window `384636`, and enter:
   `coor=90,310`, `runs=20`, `duration-ms=500`, `interval-ms=1`,
   `pre-click-delay-ms=100`, `between-runs-ms=100`.
4. Select `stop-app-session`.

Result from the earlier z-order-preservation prototype:

```text
Runs: 20, protected-covered-observed 0/20
Summary: max active contiguous 15ms, max rank1 contiguous 0ms, max protected-covered contiguous 0ms
```

Stress validation at a text-input point used:

1. Launch `.build/debug/ComputerUseCLI interactive`.
2. Select `start-app-session`, then select pid `45785` and window `384636`.
3. Select `measure-left-click-window-order`, choose window `384636`, and enter:
   `coor=500,490`, `runs=100`, `duration-ms=500`, `interval-ms=1`,
   `pre-click-delay-ms=50`, `between-runs-ms=50`.
4. Select `stop-app-session`.

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

- `Sources/ComputerUseKit/ComputerUseCore.swift`
  - Orchestrates validation, app session, target focus, mouse dispatch,
    session release, and the active-state guard.
- `Sources/ComputerUseKit/Input/BackgroundMouseEvent.swift`
  - Defines coordinate mouse event intent, independent from delivery path.
- `Sources/ComputerUseKit/Input/BackgroundMouseEventDelivery.swift`
  - Classifies AppKit vs web-content mouse event delivery routes.
- `Sources/ComputerUseKit/Input/MouseEventPoster.swift`
  - Implements event stamping, AppKit event posting, and the SkyLight
    web-content mouse-event sequence.
- `Sources/ComputerUseKit/Windows/SkyLightWindowFocuser.swift`
  - Posts target-side focus records without raising; defocus remains a
    low-level diagnostic primitive.
- `Sources/ComputerUseKit/Windows/WindowOrderGuardian.swift`
  - Defines protected windows and protected-covered diagnostics.
- `Sources/ComputerUseCLI/ComputerUseCLI.swift`
  - Provides `start-app-session`, `stop-app-session`, `left-click`, `right-click`,
    web-content-only `drag`, `--trace`,
    `observe-window-order`, and `measure-left-click-window-order` diagnostics
    for this path.

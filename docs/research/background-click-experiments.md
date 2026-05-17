# Background Click Experiments

This is a historical experiment archive. It is not the current implementation
guide.

Current source-of-truth docs:

- AppKit/general route: `docs/research/bgclick.md`
- Chromium/Electron route: `docs/research/bgclick-chromium.md`

## Target

The goal is a pixel-coordinate click into a background browser window without:

- moving the visible cursor;
- stealing frontmost app focus;
- permanently changing window order;
- relying on UI accessibility actions for page content.

The current Chromium/Electron route has live Chrome validation. Do not use
older entries in this archive to override that path.

## Current Implementation Surface

- General AppKit apps use the public pid-targeted mouse event path plus
  target-side focus-without-raise and shared window-order cleanup.
- Chromium and Electron apps use a dedicated SkyLight route:
  `mouseMoved(target) -> primer down/up(left-edge outside target) ->
  target down/up`.
- Current diagnostics include `left-click --trace`,
  `observe-window-order`, and `measure-left-click-window-order`.
- Removed experiment-only CLI options and profile enums must stay removed.

## Historical Notes

Entries below predate the current validated Chromium route. They are useful for
understanding why the implementation is conservative, but they are not a plan
for future changes.

## Codex Computer Use Clues

The local Codex Computer Use binary contains strings and symbols that are more
consistent with a long-lived focus/order control system than with a one-shot
mouse post:

- `SystemFocusStealPreventer`
- `SyntheticAppFocusEnforcer`
- `WindowOrderingObserver`
- `EventTap`
- `MouseEventTarget`
- diagnostics around a window changing order while another app is frontmost

Static pass on `computer-use/1.0.780` adds these firmer observations:

- the bundle is split into `SkyComputerUseService` and
  `SkyComputerUseClient`; the Codex plugin launches the client as an MCP
  stdio process, while the service owns the local app/session machinery;
- both binaries are ordinary LSUIElement Swift/AppKit apps with application
  group and Apple Events automation entitlements. There is no special
  entitlement that would explain privileged WindowServer ordering behavior;
- `SkyComputerUseService` links public AppKit, ApplicationServices,
  CoreGraphics, ScreenCaptureKit, and AX APIs, and it imports
  `AXObserver*`, `AXUIElement*`, `CGWindowList*`, `GetProcessForPID`, and
  `dlopen` / `dlsym`;
- the service does not directly import public `CGEventPost*` symbols in its
  symbol table. Combined with `privateFramework`, `WindowServerSPI`,
  `CGEventAPI`, and `AccessibilitySPI` strings, the event path is likely
  resolved through internal wrappers and function pointers rather than
  obvious direct imports;
- the binary contains explicit state names for a suppression stack:
  `applicationBelievesItIsActive`, `applicationBelievesItHasFocus`,
  `targetLostFocusHandler`, `targetGainedFocusHandler`, `currentFocus`,
  `previousFocus`, `keyboardEventTap`, `mouseEventTaps`, and
  `lastViewBridgeFocusStealWasSuppressed`;
- the order observer has concrete diagnostics:
  `Failed to handle order change`, `Raised "%s" over "%s" ... attempts`,
  and `"%s" (%u) changed order while %s is frontmost`.
- the same binary also contains `AXEnablementAssertion`,
  `AXNotificationObserver`, `SystemEventObserver`,
  `SystemSoftware.CGWindow.Observer`, `KeyWindowTracker`,
  `AXManualAccessibility`, `AXEnhancedUserInterface`,
  `kCPSNotifyKeyFocus*`, `kCPSNotifyTypingFocus*`, `preventActivation`,
  `isOrderedIn`, `isOrderedOut`, and `didChangeOrder`;
- disassembly around the order-repair diagnostics confirms a retry cap of
  `0x28` attempts in the observer state machine. Combined with the existing
  `bgclick.md` note about a 5ms retry cadence, this points to an event-driven
  order observer that starts repairing from the order-change notification, not
  merely a command-local cleanup pass after a click returns.

These observations shift the most likely model away from "one perfectly
stamped mouse sequence" and toward a layered interaction system:

1. Prefer AX actions for element-targeted clicks when an AX element exists.
2. Before an AX action, synthesize app/window/element focus state so the target
   app believes the action is legitimate without becoming the system frontmost
   app.
3. Around the action, arm a focus-steal preventer that restores the previous
   frontmost app if the target self-activates.
4. Independently observe WindowServer order and repair violated ordering
   constraints when the target changes rank while another app is frontmost.
5. Use pixel mouse delivery only for surfaces that are not AX-actionable, such
   as canvas/video/WebGL/custom views.

The `playground/cua` implementation has similarly named components
(`FocusGuard`, `SyntheticAppFocusEnforcer`, `SystemFocusStealPreventer`) and is
useful as a reference for how those names could fit together. It is not proof
of the Codex binary internals, but it supports the layered hypothesis: AX
enablement + synthetic AX focus + reactive frontmost restoration for AX actions,
separate from pixel-mouse delivery.

Important implication for the Chrome pixel issue: a stable Codex click on a
normal browser button may not be pixel delivery at all. It may resolve the
screenshot point back to an AX element and execute `AXPress` under the
suppression stack. The comparison must therefore force a true pixel-only target
inside Chrome web content, such as canvas/video/WebGL or a deliberately
AX-inert DOM area, before concluding Codex solved Chromium pixel delivery.

Follow-up live observation: Codex Computer Use can drag and draw inside a
Chrome `<canvas>` without a visible raise. That makes the AX-only explanation
insufficient. The remaining unknown is whether Codex prevents Chromium's order
change from happening, or whether its long-lived order observer repairs the
change before the next visible composite frame.

Passive Notch Agent observation during a Codex Computer Use Chrome Canvas drag gives a
more specific result:

- frontmost app stayed Ghostty for the whole 15s observation;
- Chrome was never observed active;
- `protected-covered` stayed `0`, so the original protected/frontmost window
  was not covered by Chrome;
- the target Chrome rank changed from `2` to `3` at about `3727ms`, then back
  to `2` at about `4208ms`.

A second 10s observation reproduced the same shape with the transition-only
diagnostic output: Ghostty stayed frontmost, Chrome was never active,
`protected-covered` stayed `0`, and target rank moved from `2` to `3` at about
`2664ms`, then back to `2` at about `3226ms`.

That rank movement is not the Chrome raise seen in Notch Agent's failed browser click:
Chrome did not become rank `1`, did not become the frontmost app, and did not
cover the protected window. The result is consistent with Codex avoiding the
visible raise entirely while still allowing some background-window stack
movement, or with a repair that never violates the protected-window invariant.
Therefore the useful invariant for the next implementation should be stricter
than "final rank unchanged" but looser than "no rank ever changes": the target
must not become frontmost, must not become active, and must not cover protected
windows.

Passive Notch Agent observation during the current Notch Agent Chromium `left-click`
shows the failing shape clearly:

- the external observer saw Chrome become target rank `1` at about `2048ms`;
- Chrome became active at about `2056ms`;
- Chrome later moved back to rank `2` at about `2459ms`, but stayed active;
- the command-local trace saw `protected-covered 1` from the first delayed
  repair tick through the final 1s settle sample;
- the delayed repair loop repeatedly reported `repaired true`, but the sampled
  state remained in violation.

This is the first direct apples-to-apples timing contrast: Codex's Chrome
Canvas drag only showed background rank movement with no active/rank-1/
protected-window violation, while Notch Agent's Chromium click crosses both `target
rank 1` and `target active true` shortly after dispatch. One caveat in the
two-terminal run: the external observer's `max protected-covered 0` can be a
false negative because the user switched from the observer terminal to a second
Ghostty window before launching `left-click`; the command-local trace
sampled the actual front Ghostty window at click time and reported
`protected-covered 1`.

Implication for Notch Agent:

- Notch Agent already has the Chromium AX enablement primitive
  (`AXManualAccessibility`, `AXEnhancedUserInterface`, retained AX observer),
  but the current `left-click` path does not use AX actions or synthetic
  AX focus. It always tries the pixel mouse path.
- Notch Agent's `WindowOrderGuardian` is command-scoped. It samples protected windows
  before the click, repairs after selected event stages, then polls for a fixed
  window. It is not a long-lived `CGWindow` / WindowServer observer.
- The Chrome traces show a key distinction: `NSWorkspace.frontmostApplication`
  can remain Ghostty while Chrome's window rank changes and its traffic lights
  light up. A pure `NSWorkspace.didActivateApplicationNotification` focus-steal
  preventer would not catch that case. The closer Codex clue is
  `WindowOrderingObserver` plus the diagnostic for a window changing order
  while another app remains frontmost.
- Therefore the current best explanation is not that Chrome cannot be
  "suppressed" at all. It is that the browser pixel route couples real page
  mouse delivery to a late WindowServer/Chromium ordering correction, and Notch Agent
  currently tries to clean it up from a short-lived polling loop. Codex likely
  has an observer already armed before the action and can repair from the order
  notification itself.
- If Chromium's correction cannot be prevented, a fast repair can still be
  visually indistinguishable from suppression only if it happens before the
  next display transaction. A post-command polling guard can be correct in
  final state but still visibly flash; an event-driven observer has a plausible
  path to repair inside the same frame budget.
- The current delayed repair loop does not merely react too late; in the Notch Agent
  Chromium click trace it keeps calling repair while Chrome remains active and
  continues covering the protected window. The repair path needs either a
  stronger deactivation/order operation or an observer loop that can react to
  the exact WindowServer order transition before Chrome's correction settles.
- A first stronger repair prototype now repeats target-side deactivation when
  the delayed guard actually repairs protected-window order. Immediate
  mouse-post stage repair does not deactivate the target, because doing so
  during an in-flight down/up sequence would risk breaking the delivery path.
- Live validation showed that prototype is insufficient for Chrome: the
  external observer still saw `target rank 1`, `target active true`, and
  `protected-covered 1`; the trace still ended with those values through the
  final 1s settle sample. Therefore the target-side `.defocus` event-record is
  not a strong enough Chromium deactivation primitive after Chrome self-
  activates.
- A second repair prototype reactivated the original front application once
  after target deactivation via `NSRunningApplication.activate(options: [])`.
  Live validation showed a brief recovery window (`target active true`, target
  rank `2`, `protected-covered 0`) but Chrome reviolated shortly afterward and
  the trace still ended with `target active true`, target rank `2`, and
  `protected-covered 1`. Therefore one-shot original-front activation is not
  enough; the delayed guard must treat target-active state as its own
  violation and keep reactivating the original front application while the
  guard is armed.
- A third repair prototype reactivated the original front application during
  the delayed guard whenever protected-window order repair ran or Chrome still
  reported active. Live validation improved the final trace: after the first
  two repair ticks, Chrome was inactive, no protected window was covered, and
  the final 1s settle sample ended at target rank `3`. However the external
  observer still saw a visible violation from about `1936ms` to `2042ms`:
  target rank `1`, `target active true`, and `protected-covered 1`. Therefore
  command-final correctness is not enough; the target-up correction must be
  repaired earlier, before post-dispatch cleanup and the long delayed guard.
  The same run also raised an unresolved diagnostic gap: the trace reported
  Ghostty as frontmost, but the user observed that Ghostty did not visually
  look active at the end. The observer now needs to track the original front
  application's active state directly.
- Follow-up validation with original-front active sampling showed Ghostty's
  application active state does recover. The visible issue is now specifically
  the rank/order flash: the observer still saw target rank `1` and
  `protected-covered 1` from about `1949ms` to `2058ms`, while
  `original-front active` was already true again for the latter part of that
  interval. The short `0ms` / `5ms` target-up guard is still too short for
  Chrome's late WindowServer correction on this machine.
- Extending the target-up guard to `120ms` made the command-local trace clean
  by `afterTargetUp`, but the external observer still saw the actual visible
  violation: Chrome became active/rank `1` with `protected-covered 1` from
  about `1965ms` to `2068ms`, then returned to rank `2`, and later rank `3`.
  This proves the remaining issue is reaction latency, not merely total guard
  duration. A longer command-local polling window can make final state correct
  while still allowing a visible frame-level flash.
- Adding a SkyLight `SLSRegisterConnectionNotifyProc` observer for target
  window ordered event `808` did not remove the visible flash either. Live
  validation still saw the same shape: target rank `1` and
  `protected-covered 1` from about `1905ms` to `2005ms`, target active from
  about `1908ms` to `1966ms`, then recovery to rank `2` and later rank `3`.
  The command-local trace stayed clean, so the observer is either delivered
  after the visible WindowServer composite or the current AX/original-app
  repair primitives are too slow. This makes the current repair architecture
  insufficient for Chromium pixel delivery.

These names do not prove the implementation, but they suggest the next useful
comparison is behavioral: watch Codex Computer Use perform the same browser
pixel click with an external Notch Agent observer and determine whether it:

- prevents the raise before it becomes visible;
- repairs the raise faster than Notch Agent's current guard;
- uses a different event target or trust path;
- avoids raw mouse delivery for Chrome page content.

To support that comparison, interactive `observe-mouse-events` now adds
a second passive diagnostic surface. It installs listen-only CGEvent taps and
records the tap location (`hid`, `session`, `annotated`), mouse event type,
screen location, source/target pids, standard mouse fields, and the raw fields
currently used by Notch Agent's Chromium stamp (`0`, `40`, `51`, `58`, `91`, `92`).

The first version only watched `.cgSessionEventTap`. Live Codex comparison on
Chrome canvas returned `events: 0` while Codex still drew on the page, so that
single tap was too narrow to prove anything. The diagnostic now defaults to
`--tap-location all`, which opens HID, session, and annotated session taps and
prints the layer that observed each event. The intended Codex comparison flow
now runs inside the interactive CLI host:

1. Launch `.build/debug/ComputerUseCLI interactive`.
2. Select `observe-mouse-events`.
3. Choose to filter to a target, then select pid `45785` and window `384636`.
4. Enter `duration-ms=15000` and select tap location `all`.
5. Run the Codex Computer Use Chrome canvas click/drag while the observation is active.

If Codex's pid-targeted or WindowServer-routed mouse events pass through any
ordinary CGEvent tap layer, this should expose the event field shape directly.
If all three taps see no Codex mouse events while the canvas still changes,
that is stronger evidence that Codex is using a lower-level WindowServer route
or a browser/process bridge that does not surface through CGEvent taps.

Live Codex comparison with `--tap-location all` did capture the Chrome canvas
drag, but only at `cgAnnotatedSessionEventTap`:

- `events: 8`;
- every event was `annotated`; no HID or plain session tap events were seen;
- `source-pid` was the Codex Computer Use service process and `target-pid`
  was Chrome;
- `mouseEventWindowUnderMousePointer`,
  `mouseEventWindowUnderMousePointerThatCanHandleThisEvent`, raw field `51`,
  raw field `91`, and raw field `92` all matched the Chrome window id;
- raw field `40` matched the Chrome pid;
- raw field `58` was stable across the whole gesture;
- the sequence shape was:
  `mouseMoved(target)`, `leftDown/leftUp(offscreen primer)`,
  `leftDown(target)`, several `leftDragged(target)`, `leftUp(target)`.

This rules out a lower-than-CGEvent-only explanation for Codex's canvas path:
Codex does expose mouse delivery through the annotated event stream. It also
explains why the session-only observer returned zero events. The next useful
comparison is now Notch Agent's current Chromium post under the same all-tap observer,
specifically checking the annotated stream's raw field `0`, raw field `58`,
primer location, target click-state sequence, and the simultaneous
window-order violation.

The same all-tap observer on Notch Agent's current Chromium `left-click` showed
the same annotated-only delivery layer, but a different event shape:

- Notch Agent emitted five annotated events:
  `mouseMoved(target)`, `leftDown/leftUp(primer)`,
  `leftDown/leftUp(target)`;
- Notch Agent used global `(-1, -1)` for the primer, while Codex used `x = -1` with
  a positive Y near the target window's bottom edge;
- Notch Agent raw field `0` sequence was `2, 1, 2, 3, 3`; Codex's observed sequence
  was `0, 1, 2, 1, ...`;
- Notch Agent raw field `58` changed on every event and matched per-event nanosecond
  timestamps; Codex raw field `58` stayed stable across the gesture and used
  the seconds-scale uptime stamp;
- the external window-order observer saw Notch Agent's violation start at about
  `2267ms`, after the primer pair and before the target down event. Chrome
  became rank `1` and covered the protected window before the real target
  click was dispatched.

That localizes the visible raise to the primer/timestamp shape, not the target
click itself. Notch Agent's Chromium route has now been changed to match the Codex
annotated shape more closely:

- primer point: just outside the left edge of the target window at the
  window's lower Y edge, instead of global `(-1, -1)`;
- raw field `0`: `0, 1, 2, 1, 1` for move, primer down/up, target down/up;
- raw field `58`: a single seconds-scale uptime timestamp shared by the whole
  Chromium gesture, set through `CGEvent.timestamp`;
- raw field `58` is no longer stamped as a synthetic click group through
  `SLEventSetIntegerValueField`.

## Next Work

Do not continue broad field-combination experiments without new evidence. The
matrix already showed the same pattern repeatedly: clean variants do not
deliver, delivering variants raise Chrome.

Useful next directions:

Replacement direction for Chromium should be architectural, not another
one-shot stamp tweak:

1. Run paired passive observers against Codex's Chrome canvas operation:
   `observe-window-order` for active/rank/protected invariants and
   `observe-mouse-events` for mouse event field shape.
2. If Codex mouse events are visible through the tap, replace
   `postChromiumElectronLeftClick` with a Codex-matched browser poster and
   delete the current fixed CUA/yabai primer sequence.
3. If Codex mouse events are not visible through the tap, treat that as
   evidence for a deeper WindowServer route and continue binary/runtime
   inspection before touching Notch Agent delivery code.
4. Independently of the final mouse poster, move Chromium interactions behind
   a long-lived browser interaction session that owns order/focus observation
   before, during, and after the dispatch. Codex's `ComputerUseAppController`
   keeps `orderingObserver` and `focusEnforcer` as session state; Notch Agent's
   command-local `WindowOrderGuardian` is the wrong shape for this problem.
5. Keep AX action delivery separate from pixel delivery. AX actions can use
   synthetic focus/enforcement, but canvas/video/WebGL targets must remain a
   true pixel-path test.

Immediate execution state:

1. Done: `observe-window-order` now passively samples frontmost app,
   frontmost layer-0 window, target active state, target rank,
   protected-covered count, and original-front active state without posting
   input. Machine-readable JSON keeps every sample; human-readable output
   prints only state transitions.
2. Done: the same observer watched Codex Computer Use draw into Chrome Canvas.
   The target rank changed in the background, but Chrome never became active,
   never became rank `1`, and never covered the protected frontmost window.
3. Done: the same observer watched Notch Agent's current Chromium click. Notch Agent produced
   `target rank 1`, `target active true`, and command-local
   `protected-covered 1` shortly after the mouse dispatch.
4. Tried and rejected: the delayed repair guard repeated target-side
   deactivation when repairing protected-window order, but live Chrome still
   remained active/rank-1/covered through the 1s settle sample.
5. Tried and rejected: one-shot original-front application activation after
   target deactivation briefly improved the trace but did not keep Chrome from
   remaining active and covering the protected window.
6. Tried and rejected as sufficient: guard-period original-front reactivation
   fixed final state but still allowed a visible rank-1/protected-covered
   interval after target mouse-up.
7. Tried and rejected as sufficient: a `0ms` / `5ms` target-up repair guard
   did not catch Chrome's later rank/order correction soon enough; the
   original-front app did recover, but the window-order flash remained
   obvious.
8. Tried and rejected as sufficient: a `120ms` target-up repair guard made the
   command-local trace look clean, but the external observer still caught a
   visible rank-1/protected-covered interval.
9. Tried and rejected as sufficient: a SkyLight target-window order observer
   using `SLSRegisterConnectionNotifyProc` event `808` and
   `SLSRequestNotificationsForWindows` still allowed the same visible
   rank-1/protected-covered interval.
10. Done: added `observe-mouse-events`, a listen-only CGEvent tap diagnostic
    for comparing Codex's real mouse event fields against Notch Agent's Chromium
    stamp.
11. Tried and rejected as sufficient: the first mouse observer only watched
    the session tap; live Codex Chrome canvas drawing produced `events: 0`,
    proving that diagnostic was too narrow.
12. Done: widened `observe-mouse-events` to `--tap-location all`, covering
    HID, session, and annotated session taps, with per-event tap labels in the
    output.
13. Done: `--tap-location all` captured Codex Chrome canvas delivery at the
    annotated tap only. Codex uses the same target pid/window stamp family but
    a different primer position and raw field sequence from Notch Agent's earlier
    Chromium poster.
14. Done: compared Notch Agent's Chromium poster against Codex's annotated stream and
    changed Notch Agent's Chromium route to use Codex-style primer position, raw field
    `0` sequence, and stable seconds-scale raw field `58` timestamp.
15. Done: live validation showed the Chromium mouse event fields now match the
    Codex-style annotated stream (`raw[0]` sequence `0,1,2,1,1`, stable
    seconds-scale `raw[58]`, and target pid/window stamps), but the external
    order observer still caught a short post-click rank/order correction where
    Chrome briefly reached `rank 1` / `protected-covered 1`.
16. Done: removed the separate delayed target-up repair guard. It duplicated
    the post-cleanup 5ms repair loop, delayed target deactivation, and hid the
    earliest repair attempts from `--trace`. The click chain is now:
    synchronous per-stage repair, immediate restore/deactivate/reactivate
    cleanup, then the single traced post-cleanup repair loop.
17. Done: live validation after removing the target-up guard was materially
    better but still not perfect. Chrome responded, the visible raise/restore
    interval became very short, but the external observer still caught
    `target active true` around mouse-up and a later `rank 1` /
    `protected-covered 1` interval.
18. Tried and rejected: a Chromium/Electron-only no-prefocus path delivered
    the Codex-matched annotated mouse events to the Chrome window stamp, and
    eliminated activation/rank/order side effects, but Chrome did not consume
    the click. Red/yellow/green did not light, so Chromium still requires the
    pre-click `focusWindowWithoutRaising` step for this event route.
19. Done: restored pre-click focus for the live Chromium/Electron route. Keep
    the no-prefocus experiment as evidence only; it is not a valid default
    delivery path.
20. Done: added `measure-left-click-window-order`, which repeats the real click
    path and reports active/rank1/protected-covered durations per run.
21. Done: live Chrome validation stabilized on the current route. A 20-run
    measurement at `90,310` observed `protected-covered 0/20`; a 100-run
    text-input measurement at `500,490` observed `protected-covered 0/100`,
    `rank1 0ms`, and `active 0ms`. The current implementation is documented
    in `docs/research/bgclick-chromium.md`.

# Background Click Experiments

This document keeps only the durable conclusions from the Chrome / Chromium /
Electron background click experiments. The stable AppKit path and current design
surface are documented in `docs/research/bgclick.md`.

## Target

The goal is a pixel-coordinate click into a background browser window without:

- moving the visible cursor;
- stealing frontmost app focus;
- permanently changing window order;
- relying on UI accessibility actions for page content.

This remains important because Codex Computer Use appears able to perform this
class of operation, so the pixel route should not be abandoned solely because
the current AOS experiment matrix did not find a stable browser sequence.

## Current Implementation Surface

- General AppKit apps use the public pid-targeted mouse event path plus
  focus-without-raise and window-order cleanup.
- Chromium and Electron apps use a separate fixed SkyLight route:
  `mouseMoved(target) -> primer down/up(-1,-1) -> target down/up`.
- `post-left-click --trace` is the only remaining diagnostic CLI surface.
- The experimental CLI options and profile enums were removed:
  `--trace-variant`, `--trace-repair`, `--trace-target-deactivate`,
  `--trace-order-repair`, `--trace-mouse-stamp`,
  `--trace-mouse-sequence`, and `--trace-mouse-coordinate`.

## Stable Conclusions

### AppKit

The AppKit path can be made stable enough for the current implementation:

- pid-targeted public events can be delivered without making the target the
  frontmost app;
- delayed order repair is still required because some activation/order effects
  appear after the immediate post-dispatch cleanup;
- the cleanup should restore the original front window, deactivate the target,
  then run the delayed order repair guard.

This is not evidence that the same suppression model works for Chrome.

### Chromium / Electron

The only browser sequence observed to deliver a real coordinate click is still
a full target-area mouse down/up pair. Every sequence that avoids the visible
raise also fails to deliver the click.

Observed behavior:

- full target `down/up` can deliver the click, but Chrome raises or visibly
  activates afterward;
- target-area `down-only` does not deliver a click and can queue a later raise;
- target-area `up-only` behaves mostly like a release/reset and does not
  deliver a click;
- move-only and primer-only sequences are clean but non-delivering;
- offscreen or window-local coordinate variants can avoid raise in some cases,
  but they do not deliver the intended click;
- changing raw event fields such as `windowUnderMouseWindowId` did not produce
  a useful deliver-without-raise combination;
- the CUA-style minimal Chromium stamp did not remove the raise problem.

The important distinction is delivery vs. order side effect: the sequences that
reach Chrome's page content are the same sequences that trigger Chrome's late
window/order compensation.

### Repair / Suppression

The visible Chrome raise is not explained by the repair loop itself:

- observe-only tracing still showed Chrome raise after target mouse events;
- skipping cleanup did not prevent Chrome's raise;
- restore/deactivate ordering variants did not remove the behavior;
- using a longer delayed repair guard did not make the approach stable;
- removed SLS order primitives did not solve the issue.

The current conclusion is that "suppress" is not the whole problem. AppKit can
be suppressed because it accepts pid-targeted mouse delivery after
focus-without-raise and does not strongly fight the final order. Chrome appears
to couple trusted page-content mouse delivery with activation/order correction,
and that correction can happen after AOS's immediate cleanup window.

So the browser problem is likely one of:

- AOS needs a stronger and longer-lived ordering/focus guard than a single
  post-click repair pass;
- AOS needs a different browser-specific route that reaches page content
  without the same mouse activation path;
- Codex Computer Use is doing additional focus/order observation and repair
  outside the small dispatch window AOS tested.

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

These names do not prove the implementation, but they suggest the next useful
comparison is behavioral: watch Codex Computer Use perform the same browser
pixel click with an external AOS observer and determine whether it:

- prevents the raise before it becomes visible;
- repairs the raise faster than AOS's current guard;
- uses a different event target or trust path;
- avoids raw mouse delivery for Chrome page content.

## Next Work

Do not continue broad field-combination experiments without new evidence. The
matrix already showed the same pattern repeatedly: clean variants do not
deliver, delivering variants raise Chrome.

Useful next directions:

- build a passive observer for frontmost app, active app, window rank,
  protected-covered count, and cursor position while Codex Computer Use clicks
  Chrome;
- compare AOS and Codex event timing at the window-order level;
- investigate a long-lived `WindowOrderingObserver` / focus guard design;
- inspect whether event taps are used to suppress or rewrite activation side
  effects;
- keep a browser-specific non-mouse path on the table if the pixel route proves
  coupled to Chrome activation.

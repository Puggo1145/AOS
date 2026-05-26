# Detachable Notch Design

Date: 2026-05-26

## Goal

Add a move affordance to the opened Notch header. Holding and dragging this button detaches the Notch UI from the top screen notch into a floating rounded rectangle. Releasing near a screen edge stores it as an edge handle that can reveal the full panel on hover. Releasing away from edges leaves the panel floating at the drop position. Dragging back to the top notch area reattaches it to the original Notch position.

## Non-Goals

- No Sidecar protocol changes.
- No persistence of detached position across app launches.
- No multi-window duplicate Notch surface.
- No new fallback behavior for unsupported screen geometry.

## Architecture

Use the existing `NotchWindow` / `NotchWindowController` as the single host window. Add placement state alongside the existing open/closed status:

- `attachedTop`: current behavior, centered on the device or virtual notch.
- `detached(frame)`: floating rounded-rectangle panel at a concrete screen-space frame.
- `edgeHandle(edge, handleFrame, revealFrame)`: small edge handle plus the full reveal frame for hover expansion.

The existing `Status.closed`, `Status.popping`, and `Status.opened` still describe content visibility. Placement describes where and how the host panel is presented.

## UI

`NotchHeaderStripsView` adds an icon-only move button to the right strip, after the new conversation and conversation history buttons. The button uses the existing notch chrome button style and an accessibility label such as "Move Notch".

The move control is drag-first:

- Pressing it starts a detach drag.
- While dragging, the Notch renders as a floating rounded rectangle and follows the cursor.
- Releasing commits the placement.

The detached shape does not use the hardware-notch shoulder silhouette. It uses the same panel content, dimensions, material/color treatment, and bottom tray behavior, but inside a normal rounded rectangle.

## Drag And Snap Rules

Geometry lives in a pure model named `NotchPlacementGeometry`.

Inputs:

- screen frame
- current panel size
- pointer location
- current drag offset within the panel
- edge snap threshold
- top reattach threshold
- handle size

Release policy:

- If the pointer is inside the top reattach zone around the device notch, return `attachedTop`.
- Else if the pointer is within the edge snap threshold of any screen edge, return `edgeHandle`.
- Else return `detached(frame)`, clamped inside the screen frame.

When two edges are close, corners choose the nearest edge by absolute distance. Ties prefer left/right over top/bottom so side handles win at corners.

## Edge Handle Behavior

When placement is `edgeHandle`, the window frame shrinks to a small handle pinned to the chosen edge:

- left/right: vertical handle
- top/bottom: horizontal handle

The handle is the only visible UI while collapsed. It is a reveal affordance, not a second conversation surface.

On mouse enter into the handle or its edge hot zone:

- move the same `NotchWindow` to `revealFrame`
- render the full rounded-rectangle panel
- keep placement as edge-docked with a revealed substate

On mouse leaving the reveal frame plus slack:

- return the same window to `handleFrame`
- render the small handle again

Dragging the move button from a revealed edge panel uses the revealed panel frame as the drag start frame.

## Window And Hit Testing

`NotchWindowController` remains the owner of `NSPanel` frame changes. It applies placement updates by setting the window frame:

- top attached: existing top-strip frame
- detached: a clamped floating frame sized to the opened total panel budget
- edge handle collapsed: `handleFrame`
- edge handle revealed: `revealFrame`

Click-through must use the current placement:

- attached top uses the existing `mouseActiveRect` policy
- detached uses the rounded panel frame plus rendered shoulder-free bounds
- edge handle collapsed uses `handleFrame`
- edge handle revealed uses `revealFrame`

VoiceOver keeps the existing rule: click-through is disabled while VoiceOver is running so the floating and handle states remain reachable to assistive technologies.

## State Boundaries

`NotchViewModel` owns user-visible placement and drag state because SwiftUI needs to render the appropriate chrome. `NotchWindowController` owns AppKit frame mutation and global mouse tracking because those are window responsibilities.

No business-layer error handling is added. Geometry helpers use preconditions for invalid sizes or impossible screen inputs.

## Testing

Add failing tests before implementation:

- releasing near each screen edge returns the expected edge handle placement
- releasing away from edges returns a detached frame clamped inside the screen
- releasing in the top notch reattach zone returns `attachedTop`
- corner releases choose the nearest edge, with side-edge tie preference
- handle and reveal frames stay inside or intentionally pinned against the screen bounds
- click-through active rects follow detached and handle placements

Add UI-facing coverage where practical:

- move button is present in `NotchHeaderStripsView`
- move button has an accessibility label

Manual verification:

- drag from top notch to floating panel
- release at left, right, top, and bottom edges
- hover edge handle to reveal, then leave to collapse
- drag revealed panel away from the edge
- drag floating panel back to the top notch area to reattach
- verify Reduce Motion removes decorative transition timing where applicable

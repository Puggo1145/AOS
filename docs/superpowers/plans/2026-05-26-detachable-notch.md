# Detachable Notch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a draggable move button that detaches Notch into a floating rounded panel, snaps it into edge handles, reveals handles on hover, and reattaches at the top notch.

**Architecture:** Keep one `NotchWindow` and add a placement model separate from the existing open/closed status. Put all snap, clamp, handle, reveal, and active-rect math in `NotchPlacementGeometry`; let `NotchViewModel` own observable placement state; let `NotchWindowController` apply AppKit window frames.

**Tech Stack:** Swift 5.10, SwiftUI, AppKit `NSPanel`, Swift Testing, existing `EventMonitors`.

---

### Task 1: Placement Geometry

**Files:**
- Create: `Sources/Shell/Notch/NotchPlacementGeometry.swift`
- Test: `Tests/ShellTests/NotchPlacementGeometryTests.swift`

- [ ] **Step 1: Write failing tests**

Add tests for edge snap, detached clamp, top reattach, corner tie preference, handle frames, reveal frames, and active rect selection.

```swift
import CoreGraphics
import Testing
@testable import Shell

@Suite("Notch placement geometry")
struct NotchPlacementGeometryTests {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let notch = CGRect(x: 620, y: 868, width: 200, height: 32)
    private let panel = CGSize(width: 500, height: 300)

    @Test("release inside top notch zone attaches to top")
    func releaseInsideTopNotchZoneAttachesTop() {
        let placement = NotchPlacementGeometry.placementOnRelease(
            screenRect: screen,
            deviceNotchRect: notch,
            panelSize: panel,
            pointer: CGPoint(x: notch.midX, y: screen.maxY - 4),
            dragOffset: CGPoint(x: 250, y: 20)
        )
        #expect(placement == .attachedTop)
    }

    @Test("release near left edge creates left handle")
    func releaseNearLeftEdgeCreatesHandle() {
        let placement = NotchPlacementGeometry.placementOnRelease(
            screenRect: screen,
            deviceNotchRect: notch,
            panelSize: panel,
            pointer: CGPoint(x: 8, y: 450),
            dragOffset: CGPoint(x: 250, y: 20)
        )
        guard case let .edgeHandle(edge, handleFrame, revealFrame, revealed) = placement else {
            Issue.record("Expected edge handle")
            return
        }
        #expect(edge == .left)
        #expect(revealed == false)
        #expect(handleFrame.minX == screen.minX)
        #expect(handleFrame.midY == 450)
        #expect(revealFrame.minX == screen.minX)
        #expect(revealFrame.height == panel.height)
    }

    @Test("release away from edges creates clamped detached frame")
    func releaseAwayFromEdgesCreatesDetachedFrame() {
        let placement = NotchPlacementGeometry.placementOnRelease(
            screenRect: screen,
            deviceNotchRect: notch,
            panelSize: panel,
            pointer: CGPoint(x: 300, y: 300),
            dragOffset: CGPoint(x: 100, y: 50)
        )
        #expect(placement == .detached(CGRect(x: 200, y: 250, width: 500, height: 300)))
    }

    @Test("detached frame is clamped inside screen")
    func detachedFrameClampsInsideScreen() {
        let placement = NotchPlacementGeometry.placementOnRelease(
            screenRect: screen,
            deviceNotchRect: notch,
            panelSize: panel,
            pointer: CGPoint(x: 1430, y: 20),
            dragOffset: CGPoint(x: 10, y: 280)
        )
        #expect(placement == .detached(CGRect(x: 940, y: 0, width: 500, height: 300)))
    }

    @Test("corner tie prefers side edge")
    func cornerTiePrefersSideEdge() {
        let edge = NotchPlacementGeometry.nearestEdge(
            screenRect: screen,
            pointer: CGPoint(x: 8, y: 8),
            threshold: 16
        )
        #expect(edge == .left)
    }

    @Test("active rect follows placement")
    func activeRectFollowsPlacement() {
        let detached = NotchPlacement.detached(CGRect(x: 100, y: 100, width: 500, height: 300))
        #expect(NotchPlacementGeometry.mouseActiveRect(for: detached) == CGRect(x: 100, y: 100, width: 500, height: 300))

        let edge = NotchPlacement.edgeHandle(
            edge: .right,
            handleFrame: CGRect(x: 1416, y: 400, width: 24, height: 96),
            revealFrame: CGRect(x: 940, y: 300, width: 500, height: 300),
            revealed: false
        )
        #expect(NotchPlacementGeometry.mouseActiveRect(for: edge) == CGRect(x: 1416, y: 400, width: 24, height: 96))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter NotchPlacementGeometryTests`

Expected: FAIL because `NotchPlacementGeometry` and `NotchPlacement` do not exist.

- [ ] **Step 3: Implement geometry**

Create `NotchPlacementGeometry.swift` with:

```swift
import CoreGraphics

public enum NotchEdge: Sendable, Equatable {
    case left
    case right
    case top
    case bottom
}

public enum NotchPlacement: Sendable, Equatable {
    case attachedTop
    case detached(CGRect)
    case edgeHandle(edge: NotchEdge, handleFrame: CGRect, revealFrame: CGRect, revealed: Bool)
}

public enum NotchPlacementGeometry {
    public static let defaultEdgeSnapThreshold: CGFloat = 24
    public static let defaultTopAttachThreshold: CGFloat = 48
    public static let defaultHandleThickness: CGFloat = 24
    public static let defaultHandleLength: CGFloat = 96

    public static func placementOnRelease(
        screenRect: CGRect,
        deviceNotchRect: CGRect,
        panelSize: CGSize,
        pointer: CGPoint,
        dragOffset: CGPoint,
        edgeSnapThreshold: CGFloat = defaultEdgeSnapThreshold,
        topAttachThreshold: CGFloat = defaultTopAttachThreshold,
        handleThickness: CGFloat = defaultHandleThickness,
        handleLength: CGFloat = defaultHandleLength
    ) -> NotchPlacement
}
```

Implement the functions exercised by the tests using preconditions for non-positive sizes.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter NotchPlacementGeometryTests`

Expected: PASS.

### Task 2: ViewModel Placement State

**Files:**
- Modify: `Sources/Shell/Notch/NotchViewModel.swift`
- Test: `Tests/ShellTests/NotchPlacementGeometryTests.swift`

- [ ] **Step 1: Write failing ViewModel-facing test**

Add:

```swift
@Test("revealed edge placement uses reveal frame for active rect")
func revealedEdgePlacementUsesRevealFrameForActiveRect() {
    let placement = NotchPlacement.edgeHandle(
        edge: .left,
        handleFrame: CGRect(x: 0, y: 400, width: 24, height: 96),
        revealFrame: CGRect(x: 0, y: 300, width: 500, height: 300),
        revealed: true
    )
    #expect(NotchPlacementGeometry.mouseActiveRect(for: placement) == CGRect(x: 0, y: 300, width: 500, height: 300))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter NotchPlacementGeometryTests/revealedEdgePlacementUsesRevealFrameForActiveRect`

Expected: FAIL until `mouseActiveRect(for:)` handles revealed edge placements.

- [ ] **Step 3: Add observable state**

In `NotchViewModel`, add:

```swift
public var placement: NotchPlacement = .attachedTop
public var detachedCornerRadius: CGFloat { 28 }
public var isAttachedTop: Bool {
    if case .attachedTop = placement { return true }
    return false
}
public var isEdgeHandleCollapsed: Bool {
    if case .edgeHandle(_, _, _, false) = placement { return true }
    return false
}
```

Add mutators:

```swift
public func setPlacement(_ placement: NotchPlacement) {
    self.placement = placement
}

public func revealEdgeHandle() {
    guard case let .edgeHandle(edge, handleFrame, revealFrame, false) = placement else { return }
    placement = .edgeHandle(edge: edge, handleFrame: handleFrame, revealFrame: revealFrame, revealed: true)
}

public func collapseEdgeHandle() {
    guard case let .edgeHandle(edge, handleFrame, revealFrame, true) = placement else { return }
    placement = .edgeHandle(edge: edge, handleFrame: handleFrame, revealFrame: revealFrame, revealed: false)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter NotchPlacementGeometryTests`

Expected: PASS.

### Task 3: Window Frame Application

**Files:**
- Modify: `Sources/Shell/Notch/NotchWindowController.swift`
- Modify: `Sources/Shell/Notch/NotchViewModel+Events.swift`
- Test: `Tests/ShellTests/NotchGeometryTests.swift`

- [ ] **Step 1: Write failing frame policy tests**

Add tests that call pure helpers:

```swift
@Test("window frame for attached top uses existing top strip")
func windowFrameForAttachedTopUsesTopStrip() {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let result = NotchWindowController.windowFrame(
        for: .attachedTop,
        screenFrame: screen,
        topStripHeight: 720
    )
    #expect(result == NotchWindowController.makeTopStripRect(screenFrame: screen, panelHeight: 720))
}

@Test("window frame for detached placement is detached frame")
func windowFrameForDetachedPlacementIsDetachedFrame() {
    let frame = CGRect(x: 100, y: 100, width: 500, height: 300)
    let result = NotchWindowController.windowFrame(
        for: .detached(frame),
        screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        topStripHeight: 720
    )
    #expect(result == frame)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter NotchGeometryTests/windowFrame`

Expected: FAIL because `windowFrame(for:screenFrame:topStripHeight:)` does not exist.

- [ ] **Step 3: Implement frame application**

Add a stored `screenFrame` and `topStripHeight` in `NotchWindowController`, add:

```swift
public nonisolated static func windowFrame(
    for placement: NotchPlacement,
    screenFrame: CGRect,
    topStripHeight: CGFloat
) -> CGRect
```

Subscribe to `.notchPlacementChanged` notifications and call `window.setFrame(target, display: true, animate: false)`.

- [ ] **Step 4: Run tests**

Run: `swift test --filter NotchGeometryTests`

Expected: PASS.

### Task 4: Drag Bridge And Header Button

**Files:**
- Modify: `Sources/Shell/Notch/Chrome/NotchHeaderStripsView.swift`
- Modify: `Sources/Shell/Notch/NotchWindowController.swift`

- [ ] **Step 1: Add move button with drag gesture**

Add the move button after `historyButton`:

```swift
moveButton
```

Use:

```swift
private var moveButton: some View {
    headerIcon("arrow.up.left.and.arrow.down.right")
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    viewModel.beginOrUpdateDetachDrag(pointer: value.location)
                }
                .onEnded { value in
                    viewModel.endDetachDrag(pointer: value.location)
                }
        )
        .accessibilityLabel(Text("Move Notch"))
        .accessibilityAddTraits(.isButton)
}
```

- [ ] **Step 2: Implement drag mutators**

In `NotchViewModel`, add drag offset state and methods:

```swift
private var detachDragOffset: CGPoint?

public func beginOrUpdateDetachDrag(pointer: CGPoint) {
    if detachDragOffset == nil {
        notchOpen(.click)
        let startFrame = NotchPlacementGeometry.currentPanelFrame(
            placement: placement,
            attachedFrame: notchOpenedTotalRect
        )
        detachDragOffset = CGPoint(x: pointer.x - startFrame.minX, y: pointer.y - startFrame.minY)
    }
    guard let offset = detachDragOffset else { preconditionFailure("Detach drag offset missing") }
    let frame = NotchPlacementGeometry.detachedFrame(screenRect: screenRect, panelSize: notchOpenedTotalSize, pointer: pointer, dragOffset: offset)
    setPlacement(.detached(frame))
}

public func endDetachDrag(pointer: CGPoint) {
    guard let offset = detachDragOffset else { preconditionFailure("Cannot end a detach drag that has not begun") }
    detachDragOffset = nil
    setPlacement(NotchPlacementGeometry.placementOnRelease(screenRect: screenRect, deviceNotchRect: deviceNotchRect, panelSize: notchOpenedTotalSize, pointer: pointer, dragOffset: offset))
}
```

- [ ] **Step 3: Build**

Run: `swift build --target Shell`

Expected: PASS.

### Task 5: Detached And Handle Rendering

**Files:**
- Modify: `Sources/Shell/Notch/NotchView.swift`

- [ ] **Step 1: Render by placement**

Update `NotchView.body` so attached top uses the existing body and detached/revealed edge uses a rounded rectangle container. Collapsed edge handle renders a small capsule-like handle.

The handle view must be icon-free and simple:

```swift
RoundedRectangle(cornerRadius: 8)
    .fill(Color.black)
    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.14), lineWidth: 1))
```

- [ ] **Step 2: Preserve existing attached behavior**

Move the current `body` ZStack into a private `attachedTopBody` computed view. Add `floatingPanelBody` for detached/revealed edge. Keep existing `openedContent`, tray rendering, and Reduce Motion animations.

- [ ] **Step 3: Build**

Run: `swift build --target Shell`

Expected: PASS.

### Task 6: Edge Hover Reveal

**Files:**
- Modify: `Sources/Shell/Notch/NotchWindowController.swift`

- [ ] **Step 1: Add hover state transitions**

In the global mouse-location sink, after click-through is applied:

```swift
Self.applyEdgeReveal(window: window, viewModel: viewModel, mouse: location)
```

Implement:

```swift
private static func applyEdgeReveal(window: NotchWindow, viewModel: NotchViewModel, mouse: NSPoint)
```

Collapsed edge handle reveals when `handleFrame.insetBy(dx: -6, dy: -6).contains(mouse)`. Revealed edge handle collapses when `revealFrame.insetBy(dx: -24, dy: -24).contains(mouse) == false`.

- [ ] **Step 2: Build**

Run: `swift build --target Shell`

Expected: PASS.

### Task 7: Full Verification

**Files:**
- No file changes expected.

- [ ] **Step 1: Run Shell tests**

Run: `swift test --filter ShellTests`

Expected: PASS.

- [ ] **Step 2: Run full Swift tests**

Run: `swift test`

Expected: PASS.

- [ ] **Step 3: Build app**

Run: `Scripts/build-app.sh`

Expected: PASS and produce the app bundle.

- [ ] **Step 4: Inspect git diff**

Run: `git diff --stat && git diff --check`

Expected: no whitespace errors; changed files match this plan.

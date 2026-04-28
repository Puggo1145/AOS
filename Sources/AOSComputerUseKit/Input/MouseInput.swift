import AppKit
import CoreGraphics
import Darwin
import Foundation

// MARK: - MouseInput
//
// Per `docs/designs/computer-use.md` §"事件投递路径". Three regimes:
//
//   1. **Frontmost target**: HID tap (`CGEventPost(tap: .cghidEventTap)`)
//      with a leading `mouseMoved`. Required for OpenGL / GHOST viewports
//      (Blender, Unity, games) that filter every per-pid path. Real cursor
//      visibly moves — acceptable because the user is already looking at
//      the target.
//
//   2. **Background, plain left single/double click**: focus-without-raise
//      + off-screen primer recipe. `(-1, 1441)` primer pair satisfies
//      Chromium's user-activation gate without hitting any DOM, then the
//      target down/up pair does the real work.
//
//   3. **Background, modified / triple+ / right / middle / drag**: standard
//      NSEvent-bridged double-post (SLEventPostToPid + CGEvent.postToPid).
//      Skips the primer prologue. The two paths can both deliver — net
//      effect is two arrivals at the target, no observable side-effect
//      since neither moves the user's cursor.
//
// Coordinate convention: `point` is screen-points (top-left origin,
// y-down). NSEvent expects bottom-left y-up; we flip against the main
// screen height before constructing the NSEvent, then `.cgEvent` re-flips
// back.

public enum MouseInputError: Error, CustomStringConvertible, Sendable {
    case eventCreationFailed(String)

    public var description: String {
        switch self {
        case .eventCreationFailed(let phase):
            return "Failed to create CGEvent for \(phase)."
        }
    }
}

public enum MouseInput {
    public enum Button: String, Sendable {
        case left
        case right
        case middle
    }

    /// Optional sink for visualization / telemetry. Called from arbitrary
    /// threads on the synthetic-event paths (background dual-post and
    /// auth-signed primer). Frontmost HID-tap clicks intentionally skip
    /// this hook because they already move the real system cursor — adding
    /// an overlay there would double-render. Set once at process boot
    /// (typically from `AOSComputerUseKit.installVisualCursor()`); reading
    /// it on the hot path is a single property load.
    nonisolated(unsafe) public static var observer: MouseInputObserver?

    /// Synthesize click(s) at `point` (screen points) and deliver to `pid`.
    /// `count` clamped to 1…3 (single / double / triple). `modifiers`
    /// accepts the standard cmd/shift/option/ctrl/fn vocabulary; unknown
    /// names are ignored.
    public static func click(
        at point: CGPoint,
        toPid pid: pid_t,
        windowId: CGWindowID,
        button: Button,
        count: Int = 1,
        modifiers: [String] = []
    ) throws {
        let targetIsFrontmost = NSRunningApplication(processIdentifier: pid)?.isActive ?? false
        if targetIsFrontmost {
            // Real cursor moves with the HID tap — visualization observer
            // is intentionally NOT invoked here (would double-cursor).
            try clickFrontmostViaHIDTap(
                at: point, button: button, count: count, modifiers: modifiers)
            return
        }

        let observer = Self.observer
        observer?.willClick(at: point, button: button, count: count, windowId: windowId)
        defer { observer?.didClick(at: point, button: button, count: count, windowId: windowId) }

        if button == .left, count == 1 || count == 2, modifiers.isEmpty {
            try clickViaAuthSignedPost(
                at: point, toPid: pid, windowId: windowId, count: count)
            return
        }

        try clickViaDualPost(
            at: point, toPid: pid, windowId: windowId,
            button: button, count: count, modifiers: modifiers
        )
    }

    /// Drag — `mouseDown` at `from`, `mouseDragged` interpolation, `mouseUp`
    /// at `to`. Delivered via the dual-post path (per-pid + auth-message
    /// off, public CGEventPostToPid). No primer prologue: drag is by
    /// definition multiple events that already register as live input.
    public static func drag(
        from: CGPoint,
        to: CGPoint,
        toPid pid: pid_t,
        windowId: CGWindowID
    ) throws {
        let observer = Self.observer
        observer?.willDrag(from: from, to: to, windowId: windowId)
        defer { observer?.didDrag(from: from, to: to, windowId: windowId) }

        let winNum = Int(windowId)

        let down = try buildBridgedEvent(
            type: .leftMouseDown,
            screenPoint: from,
            modifierFlags: [],
            clickCount: 1,
            windowNumber: winNum
        )
        let up = try buildBridgedEvent(
            type: .leftMouseUp,
            screenPoint: to,
            modifierFlags: [],
            clickCount: 1,
            windowNumber: winNum
        )
        postBoth(down, toPid: pid)
        usleep(20_000)

        // Linear interpolation. 12 steps gives reasonable smoothness
        // without flooding the queue; AppKit + Chromium drag handlers
        // accept this density.
        let steps = 12
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let p = CGPoint(
                x: from.x + (to.x - from.x) * t,
                y: from.y + (to.y - from.y) * t
            )
            let drag = try buildBridgedEvent(
                type: .leftMouseDragged,
                screenPoint: p,
                modifierFlags: [],
                clickCount: 1,
                windowNumber: winNum
            )
            postBoth(drag, toPid: pid)
            usleep(15_000)
        }

        postBoth(up, toPid: pid)
    }

    /// Wheel scroll — pixel-quantized `dx` / `dy` deltas. Delivered via
    /// the dual-post path. CGEvent's scroll constructor handles both
    /// vertical and horizontal in a single event (axes 1 and 2).
    public static func scroll(
        at point: CGPoint,
        dx: Int32,
        dy: Int32,
        toPid pid: pid_t,
        windowId: CGWindowID
    ) throws {
        guard
            let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: dy,
                wheel2: dx,
                wheel3: 0
            )
        else {
            throw MouseInputError.eventCreationFailed("scroll")
        }
        event.location = point
        _ = SkyLightEventPost.postToPid(pid, event: event, attachAuthMessage: false)
        event.postToPid(pid)
        _ = windowId  // stamped via location anchor; not field-stamped
        Self.observer?.didScroll(at: point, windowId: windowId)
    }

    // MARK: - Recipe: focus-without-raise + off-screen primer (left S/D click)

    /// Reference: `docs/designs/computer-use.md` §"事件投递路径" — the 5-event
    /// recipe for backgrounded plain left clicks:
    ///
    ///   1. `FocusWithoutRaise.activateWithoutRaise(pid, wid)`
    ///   2. 50ms settle
    ///   3. `mouseMoved` → target
    ///   4. off-screen primer down/up at `(-1, 1441)` (no DOM hit, opens
    ///      Chromium user-activation gate)
    ///   5. target down/up pair(s)
    ///
    /// Each event carries SkyLight raw fields stamped via
    /// `SLEventSetIntegerValueField` and the window-local point via
    /// `CGEventSetWindowLocation`. Auth message is **not** attached for
    /// mouse — it forks the post path off the IOHIDPostEvent route
    /// Chromium's window-event handler reads from.
    private static func clickViaAuthSignedPost(
        at point: CGPoint,
        toPid pid: pid_t,
        windowId: CGWindowID,
        count: Int
    ) throws {
        let clickPairs = max(1, min(2, count))
        let winNum = Int(windowId)

        let windowBounds = WindowEnumerator.window(forId: windowId)?.bounds
        let windowLocalTarget: CGPoint = {
            guard let bounds = windowBounds else { return point }
            return CGPoint(x: point.x - bounds.x, y: point.y - bounds.y)
        }()

        // Step 1: yabai-style activation. Skip if SPI unavailable —
        // we'll still post events; they just won't trigger Chromium's
        // user-activation gate as reliably.
        if windowId != 0 {
            _ = FocusWithoutRaise.activateWithoutRaise(targetPid: pid, targetWid: windowId)
            usleep(50_000)
        }

        func makeEvent(_ type: NSEvent.EventType, clickCount: Int) throws -> CGEvent {
            guard
                let ns = NSEvent.mouseEvent(
                    with: type,
                    location: .zero,
                    modifierFlags: [],
                    timestamp: 0,
                    windowNumber: winNum,
                    context: nil,
                    eventNumber: 0,
                    clickCount: clickCount,
                    pressure: 1.0
                )
            else {
                throw MouseInputError.eventCreationFailed("\(type.rawValue)")
            }
            guard let cg = ns.cgEvent else {
                throw MouseInputError.eventCreationFailed("\(type.rawValue) cgEvent bridge")
            }
            return cg
        }

        // Field stamps explained — see design doc §"事件投递路径".
        //   f3   (mouseEventButtonNumber) = 0       (left)
        //   f7   (mouseEventSubtype)      = 3       (NSEventSubtypeMouseEvent)
        //   f1   (mouseEventClickState)             (1 → 2 for double)
        //   f51  via SkyLight raw-field SPI         (window id)
        //   f40  via SkyLight raw-field SPI         (target pid; Chromium
        //                                            synthetic-event filter
        //                                            latches on this)
        //   CGEventSetWindowLocation                (window-local point)
        func stamp(
            _ event: CGEvent,
            screenPt: CGPoint,
            windowLocalPt: CGPoint,
            clickState: Int64
        ) {
            event.location = screenPt
            event.setIntegerValueField(.mouseEventButtonNumber, value: 0)
            event.setIntegerValueField(.mouseEventSubtype, value: 3)
            event.setIntegerValueField(.mouseEventClickState, value: clickState)
            if windowId != 0 {
                event.setIntegerValueField(
                    .mouseEventWindowUnderMousePointer, value: Int64(windowId)
                )
                event.setIntegerValueField(
                    .mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
                    value: Int64(windowId)
                )
            }
            _ = SkyLightEventPost.setWindowLocation(event, windowLocalPt)
            _ = SkyLightEventPost.setIntegerField(event, field: 40, value: Int64(pid))
        }

        let move = try makeEvent(.mouseMoved, clickCount: 0)
        stamp(move, screenPt: point, windowLocalPt: windowLocalTarget, clickState: 0)

        // `(-1, -1)` is outside every window — Chrome accepts the primer
        // for its user-activation gate but discards the click since no
        // DOM element lives there. (-1, 1441) in the design is just one
        // of many choices; the core requirement is "no element to hit".
        let offScreenPrimer = CGPoint(x: -1, y: -1)
        let primerDown = try makeEvent(.leftMouseDown, clickCount: 1)
        let primerUp   = try makeEvent(.leftMouseUp,   clickCount: 1)
        stamp(primerDown, screenPt: offScreenPrimer, windowLocalPt: offScreenPrimer, clickState: 1)
        stamp(primerUp,   screenPt: offScreenPrimer, windowLocalPt: offScreenPrimer, clickState: 1)

        var targetPairs: [(down: CGEvent, up: CGEvent)] = []
        for pairIndex in 1...clickPairs {
            let down = try makeEvent(.leftMouseDown, clickCount: pairIndex)
            let up   = try makeEvent(.leftMouseUp,   clickCount: pairIndex)
            let state = Int64(pairIndex)
            stamp(down, screenPt: point, windowLocalPt: windowLocalTarget, clickState: state)
            stamp(up,   screenPt: point, windowLocalPt: windowLocalTarget, clickState: state)
            targetPairs.append((down, up))
        }

        func post(_ event: CGEvent) {
            event.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            // Mouse: NO auth message — attaching it forks the post off
            // IOHIDPostEvent onto a direct-mach path Chromium's
            // cgAnnotatedSessionEventTap subscriber doesn't see.
            _ = SkyLightEventPost.postToPid(pid, event: event, attachAuthMessage: false)
        }

        post(move)
        usleep(15_000)
        post(primerDown)
        usleep(1_000)
        post(primerUp)
        usleep(100_000)  // ≥1 frame so Chromium splits primer + target into two gestures.
        for (i, pair) in targetPairs.enumerated() {
            post(pair.down)
            usleep(1_000)
            post(pair.up)
            if i < targetPairs.count - 1 {
                usleep(80_000)  // Below double-click threshold, clear of coalescing.
            }
        }
    }

    // MARK: - Recipe: dual-post (modifier / right / middle / triple+)

    private static func clickViaDualPost(
        at point: CGPoint,
        toPid pid: pid_t,
        windowId: CGWindowID,
        button: Button,
        count: Int,
        modifiers: [String]
    ) throws {
        let clamped = max(1, min(3, count))
        let (downType, upType) = nsEventTypes(for: button)
        let modifierFlags = modifierMask(for: modifiers)
        let winNum = Int(windowId)

        for clickIndex in 1...clamped {
            let down = try buildBridgedEvent(
                type: downType,
                screenPoint: point,
                modifierFlags: modifierFlags,
                clickCount: clickIndex,
                windowNumber: winNum
            )
            let up = try buildBridgedEvent(
                type: upType,
                screenPoint: point,
                modifierFlags: modifierFlags,
                clickCount: clickIndex,
                windowNumber: winNum
            )
            // NSEvent's mouseEvent is supposed to set click state; re-stamp
            // anyway because some SDK builds drop it on the bridge.
            down.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex))

            postBoth(down, toPid: pid)
            usleep(30_000)  // intra-pair gap
            postBoth(up, toPid: pid)
            if clickIndex < clamped {
                usleep(80_000)  // inter-pair gap
            }
        }
    }

    // MARK: - Recipe: HID tap (frontmost target, viewport-friendly)

    private static func clickFrontmostViaHIDTap(
        at point: CGPoint,
        button: Button,
        count: Int,
        modifiers: [String]
    ) throws {
        let clamped = max(1, min(3, count))
        let (downType, upType) = cgEventTypes(for: button)
        let mouseButton: CGMouseButton = {
            switch button {
            case .left: return .left
            case .right: return .right
            case .middle: return .center
            }
        }()
        let modifierFlags = cgEventFlags(for: modifiers)

        // hidSystemState mimics hardware origin; some viewports
        // (Blender's GHOST) check this.
        let src = CGEventSource(stateID: .hidSystemState)

        guard
            let move = CGEvent(
                mouseEventSource: src,
                mouseType: .mouseMoved,
                mouseCursorPosition: point,
                mouseButton: mouseButton
            )
        else { throw MouseInputError.eventCreationFailed("frontmost hid-tap mouseMoved") }
        move.flags = modifierFlags
        move.post(tap: .cghidEventTap)
        usleep(30_000)  // give the OS a frame to propagate cursor position

        for clickIndex in 1...clamped {
            guard
                let down = CGEvent(
                    mouseEventSource: src, mouseType: downType,
                    mouseCursorPosition: point, mouseButton: mouseButton
                ),
                let up = CGEvent(
                    mouseEventSource: src, mouseType: upType,
                    mouseCursorPosition: point, mouseButton: mouseButton
                )
            else { throw MouseInputError.eventCreationFailed("frontmost hid-tap click") }
            down.flags = modifierFlags
            up.flags = modifierFlags
            down.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex))
            down.post(tap: .cghidEventTap)
            usleep(20_000)
            up.post(tap: .cghidEventTap)
            if clickIndex < clamped {
                usleep(80_000)
            }
        }
    }

    // MARK: - Helpers

    private static func cgEventTypes(for button: Button) -> (down: CGEventType, up: CGEventType) {
        switch button {
        case .left: return (.leftMouseDown, .leftMouseUp)
        case .right: return (.rightMouseDown, .rightMouseUp)
        case .middle: return (.otherMouseDown, .otherMouseUp)
        }
    }

    private static func nsEventTypes(for button: Button) -> (down: NSEvent.EventType, up: NSEvent.EventType) {
        switch button {
        case .left: return (.leftMouseDown, .leftMouseUp)
        case .right: return (.rightMouseDown, .rightMouseUp)
        case .middle: return (.otherMouseDown, .otherMouseUp)
        }
    }

    private static func cgEventFlags(for modifiers: [String]) -> CGEventFlags {
        var flags: CGEventFlags = []
        for raw in modifiers {
            switch raw.lowercased() {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "option", "alt", "opt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            case "fn", "function": flags.insert(.maskSecondaryFn)
            default: break
            }
        }
        return flags
    }

    private static func modifierMask(for modifiers: [String]) -> NSEvent.ModifierFlags {
        var mask: NSEvent.ModifierFlags = []
        for raw in modifiers {
            switch raw.lowercased() {
            case "cmd", "command": mask.insert(.command)
            case "shift": mask.insert(.shift)
            case "option", "alt": mask.insert(.option)
            case "ctrl", "control": mask.insert(.control)
            case "fn": mask.insert(.function)
            default: break
            }
        }
        return mask
    }

    private static func postBoth(_ event: CGEvent, toPid pid: pid_t) {
        // Mouse path skips auth message — see file-level doc.
        _ = SkyLightEventPost.postToPid(pid, event: event, attachAuthMessage: false)
        event.postToPid(pid)
    }

    private static func buildBridgedEvent(
        type: NSEvent.EventType,
        screenPoint: CGPoint,
        modifierFlags: NSEvent.ModifierFlags,
        clickCount: Int,
        windowNumber: Int
    ) throws -> CGEvent {
        let cocoaPoint = cocoaLocation(fromScreenPoint: screenPoint)
        guard
            let ns = NSEvent.mouseEvent(
                with: type,
                location: cocoaPoint,
                modifierFlags: modifierFlags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: clickCount,
                pressure: 1.0
            )
        else {
            throw MouseInputError.eventCreationFailed("bridged \(type.rawValue)")
        }
        guard let cg = ns.cgEvent else {
            throw MouseInputError.eventCreationFailed("bridged \(type.rawValue) → cgEvent")
        }
        return cg
    }

    /// Quartz top-left → AppKit bottom-left. NSEvent expects bottom-left
    /// y-up; flip against `NSScreen.main.frame.height`. The
    /// `.cgEvent` bridge re-flips back to Quartz top-left when emitting
    /// the CGEvent, so the posted event lands at the original
    /// screen-point.
    private static func cocoaLocation(fromScreenPoint point: CGPoint) -> CGPoint {
        let mainScreenHeight = NSScreen.main?.frame.height
            ?? NSScreen.screens.first?.frame.height
            ?? 0
        return CGPoint(x: point.x, y: mainScreenHeight - point.y)
    }
}

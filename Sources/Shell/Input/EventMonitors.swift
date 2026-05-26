import Foundation
import AppKit
import Combine

// MARK: - EventMonitors
//
// Singleton aggregating the four event sources the Notch UI cares about.
// Per notch-ui.md and notch-dev-guide.md §5.2 / §5.3:
//   - mouseLocation: drives closed↔popping transitions and edge highlight
//   - mouseDown:     drives popping/closed → opened, opened → closed
//   - keyDown:       drives ESC → cancel + close
//
// All publishers fire on the main runloop because every downstream consumer
// (NotchViewModel, EdgeHighlightOverlay) is @MainActor.

@MainActor
public final class EventMonitors {
    public static let shared = EventMonitors()

    /// Latest mouse location in screen coords (origin at lower-left of primary
    /// screen). Updated on every `mouseMoved` (and is also seeded with the
    /// current location at start).
    public let mouseLocation = CurrentValueSubject<NSPoint, Never>(.zero)

    /// Fires once per left-mouse-down. The event is preserved so downstream
    /// can distinguish a local click inside the Notch window from a global
    /// outside click; the live mouse location remains the coordinate truth.
    public let mouseDown = PassthroughSubject<NSEvent?, Never>()

    /// Fires during left-button drags. Used for operations that must continue
    /// even when moving the Notch window causes the original SwiftUI control
    /// to leave the cursor.
    public let mouseDragged = PassthroughSubject<NSEvent?, Never>()

    /// Fires when the left button is released. Completes global drag
    /// lifecycles started by controls inside the Notch window.
    public let mouseUp = PassthroughSubject<NSEvent?, Never>()

    /// Fires the keyCode of every keyDown. Subscribers filter for ESC (53).
    public let keyDown = PassthroughSubject<UInt16, Never>()

    private var moveMonitor: EventMonitor?
    private var downMonitor: EventMonitor?
    private var dragMonitor: EventMonitor?
    private var upMonitor: EventMonitor?
    private var keyMonitor: EventMonitor?

    private init() {}

    public func start() {
        guard moveMonitor == nil else { return }

        // Seed mouseLocation immediately so downstream hot-rect checks have a
        // valid value before the first mouseMoved event fires.
        mouseLocation.send(NSEvent.mouseLocation)

        let move = EventMonitor(mask: .mouseMoved) { [weak self] _ in
            self?.mouseLocation.send(NSEvent.mouseLocation)
        }
        let down = EventMonitor(mask: .leftMouseDown) { [weak self] event in
            self?.mouseDown.send(event)
        }
        let drag = EventMonitor(mask: .leftMouseDragged) { [weak self] event in
            self?.mouseLocation.send(NSEvent.mouseLocation)
            self?.mouseDragged.send(event)
        }
        let up = EventMonitor(mask: .leftMouseUp) { [weak self] event in
            self?.mouseLocation.send(NSEvent.mouseLocation)
            self?.mouseUp.send(event)
        }
        let key = EventMonitor(mask: .keyDown) { [weak self] event in
            guard let event else { return }
            self?.keyDown.send(event.keyCode)
        }
        move.start()
        down.start()
        drag.start()
        up.start()
        key.start()
        moveMonitor = move
        downMonitor = down
        dragMonitor = drag
        upMonitor = up
        keyMonitor = key
    }

    public func stop() {
        moveMonitor?.stop()
        downMonitor?.stop()
        dragMonitor?.stop()
        upMonitor?.stop()
        keyMonitor?.stop()
        moveMonitor = nil
        downMonitor = nil
        dragMonitor = nil
        upMonitor = nil
        keyMonitor = nil
    }
}

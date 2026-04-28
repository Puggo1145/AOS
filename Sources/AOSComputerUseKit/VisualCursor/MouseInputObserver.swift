import AppKit
import CoreGraphics
import Foundation

// MARK: - MouseInputObserver
//
// Hook surface that `MouseInput` calls around every synthetic mouse event.
// Exists so visualization (and future telemetry / mirroring) can ride on the
// existing event path without `MouseInput` knowing anything about the
// overlay. Observers MUST be cheap and non-blocking — `MouseInput` runs on
// hot dispatch paths and any observer cost shows up as click latency.
//
// All callbacks may fire from arbitrary threads. Implementations are
// responsible for hopping to the main actor when they touch UI. Frontmost
// HID-tap clicks (which move the real system cursor) deliberately do NOT
// invoke the observer — the OS already shows the cursor and a software
// overlay would double-render. See `MouseInput.click` for the dispatch.

public protocol MouseInputObserver: AnyObject, Sendable {
    func willClick(
        at point: CGPoint,
        button: MouseInput.Button,
        count: Int,
        windowId: CGWindowID
    )
    func didClick(
        at point: CGPoint,
        button: MouseInput.Button,
        count: Int,
        windowId: CGWindowID
    )
    func willDrag(from start: CGPoint, to end: CGPoint, windowId: CGWindowID)
    func didDrag(from start: CGPoint, to end: CGPoint, windowId: CGWindowID)
    func didScroll(at point: CGPoint, windowId: CGWindowID)
}

// MARK: - VisualCursorMouseObserver
//
// Default observer that drives `SoftwareCursorOverlay`. Resolves the
// target window's CGWindowList layer once per call so the overlay panel
// can sit at the same window level as the operated app, then delegates
// to the overlay's main-actor API via `VisualCursorSupport.performOnMain`.
//
// We deliberately do not stash a CursorTargetWindow inside `willClick`
// for `didClick` to reuse: the windowId + layer is cheap to look up, and
// keeping each callback self-contained means losing a `will` doesn't
// strand state.

public final class VisualCursorMouseObserver: MouseInputObserver {
    public static let shared = VisualCursorMouseObserver()

    private init() {}

    public func willClick(
        at point: CGPoint,
        button _: MouseInput.Button,
        count _: Int,
        windowId: CGWindowID
    ) {
        let target = targetWindow(for: windowId)
        VisualCursorSupport.performOnMain {
            SoftwareCursorOverlay.moveCursor(to: Self.appKitPoint(from: point), in: target)
        }
    }

    public func didClick(
        at point: CGPoint,
        button: MouseInput.Button,
        count: Int,
        windowId: CGWindowID
    ) {
        let target = targetWindow(for: windowId)
        let mapped = mapButton(button)
        VisualCursorSupport.performOnMain {
            SoftwareCursorOverlay.pulseClick(
                at: Self.appKitPoint(from: point),
                clickCount: count,
                mouseButton: mapped,
                in: target
            )
        }
    }

    public func willDrag(from start: CGPoint, to _: CGPoint, windowId: CGWindowID) {
        let target = targetWindow(for: windowId)
        VisualCursorSupport.performOnMain {
            SoftwareCursorOverlay.moveCursor(to: Self.appKitPoint(from: start), in: target)
        }
    }

    public func didDrag(from _: CGPoint, to end: CGPoint, windowId: CGWindowID) {
        let target = targetWindow(for: windowId)
        VisualCursorSupport.performOnMain {
            SoftwareCursorOverlay.settle(at: Self.appKitPoint(from: end), in: target)
        }
    }

    public func didScroll(at point: CGPoint, windowId: CGWindowID) {
        let target = targetWindow(for: windowId)
        VisualCursorSupport.performOnMain {
            SoftwareCursorOverlay.settle(at: Self.appKitPoint(from: point), in: target)
        }
    }

    // MARK: - helpers

    private func targetWindow(for windowId: CGWindowID) -> CursorTargetWindow? {
        guard windowId != 0 else { return nil }
        guard let info = WindowEnumerator.window(forId: windowId) else { return nil }
        return CursorTargetWindow(windowID: windowId, layer: info.layer)
    }

    /// `MouseInput` uses CG screen-points (top-left origin, y-down) — see
    /// the file-level doc on `MouseInput.swift`. The overlay places its
    /// `NSPanel` via `setFrameOrigin`, which is AppKit global coords
    /// (bottom-left origin, y-up, with multi-monitor offsets that don't
    /// match CG's). Without this conversion the panel lands off-screen
    /// and gets clamped to a corner — looks identical to "no cursor at
    /// all." Per-display mapping uses `CGDisplayBounds` ↔ `NSScreen.frame`
    /// so the cursor lands on the correct monitor.
    @MainActor
    private static func appKitPoint(from cgPoint: CGPoint) -> CGPoint {
        for screen in NSScreen.screens {
            guard
                let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { continue }
            let cgFrame = CGDisplayBounds(CGDirectDisplayID(screenNumber.uint32Value))
            guard cgFrame.contains(cgPoint) else { continue }
            let localX = cgPoint.x - cgFrame.minX
            let localY = cgPoint.y - cgFrame.minY
            return CGPoint(
                x: screen.frame.minX + localX,
                y: screen.frame.maxY - localY
            )
        }
        // Fallback: assume primary-screen coords.
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: cgPoint.x, y: h - cgPoint.y)
    }

    private func mapButton(_ button: MouseInput.Button) -> VisualCursorMouseButton {
        switch button {
        case .left: return .left
        case .right: return .right
        case .middle: return .middle
        }
    }
}

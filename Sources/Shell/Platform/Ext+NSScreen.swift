import Foundation
import AppKit

// MARK: - NSScreen helpers
//
// Per docs/guide/notch-dev-guide.md §2.1 / §2.2 — detect physical notch and
// pick the built-in display.
//
// Dev-time fallback: when no notch is detected (no built-in MacBook with
// notch attached), `notchSize` returns a virtual `150×28` rect *only* if
// the env var `NOTCH_VIRTUAL_NOTCH=1` is set. Otherwise `notchSize == .zero`
// and the Shell refuses to show a NotchWindow on that screen.

extension NSScreen {
    /// Physical notch rectangle reported by macOS, or zero if the screen has none.
    public var notchSize: CGSize {
        if safeAreaInsets.top > 0 {
            let h = safeAreaInsets.top
            let leftPad = auxiliaryTopLeftArea?.width ?? 0
            let rightPad = auxiliaryTopRightArea?.width ?? 0
            if leftPad > 0, rightPad > 0 {
                let w = frame.width - leftPad - rightPad
                return CGSize(width: w, height: h)
            }
        }
        // Dev fallback — only honored when explicitly opted in via env.
        if ProcessInfo.processInfo.environment["NOTCH_VIRTUAL_NOTCH"] == "1" {
            return CGSize(width: 150, height: 28)
        }
        return .zero
    }

    /// True if this screen is the built-in display (the only one that ever
    /// has a physical notch).
    public var isBuildinDisplay: Bool {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let id = deviceDescription[key],
              let rid = (id as? NSNumber)?.uint32Value else { return false }
        return CGDisplayIsBuiltin(rid) == 1
    }

    /// First built-in display, or nil if none is currently attached. Falls
    /// back to `NSScreen.main` only when `NOTCH_VIRTUAL_NOTCH=1` (dev mode).
    public static var buildin: NSScreen? {
        if let s = screens.first(where: { $0.isBuildinDisplay }) { return s }
        if ProcessInfo.processInfo.environment["NOTCH_VIRTUAL_NOTCH"] == "1" {
            return NSScreen.main
        }
        return nil
    }
}

import ApplicationServices
import Foundation

// MARK: - SyntheticAppFocusEnforcer
//
// Layer 2 of `FocusGuard`. Writes `AXFocused` / `AXMain` on the target
// window and `AXFocused` on the element so the target's internal AppKit
// state machine believes it has focus during the AX action — without
// calling `NSRunningApplication.activate(...)` (which would steal focus
// at the system level). After the action completes the prior values are
// restored.
//
// Best-effort by design: most AX elements (labels, static text) reject
// AXFocused writes. The priority is that the action lands; perfect focus
// fidelity on the target is a second-order concern.

/// Opaque snapshot of focus state captured before the action; pass back
/// to `reenableActivation` to restore.
public struct FocusState: Sendable {
    fileprivate let pid: pid_t
    fileprivate let window: AXUIElement?
    fileprivate let element: AXUIElement?
    fileprivate let priorWindowFocused: Bool?
    fileprivate let priorWindowMain: Bool?
    fileprivate let priorElementFocused: Bool?
}

public actor SyntheticAppFocusEnforcer {
    public init() {}

    public func preventActivation(
        pid: pid_t,
        window: AXUIElement?,
        element: AXUIElement?
    ) -> FocusState {
        let priorWindowFocused = window.flatMap { Self.readBool($0, "AXFocused") }
        let priorWindowMain = window.flatMap { Self.readBool($0, "AXMain") }
        let priorElementFocused = element.flatMap { Self.readBool($0, "AXFocused") }

        if let window {
            Self.writeBool(window, "AXFocused", true)
            Self.writeBool(window, "AXMain", true)
        }
        if let element {
            Self.writeBool(element, "AXFocused", true)
        }

        return FocusState(
            pid: pid,
            window: window,
            element: element,
            priorWindowFocused: priorWindowFocused,
            priorWindowMain: priorWindowMain,
            priorElementFocused: priorElementFocused
        )
    }

    public func reenableActivation(_ state: FocusState) {
        if let window = state.window {
            if let prior = state.priorWindowFocused {
                Self.writeBool(window, "AXFocused", prior)
            }
            if let prior = state.priorWindowMain {
                Self.writeBool(window, "AXMain", prior)
            }
        }
        if let element = state.element, let prior = state.priorElementFocused {
            Self.writeBool(element, "AXFocused", prior)
        }
    }

    // MARK: - Static helpers

    private static func readBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let v = value else { return nil }
        if CFGetTypeID(v) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((v as! CFBoolean))
        }
        return nil
    }

    private static func writeBool(_ element: AXUIElement, _ attribute: String, _ value: Bool) {
        _ = AXUIElementSetAttributeValue(
            element,
            attribute as CFString,
            (value ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef
        )
    }
}

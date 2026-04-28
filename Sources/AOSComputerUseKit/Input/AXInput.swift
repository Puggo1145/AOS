import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - AXInput
//
// Per `docs/designs/computer-use.md` §"操作降级链路". The AX-action and
// AX-attribute paths sit at layers 1 and 2 of the operation-degradation
// chain; `MouseInput` / `KeyboardInput` cover layer 3 (directed event
// posting). This file owns the layer-1/2 primitives plus
// `screenCenter(of:)` — the 5×5 hit-test self-calibration grid the design
// calls out.

public enum AXInputError: Error, CustomStringConvertible, Sendable {
    case notAuthorized
    case noElementAt(CGPoint)
    case actionFailed(action: String, code: Int32)
    case setAttributeFailed(attribute: String, code: Int32)

    public var description: String {
        switch self {
        case .notAuthorized:
            return "Accessibility permission not granted."
        case .noElementAt(let p):
            return "No AX element at (\(Int(p.x)), \(Int(p.y)))."
        case .actionFailed(let action, let code):
            return "AX action \(action) failed with code \(code)."
        case .setAttributeFailed(let attribute, let code):
            return "AX setAttribute \(attribute) failed with code \(code)."
        }
    }
}

public enum AXInput {
    /// Throw `notAuthorized` if the host process lacks Accessibility TCC.
    public static func requireAuthorized() throws {
        guard AXIsProcessTrusted() else {
            throw AXInputError.notAuthorized
        }
    }

    /// Element at a screen point (top-left origin). Most plausible
    /// on-screen points resolve to *something* (desktop background,
    /// menu bar, etc).
    public static func elementAt(_ point: CGPoint) throws -> AXUIElement {
        try requireAuthorized()
        let system = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(
            system, Float(point.x), Float(point.y), &element
        )
        guard result == .success, let resolved = element else {
            throw AXInputError.noElementAt(point)
        }
        return resolved
    }

    /// Layer 1 of the operation-degradation chain. Caller is expected to
    /// have validated the action against `advertisedActionNames` first;
    /// `AXUIElementPerformAction` returns success even on no-op actions
    /// (the design calls this out — verify before calling).
    public static func performAction(_ action: String, on element: AXUIElement) throws {
        let result = AXUIElementPerformAction(element, action as CFString)
        guard result == .success else {
            throw AXInputError.actionFailed(action: action, code: result.rawValue)
        }
    }

    /// Action names advertised via `AXUIElementCopyActionNames`. Used to
    /// gate `performAction` so we don't fire `AXPress` on an element that
    /// doesn't support it.
    public static func advertisedActionNames(of element: AXUIElement) -> [String] {
        var names: CFArray?
        let result = AXUIElementCopyActionNames(element, &names)
        guard result == .success, let names = names as? [String] else { return [] }
        return names
    }

    /// Layer 2 — attribute write fallback when the element has no
    /// matching action.
    public static func setAttribute(
        _ attribute: String, on element: AXUIElement, value: CFTypeRef
    ) throws {
        let result = AXUIElementSetAttributeValue(element, attribute as CFString, value)
        guard result == .success else {
            throw AXInputError.setAttributeFailed(attribute: attribute, code: result.rawValue)
        }
    }

    /// Resolve a screen-point center for `element`. If the geometric
    /// center fails the AX hit-test, scan a 5×5 grid (skipping corners
    /// — they tend to land on padding) and return the first interior
    /// point that hit-tests back to the element or one of its
    /// descendants. Falls back to the geometric center if every grid
    /// point fails (the element is occluded — caller should bail to
    /// AX-action-only).
    public static func screenCenter(of element: AXUIElement) -> CGPoint? {
        guard let rect = boundingRect(of: element) else { return nil }

        let center = CGPoint(x: rect.midX, y: rect.midY)
        if hitTestResolves(to: element, at: center) { return center }

        let cols = 5, rows = 5
        for r in 0..<rows {
            for c in 0..<cols {
                if (r == 0 || r == rows - 1) && (c == 0 || c == cols - 1) { continue }
                let fx = (CGFloat(c) + 0.5) / CGFloat(cols)
                let fy = (CGFloat(r) + 0.5) / CGFloat(rows)
                let point = CGPoint(
                    x: rect.minX + rect.width * fx,
                    y: rect.minY + rect.height * fy
                )
                if hitTestResolves(to: element, at: point) { return point }
            }
        }
        return center
    }

    /// `AXPosition` + `AXSize` → `CGRect`. Returns nil when either
    /// attribute is missing or size is non-positive.
    public static func boundingRect(of element: AXUIElement) -> CGRect? {
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, "AXPosition" as CFString, &posValue) == .success,
            AXUIElementCopyAttributeValue(element, "AXSize" as CFString, &sizeValue) == .success,
            let posValue, let sizeValue,
            CFGetTypeID(posValue) == AXValueGetTypeID(),
            CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        guard size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Does a hit-test at `point` resolve to `target` or one of its
    /// descendants? "Descendant" = walking up `AXParent` from the hit
    /// result eventually returns the target.
    private static func hitTestResolves(to target: AXUIElement, at point: CGPoint) -> Bool {
        guard let hit = try? elementAt(point) else { return false }
        var current: AXUIElement? = hit
        // 16-hop cap — pathological deep trees shouldn't stall a click.
        for _ in 0..<16 {
            guard let node = current else { return false }
            if CFEqual(node, target) { return true }
            var parent: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(node, "AXParent" as CFString, &parent)
            guard
                result == .success,
                let parent,
                CFGetTypeID(parent) == AXUIElementGetTypeID()
            else { return false }
            current = unsafeBitCast(parent, to: AXUIElement.self)
        }
        return false
    }
}

import AppKit
import ApplicationServices
import Foundation

// MARK: - FocusGuard
//
// Per `docs/designs/computer-use.md` §"焦点抑制(FocusGuard)". Orchestrates
// the three layers; every operation that could trigger AppKit / Chromium
// focus reflexes is wrapped in `withFocusSuppressed(pid:element:)`:
//
//   1. AXEnablementAssertion        — cache-aware Chromium AX activation
//   2. SyntheticAppFocusEnforcer    — write/restore AXFocused / AXMain
//   3. SystemFocusStealPreventer    — observer-driven reverse-snatch
//
// The minimized-window guard skips layer 2 entirely: writing AXFocused on
// a minimized Chrome window unconditionally deminiaturizes it. The bare
// AX action still works against a minimized AX tree — the caller just
// doesn't get synthetic-focus reinforcement.

public actor FocusGuard {
    private let enablement: AXEnablementAssertion
    private let enforcer: SyntheticAppFocusEnforcer
    private let systemPreventer: SystemFocusStealPreventer?

    public init(
        enablement: AXEnablementAssertion,
        enforcer: SyntheticAppFocusEnforcer,
        systemPreventer: SystemFocusStealPreventer? = nil
    ) {
        self.enablement = enablement
        self.enforcer = enforcer
        self.systemPreventer = systemPreventer
    }

    /// Run `body` with all three suppression layers active for `pid`. If
    /// `element` is nil only layer 1 (enablement) applies — used for app-
    /// root operations like first-time AX walking.
    ///
    /// `enforcer` state is restored even if `body` throws; the suppression
    /// handle is also released so a thrown error never leaks an observer.
    public func withFocusSuppressed<T: Sendable>(
        pid: pid_t,
        element: AXUIElement?,
        body: @Sendable () async throws -> T
    ) async throws -> T {
        // Layer 1 — enablement (cached no-op for native Cocoa apps).
        let root = AXUIElementCreateApplication(pid)
        _ = await enablement.assert(pid: pid, root: root)

        // Layer 2 — synthetic focus. Walk up to the enclosing window via
        // AXWindow so we can flip its AXFocused / AXMain alongside the
        // element. Skip when minimized — AXFocused on a minimized Chrome
        // window deminiaturizes it.
        let window = element.flatMap { Self.enclosingWindow(of: $0) }
        let windowIsMinimized = window.flatMap { Self.readBool($0, "AXMinimized") } ?? false
        let focusState: FocusState?
        if windowIsMinimized {
            focusState = nil
        } else {
            focusState = await enforcer.preventActivation(
                pid: pid, window: window, element: element
            )
        }

        // Layer 3 — reactive system-level reverse-snatch. Only arm when the
        // target isn't already frontmost (no point suppressing self → self).
        var suppressionHandle: SuppressionHandle?
        if let preventer = systemPreventer {
            let targetApp = NSRunningApplication(processIdentifier: pid)
            let isTargetFrontmost = targetApp?.isActive ?? false
            if !isTargetFrontmost,
               let frontmost = NSWorkspace.shared.frontmostApplication
            {
                suppressionHandle = await preventer.beginSuppression(
                    targetPid: pid, restoreTo: frontmost
                )
            }
        }

        do {
            let result = try await body()
            if let focusState { await enforcer.reenableActivation(focusState) }
            if let handle = suppressionHandle {
                // Tiny grace window so a delayed self-activation we'd miss
                // by ending immediately still gets reversed. Keeps the
                // suppression alive for ~50ms after `body` returns.
                try? await Task.sleep(nanoseconds: 50_000_000)
                await systemPreventer?.endSuppression(handle)
            }
            return result
        } catch {
            if let focusState { await enforcer.reenableActivation(focusState) }
            if let handle = suppressionHandle {
                await systemPreventer?.endSuppression(handle)
            }
            throw error
        }
    }

    // MARK: - Helpers

    private static func readBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let v = value else { return nil }
        if CFGetTypeID(v) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((v as! CFBoolean))
        }
        return nil
    }

    private static func enclosingWindow(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, "AXWindow" as CFString, &value)
        guard result == .success, let raw = value else { return nil }
        guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(raw, to: AXUIElement.self)
    }
}

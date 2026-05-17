import Foundation
import Observation

// MARK: - VisualCapturePolicyStore
//
// Per `docs/designs/os-sense.md` §"ScreenMirror（视觉兜底）" — *when* to
// capture a window snapshot is a Shell-side policy decision, not an OS
// Sense responsibility. OS Sense exposes `captureVisualSnapshot()`; this
// store decides whether to call it.
//
// Semantics: opt-in per `bundleId`. While a bundleId is in `enabled`,
// every submit while that app is frontmost attaches a fresh snapshot.
// Toggle is exposed next to the app chip in the composer.
//
// Lifetime: process-only memory. Per product decision, the toggle is
// remembered for the rest of the Notch Agent session but does NOT persist across
// app launches — UserDefaults would force users to discover and clear
// it later if their preference changed. Keeping it in-memory makes the
// affordance feel like a one-shot per-session preference.

@MainActor
@Observable
public final class VisualCapturePolicyStore {
    private var enabled: Set<String> = []

    public init() {}

    /// True iff `bundleId` is currently set to auto-attach window snapshots.
    public func isAlwaysCapture(bundleId: String) -> Bool {
        enabled.contains(bundleId)
    }

    /// Flip the per-app toggle. Returns the resulting state.
    @discardableResult
    public func toggle(bundleId: String) -> Bool {
        if enabled.contains(bundleId) {
            enabled.remove(bundleId)
            return false
        } else {
            enabled.insert(bundleId)
            return true
        }
    }
}

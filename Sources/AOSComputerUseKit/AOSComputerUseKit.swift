import Foundation

// MARK: - AOSComputerUseKit
//
// Write-side macOS-native operations per `docs/designs/computer-use.md`.
// The Kit's single responsibility is: receive parameters → operate macOS →
// return structured results. It is not aware of JSON-RPC, Bun, or the
// agent loop — the Shell's `ComputerUseHandlers.swift` adapts the public
// `ComputerUseService` API to wire methods.
//
// Module layout (mirrors §"模块结构" in the design):
//
//   Focus/         AXEnablementAssertion · SyntheticAppFocusEnforcer ·
//                  SystemFocusStealPreventer · FocusGuard
//   Input/         SkyLightEventPost · FocusWithoutRaise ·
//                  MouseInput · KeyboardInput · AXInput
//   Capture/       WindowCapture · ScreenInfo
//   Apps/          AppEnumerator
//   Windows/       WindowEnumerator · WindowCoordinateSpace · SpaceDetector
//   AppState/      AccessibilitySnapshot · TreeRenderer · StateCache
//   Permissions/   Permissions
//
// `ComputerUseService` (the public façade) is composed in this file; the
// rest of the module exposes building blocks usable in tests in isolation.

/// Identity-style tag describing the package version. Surfaced through
/// `doctor` so build divergence is visible in the wire response.
public enum AOSComputerUseKit {
    public static let moduleName: String = "AOSComputerUseKit"

    /// Registers `VisualCursorMouseObserver.shared` on `MouseInput` so every
    /// background-pid click / drag / scroll renders a software cursor on
    /// screen. Idempotent. The Shell calls this once at startup, after
    /// `ComputerUseService` is constructed. Set `AOS_VISUAL_CURSOR=0` in
    /// the process environment to disable visualization at runtime; the
    /// observer stays installed but the overlay short-circuits.
    public static func installVisualCursor() {
        MouseInput.observer = VisualCursorMouseObserver.shared
    }
}

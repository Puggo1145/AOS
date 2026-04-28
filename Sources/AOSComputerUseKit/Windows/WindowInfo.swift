import CoreGraphics
import Foundation

// MARK: - WindowInfo
//
// Plain-data record describing a single CGWindow as seen from a CGWindowList
// query. Carried inside the Kit and projected to the wire `WindowInfo`
// schema by the Shell handler. `id` is the `CGWindowID` (the long-lived
// per-window handle assigned by WindowServer); `pid` is the owner.
//
// All fields here are derived directly from `CGWindowListCopyWindowInfo`
// — no AX involvement. That matters because we want `listWindows` to work
// without Accessibility permission so the agent can at least enumerate
// before falling back to vision-only `captureMode`.

public struct WindowBounds: Sendable, Hashable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

public struct WindowInfo: Sendable, Hashable {
    /// CGWindowID — the WindowServer-assigned handle. Stable across the
    /// window's lifetime; suitable as a wire key when paired with `pid`.
    public let id: CGWindowID
    public let pid: pid_t
    public let owner: String
    public let title: String
    public let bounds: WindowBounds
    /// Front-to-back ordering as observed by CGWindowList: larger values
    /// are nearer the user. The Kit picks the maximum-zIndex on-current-Space
    /// window as the "frontmost" anchor (same rule used by `captureWindow`).
    public let zIndex: Int
    public let isOnScreen: Bool
    /// CGWindow layer. `0` is the normal app-window layer; non-zero values
    /// (menu bar items, dock, panels) are filtered out by callers that
    /// want operable target windows.
    public let layer: Int

    public init(
        id: CGWindowID,
        pid: pid_t,
        owner: String,
        title: String,
        bounds: WindowBounds,
        zIndex: Int,
        isOnScreen: Bool,
        layer: Int
    ) {
        self.id = id
        self.pid = pid
        self.owner = owner
        self.title = title
        self.bounds = bounds
        self.zIndex = zIndex
        self.isOnScreen = isOnScreen
        self.layer = layer
    }
}

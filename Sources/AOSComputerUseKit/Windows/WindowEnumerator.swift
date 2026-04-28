import CoreGraphics
import Foundation

// MARK: - WindowEnumerator
//
// Wraps `CGWindowListCopyWindowInfo` into typed `WindowInfo` records. Per
// `docs/designs/computer-use.md` §"Window 选择规则" the Kit's anchor for a
// pid is layer-0 + on-screen + on-current-Space + maximum zIndex; if no
// such window exists we fall back to layer-0 maximum-area (covers
// hidden-launched / fully-minimized cases).
//
// `listWindows` (RPC) returns the layer-0 set; coordinate / capture paths
// use the same selector internally so screenshot anchor and click anchor
// always agree.

public enum WindowEnumerator {

    /// All on-screen windows, including non-app layers (menu bar, etc).
    /// Most callers want `appWindows()` instead.
    public static func visibleWindows() -> [WindowInfo] {
        enumerate(options: [.optionOnScreenOnly, .excludeDesktopElements])
    }

    /// Every window known to WindowServer — including off-screen, minimized,
    /// or on-another-Space windows. Use this to identify a pid's window
    /// regardless of current visibility. Each entry's `isOnScreen` flag
    /// reports current visibility.
    public static func allWindows() -> [WindowInfo] {
        enumerate(options: [.excludeDesktopElements])
    }

    /// Layer-0 (normal app-window) entries for `pid`. The wire
    /// `computerUse.listWindows` result is built from this set.
    public static func appWindows(forPid pid: pid_t) -> [WindowInfo] {
        return allWindows().filter { $0.pid == pid && $0.layer == 0 }
    }

    /// Pick the operable "frontmost" window for `pid` per the design's
    /// selection rule:
    ///
    /// 1. Layer 0, on-screen, on-current-Space, non-degenerate bounds → max
    ///    zIndex wins.
    /// 2. Otherwise: layer 0 max area (covers hidden-launched / all-minimized).
    ///
    /// Returns `nil` if `pid` has no layer-0 window at all.
    public static func selectFrontmostWindow(forPid pid: pid_t) -> WindowInfo? {
        let layerZero = allWindows().filter { $0.pid == pid && $0.layer == 0 }
        let visible = layerZero.filter {
            $0.isOnScreen && $0.bounds.width > 1 && $0.bounds.height > 1
        }
        if let pick = visible.max(by: { $0.zIndex < $1.zIndex }) {
            return pick
        }
        return layerZero.max(by: { areaOf($0.bounds) < areaOf($1.bounds) })
    }

    /// `WindowInfo` for the given `windowId`, or `nil` if no such window
    /// exists. Validates pid ownership at the caller (see `WindowGuard`).
    public static func window(forId windowId: CGWindowID) -> WindowInfo? {
        return allWindows().first(where: { $0.id == windowId })
    }

    // MARK: - Internals

    private static func areaOf(_ bounds: WindowBounds) -> Double {
        return bounds.width * bounds.height
    }

    private static func enumerate(options: CGWindowListOption) -> [WindowInfo] {
        guard
            let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]]
        else {
            return []
        }
        // CGWindowList returns front-to-back; assign zIndex so that larger = frontmost.
        let total = raw.count
        return raw.enumerated().compactMap { (idx, entry) in
            parse(entry, zIndex: total - idx)
        }
    }

    private static func parse(_ entry: [String: Any], zIndex: Int) -> WindowInfo? {
        guard
            let idValue = entry[kCGWindowNumber as String] as? Int,
            let pidValue = entry[kCGWindowOwnerPID as String] as? Int,
            let boundsDict = entry[kCGWindowBounds as String] as? [String: Double]
        else {
            return nil
        }

        let owner = entry[kCGWindowOwnerName as String] as? String ?? ""
        let title = entry[kCGWindowName as String] as? String ?? ""
        let layer = entry[kCGWindowLayer as String] as? Int ?? 0
        let isOnScreen = entry[kCGWindowIsOnscreen as String] as? Bool ?? false

        let bounds = WindowBounds(
            x: boundsDict["X"] ?? 0,
            y: boundsDict["Y"] ?? 0,
            width: boundsDict["Width"] ?? 0,
            height: boundsDict["Height"] ?? 0
        )

        return WindowInfo(
            id: CGWindowID(idValue),
            pid: pid_t(pidValue),
            owner: owner,
            title: title,
            bounds: bounds,
            zIndex: zIndex,
            isOnScreen: isOnScreen,
            layer: layer
        )
    }
}

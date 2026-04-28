import AppKit
import CoreGraphics
import Foundation

// MARK: - ScreenInfo
//
// Backing-scale resolver shared by `WindowCapture` and `WindowCoordinateSpace`.
// Per `docs/designs/computer-use.md` §"截图" the rule is:
//
//   pick the NSScreen with the largest intersection area with the window
//   frame; fall back to NSScreen.main; finally to 1.0
//
// Single source so screenshot bake and coordinate division cancel.

public enum ScreenInfo {
    public static func backingScale(for frame: CGRect) -> CGFloat {
        var best: NSScreen? = nil
        var bestArea: CGFloat = 0
        for screen in NSScreen.screens {
            let intersection = screen.frame.intersection(frame)
            // intersection is .null when no overlap; its width/height are
            // .infinity in that case — guard explicitly so the comparison
            // doesn't get poisoned.
            guard !intersection.isNull else { continue }
            let area = intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                best = screen
            }
        }
        return (best ?? NSScreen.main)?.backingScaleFactor ?? 1.0
    }
}

import AppKit
import CoreGraphics
import Foundation

// MARK: - WindowCoordinateSpace
//
// Per `docs/designs/computer-use.md` §"坐标空间换算":
//
//   external `(x, y)` are window-local screenshot pixels (top-left of the
//   PNG returned by `getAppState`). The Kit converts to global screen
//   points by scaling the pixel coord by
//   `screenshotFrame.size / screenshotPixelSize` and adding the screenshot
//   frame origin.
//
// The reference screenshot's ScreenCaptureKit frame and actual pixel
// dimensions are the source of truth, not the assumed `backingScale ×
// CGWindowList.bounds`. The two diverge as soon as `maxImageDimension`
// downscales the image, CGWindowList reports a shadow-adjusted origin, or
// the screen the window lives on differs from the one we'd guess from
// `NSScreen.main`. When the caller supplies a reference from the latest
// `getAppState` recorded in `StateCache`, use that frame + ratio.
//
// External callers must specify both `pid` and `windowId`; the
// `(pid, windowId)` consistency check in `ComputerUseService` catches
// mismatches before any conversion.

public enum WindowCoordinateSpaceError: Error, CustomStringConvertible, Sendable {
    case windowNotFound(windowId: CGWindowID)
    case windowNotOwnedByPid(windowId: CGWindowID, ownerPid: pid_t, requestedPid: pid_t)

    public var description: String {
        switch self {
        case .windowNotFound(let windowId):
            return "No window with id \(windowId); cannot translate window-local pixel to screen point."
        case .windowNotOwnedByPid(let windowId, let ownerPid, let requestedPid):
            return "Window id \(windowId) belongs to pid \(ownerPid), not pid \(requestedPid)."
        }
    }
}

public struct ScreenshotCoordinateSpace: Sendable, Equatable {
    /// ScreenCaptureKit's frame for the captured window image.
    public let windowFrame: WindowBounds
    /// CGWindowList bounds for the same window at capture time. Kept
    /// separately because CGWindowList can include a stable shadow offset
    /// from ScreenCaptureKit's frame, but it reliably tracks later window
    /// movement for the same `windowId`.
    public let windowBounds: WindowBounds
    public let pixelSize: CGSize

    public init(
        windowFrame: WindowBounds,
        windowBounds: WindowBounds? = nil,
        pixelSize: CGSize
    ) {
        self.windowFrame = windowFrame
        self.windowBounds = windowBounds ?? windowFrame
        self.pixelSize = pixelSize
    }

    /// Returns the captured ScreenCaptureKit frame translated by the
    /// movement observed in the current CGWindowList bounds.
    public func frameTranslatedToCurrentWindowBounds(
        _ currentWindowBounds: WindowBounds
    ) -> WindowBounds {
        WindowBounds(
            x: windowFrame.x + currentWindowBounds.x - windowBounds.x,
            y: windowFrame.y + currentWindowBounds.y - windowBounds.y,
            width: windowFrame.width,
            height: windowFrame.height
        )
    }

    public func hasSameWindowSize(
        as currentWindowBounds: WindowBounds,
        tolerance: Double = 0.5
    ) -> Bool {
        abs(currentWindowBounds.width - windowBounds.width) <= tolerance
            && abs(currentWindowBounds.height - windowBounds.height) <= tolerance
    }
}

public enum WindowCoordinateSpace {
    /// Translate a window-local screenshot pixel (top-left origin) into a
    /// global screen point (CGEvent / AX convention). Validates that the
    /// `windowId` exists and is owned by `pid` — the (pid, windowId) hard
    /// contract from the design.
    ///
    /// `referenceFrame` + `referenceImagePixelSize`: the ScreenCaptureKit
    /// frame and actual pixel dimensions of the screenshot the caller's
    /// coordinate space refers to. When present, conversion uses
    /// `referenceFrame.size / pixelSize` so it survives image downscaling,
    /// shadow-adjusted CGWindow bounds, and bounds-rounding skew.
    public static func screenPoint(
        fromImagePixel imagePixel: CGPoint,
        forPid pid: pid_t,
        windowId: CGWindowID,
        referenceFrame: WindowBounds? = nil,
        referenceImagePixelSize: CGSize? = nil
    ) throws -> CGPoint {
        guard let info = WindowEnumerator.window(forId: windowId) else {
            throw WindowCoordinateSpaceError.windowNotFound(windowId: windowId)
        }
        if info.pid != pid {
            throw WindowCoordinateSpaceError.windowNotOwnedByPid(
                windowId: windowId, ownerPid: info.pid, requestedPid: pid
            )
        }
        return convert(
            imagePixel: imagePixel,
            windowBounds: info.bounds,
            referenceFrame: referenceFrame,
            referencePixelSize: referenceImagePixelSize
        )
    }

    /// Backing scale for the screen the window lives on — picks the screen
    /// with the largest intersection area, falling back to `NSScreen.main`,
    /// finally to 1.0. Same rule as `WindowCapture.scaleFactor(for:)`.
    public static func backingScale(forBounds bounds: WindowBounds) -> CGFloat {
        let frame = bounds.cgRect
        var best: NSScreen? = nil
        var bestArea: CGFloat = 0
        for screen in NSScreen.screens {
            let intersection = screen.frame.intersection(frame)
            guard !intersection.isNull else { continue }
            let area = intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                best = screen
            }
        }
        return (best ?? NSScreen.main)?.backingScaleFactor ?? 1.0
    }

    /// Internal-by-default convert exposed for testing. The public
    /// `screenPoint(...)` wraps this with the window-ownership validation;
    /// the conversion math is pure and worth covering in isolation.
    static func _convertForTesting(
        imagePixel: CGPoint,
        windowBounds: WindowBounds,
        referenceFrame: WindowBounds? = nil,
        referencePixelSize: CGSize?
    ) -> CGPoint {
        convert(
            imagePixel: imagePixel,
            windowBounds: windowBounds,
            referenceFrame: referenceFrame,
            referencePixelSize: referencePixelSize
        )
    }

    private static func convert(
        imagePixel: CGPoint,
        windowBounds: WindowBounds,
        referenceFrame: WindowBounds?,
        referencePixelSize: CGSize?
    ) -> CGPoint {
        if let referencePixelSize,
           referencePixelSize.width > 0,
           referencePixelSize.height > 0,
           (referenceFrame ?? windowBounds).width > 0,
           (referenceFrame ?? windowBounds).height > 0
        {
            // Per-axis ratio derived from the actual screenshot's pixel
            // dimensions. Robust to maxImageDimension downscaling and
            // bounds-rounding skew (playground's approach in
            // `screenshotPixelToWindowPoint`).
            let frame = referenceFrame ?? windowBounds
            let xScale = frame.width / referencePixelSize.width
            let yScale = frame.height / referencePixelSize.height
            return CGPoint(
                x: frame.x + imagePixel.x * xScale,
                y: frame.y + imagePixel.y * yScale
            )
        }
        let scale = backingScale(forBounds: windowBounds)
        return CGPoint(
            x: windowBounds.x + imagePixel.x / scale,
            y: windowBounds.y + imagePixel.y / scale
        )
    }
}

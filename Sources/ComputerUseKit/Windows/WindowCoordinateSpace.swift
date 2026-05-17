import CoreGraphics
import Foundation

// MARK: - ScreenshotCoordinateSpace
//
// Captures the window frame and pixel dimensions that produced a screenshot.
// The remaining Computer Use foundation stores this with snapshot state so
// future operation layers can rebuild coordinate handling explicitly.

public struct ScreenshotCoordinateSpace: Sendable, Equatable {
    public let windowFrame: WindowBounds
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

    public func frameTranslatedToCurrentWindowBounds(
        _ currentWindowBounds: WindowBounds
    ) -> WindowBounds {
        WindowBounds(
            x: currentWindowBounds.x + (windowFrame.x - windowBounds.x),
            y: currentWindowBounds.y + (windowFrame.y - windowBounds.y),
            width: windowFrame.width,
            height: windowFrame.height
        )
    }

    public func hasSameWindowSize(
        as currentWindowBounds: WindowBounds,
        tolerance: Double = 0.5
    ) -> Bool {
        abs(windowBounds.width - currentWindowBounds.width) <= tolerance
            && abs(windowBounds.height - currentWindowBounds.height) <= tolerance
    }
}

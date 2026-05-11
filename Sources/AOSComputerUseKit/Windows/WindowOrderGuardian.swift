import CoreGraphics
import Foundation

/// Repairs the target click side effect where WindowServer raises the target
/// above windows that were visibly covering it.
///
/// The invariant is visual rather than global: every normal on-screen window
/// that overlapped the target and was above it before the click must remain
/// above it after the click settles. Non-overlapping windows, including windows
/// on another display, do not need repair because the target cannot cover them.
struct WindowOrderGuardian: Sendable {
    let targetWindowId: CGWindowID
    private let protectedWindows: [WindowInfo]

    init(targetWindowId: CGWindowID, beforeWindows: [WindowInfo]) throws {
        let orderedWindows = Self.guardableWindows(beforeWindows)
        guard let targetIndex = orderedWindows.firstIndex(where: { $0.id == targetWindowId }) else {
            throw ComputerUseError.clickUnavailable(
                "target window \(targetWindowId) is not visible; cannot guard window order"
            )
        }

        self.targetWindowId = targetWindowId
        let targetWindow = orderedWindows[targetIndex]
        self.protectedWindows = orderedWindows[..<targetIndex].filter { window in
            Self.visuallyCompetes(window, with: targetWindow)
        }
    }

    @discardableResult
    func repair(
        currentWindows: [WindowInfo],
        raiseWindow: @Sendable (WindowInfo) async throws -> Void
    ) async throws -> Bool {
        guard !protectedWindows.isEmpty else {
            return false
        }

        let orderedWindows = Self.guardableWindows(currentWindows)
        guard let targetIndex = orderedWindows.firstIndex(where: { $0.id == targetWindowId }) else {
            throw ComputerUseError.clickUnavailable(
                "target window \(targetWindowId) disappeared during window-order repair"
            )
        }

        let indexByWindowId = Dictionary(
            uniqueKeysWithValues: orderedWindows.enumerated().map { index, window in
                (window.id, index)
            }
        )
        let violatedWindows = protectedWindows.filter { window in
            guard let currentIndex = indexByWindowId[window.id] else {
                return false
            }
            return currentIndex > targetIndex
        }

        for window in violatedWindows.reversed() {
            try await raiseWindow(window)
        }

        return !violatedWindows.isEmpty
    }

    static func guardableWindows(_ windows: [WindowInfo]) -> [WindowInfo] {
        windows.filter { window in
            window.layer == 0
                && window.isOnScreen
                && window.bounds.width >= 64
                && window.bounds.height >= 64
        }
    }

    static func visuallyCompetes(_ window: WindowInfo, with targetWindow: WindowInfo) -> Bool {
        guard window.id != targetWindow.id else {
            return false
        }
        let intersection = window.bounds.cgRect.intersection(targetWindow.bounds.cgRect)
        return !intersection.isNull && intersection.width > 0 && intersection.height > 0
    }
}

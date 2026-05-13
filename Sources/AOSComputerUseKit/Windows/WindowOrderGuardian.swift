import CoreGraphics
import Foundation

/// Detects the target click side effect where WindowServer raises the target
/// above windows that were visibly covering it.
///
/// The invariant is visual: every normal on-screen window that overlapped the
/// target and was above it before the click is treated as protected diagnostic
/// context. The current production guard reports this drift for active-state
/// cleanup, but deliberately does not reorder any windows.
struct WindowOrderGuardian: Sendable {
    let targetWindowId: CGWindowID
    private let protectedWindows: [WindowInfo]

    var observedWindowIds: [CGWindowID] {
        [targetWindowId]
    }

    init(targetWindowId: CGWindowID, beforeWindows: [WindowInfo]) throws {
        let orderedWindows = Self.guardableWindows(beforeWindows)
        guard let targetIndex = orderedWindows.firstIndex(where: { $0.id == targetWindowId }) else {
            throw ComputerUseError.mouseEventUnavailable(
                "target window \(targetWindowId) is not visible; cannot guard window order"
            )
        }

        self.targetWindowId = targetWindowId
        let targetWindow = orderedWindows[targetIndex]
        self.protectedWindows = orderedWindows[..<targetIndex].filter { window in
            Self.visuallyCompetes(window, with: targetWindow)
        }
    }

    func targetCrossedProtectedWindow(currentWindows: [WindowInfo]) throws -> Bool {
        guard !protectedWindows.isEmpty else {
            return false
        }

        return try targetCrossedProtectedWindow(
            targetIndex: targetIndex(in: currentWindows),
            currentWindows: currentWindows
        )
    }

    func protectedCoveredCount(currentWindows: [WindowInfo]) -> Int? {
        guard !protectedWindows.isEmpty else {
            return 0
        }

        let orderedWindows = Self.guardableWindows(currentWindows)
        guard let targetIndex = orderedWindows.firstIndex(where: { $0.id == targetWindowId }) else {
            return nil
        }

        let indexByWindowId = Dictionary(
            uniqueKeysWithValues: orderedWindows.enumerated().map { index, window in
                (window.id, index)
            }
        )
        return protectedWindows.filter { window in
            guard let currentIndex = indexByWindowId[window.id] else {
                return false
            }
            return currentIndex > targetIndex
        }.count
    }

    private func targetIndex(in currentWindows: [WindowInfo]) throws -> Int {
        let orderedWindows = Self.guardableWindows(currentWindows)
        guard let targetIndex = orderedWindows.firstIndex(where: { $0.id == targetWindowId }) else {
            throw ComputerUseError.mouseEventUnavailable(
                "target window \(targetWindowId) disappeared during window-order guard"
            )
        }
        return targetIndex
    }

    private func targetCrossedProtectedWindow(
        targetIndex: Int,
        currentWindows: [WindowInfo]
    ) -> Bool {
        let orderedWindows = Self.guardableWindows(currentWindows)
        let indexByWindowId = Dictionary(
            uniqueKeysWithValues: orderedWindows.enumerated().map { index, window in
                (window.id, index)
            }
        )
        let targetCrossedProtectedWindow = protectedWindows.contains { window in
            guard let currentIndex = indexByWindowId[window.id] else {
                return false
            }
            return currentIndex > targetIndex
        }
        return targetCrossedProtectedWindow
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

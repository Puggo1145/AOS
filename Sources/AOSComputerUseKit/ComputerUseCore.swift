import AppKit
import AOSAXSupport
import CoreGraphics
import Foundation

// MARK: - ComputerUseCore
//
// Public façade for the Computer Use foundation: app/window enumeration,
// AX snapshot rendering, screenshot capture, non-raising focus, and snapshot
// cache ownership. App operation layers were removed so this actor has no
// ability to click, type, drag, or scroll.

public struct AppStateBundle: Sendable {
    public let stateId: StateID
    public let treeMarkdown: String
    public let elementCount: Int
    public let screenshot: Screenshot?
    public let bundleId: String?
    public let appName: String?

    public init(
        stateId: StateID,
        treeMarkdown: String,
        elementCount: Int,
        screenshot: Screenshot?,
        bundleId: String?,
        appName: String?
    ) {
        self.stateId = stateId
        self.treeMarkdown = treeMarkdown
        self.elementCount = elementCount
        self.screenshot = screenshot
        self.bundleId = bundleId
        self.appName = appName
    }
}

/// Result of focusing a WindowServer window without changing its z-order.
public struct WindowFocusResult: Sendable, Equatable {
    public let pid: pid_t
    public let windowId: CGWindowID

    public init(pid: pid_t, windowId: CGWindowID) {
        self.pid = pid
        self.windowId = windowId
    }
}

/// Result of posting a coordinate-based left click to a WindowServer window.
public struct WindowClickResult: Sendable, Equatable {
    public let pid: pid_t
    public let windowId: CGWindowID
    public let point: CGPoint

    public init(pid: pid_t, windowId: CGWindowID, point: CGPoint) {
        self.pid = pid
        self.windowId = windowId
        self.point = point
    }
}

public enum CaptureMode: String, Sendable, Equatable {
    case vision
    case ax
}

public enum ComputerUseError: Error, CustomStringConvertible, Sendable {
    case windowMismatch(pid: pid_t, windowId: CGWindowID, ownerPid: pid_t?)
    case captureUnavailable(String)
    case focusUnavailable(String)
    case clickUnavailable(String)
    case payloadTooLarge(bytes: Int, limit: Int)
    case windowNotFound(windowId: CGWindowID)

    public var description: String {
        switch self {
        case .windowMismatch(let pid, let windowId, let ownerPid):
            var detail = "windowId \(windowId) is not owned by pid \(pid)"
            if let ownerPid {
                detail += " (actual owner: \(ownerPid))"
            }
            return detail
        case .captureUnavailable(let message):
            return "capture unavailable: \(message)"
        case .focusUnavailable(let message):
            return "focus unavailable: \(message)"
        case .clickUnavailable(let message):
            return "click unavailable: \(message)"
        case .payloadTooLarge(let bytes, let limit):
            return "screenshot payload \(bytes) bytes exceeds raw limit \(limit) bytes after downscale retries"
        case .windowNotFound(let windowId):
            return "no window with id \(windowId)"
        }
    }
}

public actor ComputerUseCore {
    private let webAccessibilityActivator: AXWebAccessibilityActivator
    private let snapshot: AccessibilitySnapshot
    private let cache: StateCache
    private let capture: WindowCapture
    private let windowLookup: @Sendable (CGWindowID) -> WindowInfo?
    private let visibleWindowsLookup: @Sendable () -> [WindowInfo]
    private let frontmostWindowLookup: @Sendable () -> WindowInfo?
    private let focusWindowWithoutRaising: @Sendable (pid_t, CGWindowID) async throws -> Void
    private let deactivateWindowWithoutRaising: @Sendable (pid_t, CGWindowID) async throws -> Void
    private let raiseWindowWithoutActivating: @Sendable (WindowInfo) async throws -> Void
    private let orderRepairDelays: [UInt64]
    private let sleepForOrderRepair: @Sendable (UInt64) async throws -> Void
    private let postLeftClickEvent: @Sendable (
        pid_t,
        CGWindowID,
        CGPoint,
        WindowBounds,
        MouseClickPostObserver?
    ) async throws -> Void

    public init() {
        let webAccessibilityActivator = AXWebAccessibilityActivator()
        let windowFocuser = SkyLightWindowFocuser.live()
        let mousePoster = MouseEventPoster.live()
        let windowRaiser = AXWindowRaiser.live()
        self.init(
            webAccessibilityActivator: webAccessibilityActivator,
            snapshot: AccessibilitySnapshot(webAccessibilityActivator: webAccessibilityActivator),
            cache: StateCache(ttlSeconds: 30),
            capture: WindowCapture(),
            windowLookup: { windowId in
                WindowEnumerator.window(forId: windowId)
            },
            visibleWindowsLookup: {
                WindowEnumerator.visibleWindows()
            },
            frontmostWindowLookup: {
                Self.currentFrontmostLayerZeroWindow()
            },
            focusWindowWithoutRaising: { pid, windowId in
                try windowFocuser.focusWindowWithoutRaising(pid: pid, windowId: windowId)
            },
            deactivateWindowWithoutRaising: { pid, windowId in
                try windowFocuser.deactivateWindowWithoutRaising(pid: pid, windowId: windowId)
            },
            raiseWindowWithoutActivating: { window in
                try windowRaiser.raise(window)
            },
            orderRepairDelays: Self.liveOrderRepairDelays,
            sleepForOrderRepair: { delay in
                try await Task.sleep(nanoseconds: delay)
            },
            postLeftClick: { pid, windowId, point, windowBounds, stageObserver in
                try await mousePoster.postLeftClick(
                    pid: pid,
                    windowId: windowId,
                    point: point,
                    windowBounds: windowBounds,
                    stageObserver: stageObserver
                )
            }
        )
    }

    init(
        webAccessibilityActivator: AXWebAccessibilityActivator = AXWebAccessibilityActivator(),
        snapshot: AccessibilitySnapshot? = nil,
        cache: StateCache = StateCache(ttlSeconds: 30),
        capture: WindowCapture = WindowCapture(),
        windowLookup: @escaping @Sendable (CGWindowID) -> WindowInfo?,
        visibleWindowsLookup: @escaping @Sendable () -> [WindowInfo] = { [] },
        frontmostWindowLookup: @escaping @Sendable () -> WindowInfo? = { nil },
        focusWindowWithoutRaising: @escaping @Sendable (pid_t, CGWindowID) async throws -> Void,
        deactivateWindowWithoutRaising: @escaping @Sendable (pid_t, CGWindowID) async throws -> Void,
        raiseWindowWithoutActivating: @escaping @Sendable (WindowInfo) async throws -> Void = { _ in },
        orderRepairDelays: [UInt64] = [],
        sleepForOrderRepair: @escaping @Sendable (UInt64) async throws -> Void = { _ in },
        postLeftClick: @escaping @Sendable (
            pid_t,
            CGWindowID,
            CGPoint,
            WindowBounds,
            MouseClickPostObserver?
        ) async throws -> Void = { _, _, _, _, _ in
            throw ComputerUseError.clickUnavailable("mouse event poster is not configured")
        }
    ) {
        let snapshot = snapshot ?? AccessibilitySnapshot(webAccessibilityActivator: webAccessibilityActivator)
        self.webAccessibilityActivator = webAccessibilityActivator
        self.snapshot = snapshot
        self.cache = cache
        self.capture = capture
        self.windowLookup = windowLookup
        self.visibleWindowsLookup = visibleWindowsLookup
        self.frontmostWindowLookup = frontmostWindowLookup
        self.focusWindowWithoutRaising = focusWindowWithoutRaising
        self.deactivateWindowWithoutRaising = deactivateWindowWithoutRaising
        self.raiseWindowWithoutActivating = raiseWindowWithoutActivating
        self.orderRepairDelays = orderRepairDelays
        self.sleepForOrderRepair = sleepForOrderRepair
        self.postLeftClickEvent = postLeftClick
    }

    public func listApps(mode: AppListMode) -> [AppInfo] {
        AppEnumerator.apps(mode: mode)
    }

    public func listWindows(pid: pid_t) -> [WindowInfo] {
        WindowEnumerator.appWindows(forPid: pid)
    }

    public func getAppState(
        pid: pid_t,
        windowId: CGWindowID,
        captureMode: CaptureMode = .vision,
        maxImageDimension: Int = 0
    ) async throws -> AppStateBundle {
        try validateOwnership(pid: pid, windowId: windowId)

        let app = NSRunningApplication(processIdentifier: pid)
        let bundleId = app?.bundleIdentifier
        let appName = app?.localizedName

        let result = try await snapshot.walk(pid: pid, windowId: windowId)
        let stateId = await cache.store(pid: pid, windowId: windowId, elements: result.elements)

        var shot: Screenshot?
        if captureMode == .vision {
            shot = try await captureWithPayloadCap(
                windowId: windowId,
                initialMaxImageDimension: maxImageDimension
            )
        }

        if let shot {
            await cache.recordScreenshot(
                pid: pid,
                windowId: windowId,
                coordinateSpace: shot.coordinateSpace
            )
        }

        return AppStateBundle(
            stateId: stateId,
            treeMarkdown: result.treeMarkdown,
            elementCount: result.elements.count,
            screenshot: shot,
            bundleId: bundleId,
            appName: appName
        )
    }

    /// Focuses `windowId` for `pid` without raising or reordering the window.
    public func focusWindowWithoutRaise(
        pid: pid_t,
        windowId: CGWindowID
    ) async throws -> WindowFocusResult {
        try validateOwnership(pid: pid, windowId: windowId)
        try await focusWindowWithoutRaising(pid, windowId)
        return WindowFocusResult(pid: pid, windowId: windowId)
    }

    /// Posts a background left-click to an explicit screen-space point inside
    /// `windowId`, using the standard non-raising focus and order-guardian path.
    public func postLeftClick(
        pid: pid_t,
        windowId: CGWindowID,
        point: CGPoint
    ) async throws -> WindowClickResult {
        let window = try validateOwnership(pid: pid, windowId: windowId)
        guard window.bounds.cgRect.contains(point) else {
            throw ComputerUseError.clickUnavailable(
                "point \(Int(point.x)),\(Int(point.y)) is outside window \(windowId)"
            )
        }
        let originalFrontWindow = frontmostWindowLookup()
        let orderGuardian = try makeWindowOrderGuardian(targetWindowId: windowId)
        try await focusWindowWithoutRaising(pid, windowId)
        try await Task.sleep(nanoseconds: 5_000_000)
        try await postLeftClickEvent(pid, windowId, point, window.bounds) { [self] _ in
            try await self.repairWindowOrderOnce(
                orderGuardian,
                originalFrontWindow: originalFrontWindow,
                targetWindowId: windowId
            )
        }
        try await restoreOriginalFrontWindow(originalFrontWindow, targetWindowId: windowId)
        try await repairWindowOrder(
            orderGuardian,
            originalFrontWindow: originalFrontWindow,
            targetWindowId: windowId
        )
        try await deactivateTargetWindowIfNeeded(
            pid: pid,
            windowId: windowId,
            originalFrontWindow: originalFrontWindow
        )
        return WindowClickResult(pid: pid, windowId: windowId, point: point)
    }

    @discardableResult
    private func validateOwnership(pid: pid_t, windowId: CGWindowID) throws -> WindowInfo {
        guard let info = windowLookup(windowId) else {
            throw ComputerUseError.windowNotFound(windowId: windowId)
        }
        if info.pid != pid {
            throw ComputerUseError.windowMismatch(pid: pid, windowId: windowId, ownerPid: info.pid)
        }
        return info
    }

    private func restoreOriginalFrontWindow(
        _ originalFrontWindow: WindowInfo?,
        targetWindowId: CGWindowID
    ) async throws {
        guard let originalFrontWindow, originalFrontWindow.id != targetWindowId else {
            return
        }
        try await focusWindowWithoutRaising(originalFrontWindow.pid, originalFrontWindow.id)
    }

    private func deactivateTargetWindowIfNeeded(
        pid: pid_t,
        windowId: CGWindowID,
        originalFrontWindow: WindowInfo?
    ) async throws {
        guard originalFrontWindow?.id != windowId else {
            return
        }
        try await deactivateWindowWithoutRaising(pid, windowId)
    }

    private func makeWindowOrderGuardian(targetWindowId: CGWindowID) throws -> WindowOrderGuardian? {
        guard !orderRepairDelays.isEmpty else {
            return nil
        }
        return try WindowOrderGuardian(
            targetWindowId: targetWindowId,
            beforeWindows: visibleWindowsLookup()
        )
    }

    private func repairWindowOrder(
        _ orderGuardian: WindowOrderGuardian?,
        originalFrontWindow: WindowInfo?,
        targetWindowId: CGWindowID
    ) async throws {
        for delay in orderRepairDelays {
            if delay > 0 {
                try await sleepForOrderRepair(delay)
            }
            try await repairWindowOrderOnce(
                orderGuardian,
                originalFrontWindow: originalFrontWindow,
                targetWindowId: targetWindowId
            )
        }
    }

    private func repairWindowOrderDuring(
        _ duration: UInt64,
        _ orderGuardian: WindowOrderGuardian?,
        originalFrontWindow: WindowInfo?,
        targetWindowId: CGWindowID
    ) async throws {
        var elapsed: UInt64 = 0
        while elapsed < duration {
            let delay = min(Self.liveOrderRepairInterval, duration - elapsed)
            try await sleepForOrderRepair(delay)
            elapsed += delay
            try await repairWindowOrderOnce(
                orderGuardian,
                originalFrontWindow: originalFrontWindow,
                targetWindowId: targetWindowId
            )
        }
    }

    @discardableResult
    private func repairWindowOrderOnce(
        _ orderGuardian: WindowOrderGuardian?,
        originalFrontWindow: WindowInfo?,
        targetWindowId: CGWindowID
    ) async throws -> Bool {
        guard let orderGuardian else {
            return false
        }
        let repaired = try await orderGuardian.repair(currentWindows: visibleWindowsLookup()) { window in
            try await raiseWindowWithoutActivating(window)
        }
        if repaired {
            try await restoreOriginalFrontWindow(originalFrontWindow, targetWindowId: targetWindowId)
        }
        return repaired
    }

    private func captureWithPayloadCap(
        windowId: CGWindowID,
        initialMaxImageDimension: Int
    ) async throws -> Screenshot {
        try await Self.capturePayloadLoop(initialMaxImageDimension: initialMaxImageDimension) { [capture] dim in
            do {
                return try await capture.captureWindow(
                    windowID: windowId,
                    format: .png,
                    quality: 95,
                    maxImageDimension: dim
                )
            } catch let err as CaptureError {
                throw ComputerUseError.captureUnavailable(err.description)
            }
        }
    }

    static func capturePayloadLoop(
        initialMaxImageDimension: Int,
        maxAttempts: Int = 8,
        capture: (Int) async throws -> Screenshot
    ) async throws -> Screenshot {
        var maxDim = initialMaxImageDimension
        var lastBytes = 0
        for _ in 0..<maxAttempts {
            let shot = try await capture(maxDim)
            lastBytes = shot.imageData.count
            let currentDim = maxDim > 0 ? maxDim : max(shot.width, shot.height)
            guard let next = ScreenshotPayloadPolicy.nextMaxDim(
                currentBytes: lastBytes,
                currentMaxDim: currentDim
            ) else {
                return shot
            }
            if next == 0 { break }
            maxDim = next
        }
        throw ComputerUseError.payloadTooLarge(
            bytes: lastBytes,
            limit: ScreenshotPayloadPolicy.defaultRawByteBudget
        )
    }
}

private extension ComputerUseCore {
    static let liveOrderRepairInterval: UInt64 = 5_000_000
    static let liveOrderRepairWindow: UInt64 = 300_000_000

    static let liveOrderRepairDelays: [UInt64] = [
        0,
    ] + Array(
        repeating: liveOrderRepairInterval,
        count: Int(liveOrderRepairWindow / liveOrderRepairInterval)
    )

    static func currentFrontmostLayerZeroWindow() -> WindowInfo? {
        guard let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return nil
        }
        return WindowEnumerator.visibleWindows().first { window in
            window.pid == frontmostPID
                && window.layer == 0
                && window.bounds.width >= 64
                && window.bounds.height >= 64
        }
    }
}

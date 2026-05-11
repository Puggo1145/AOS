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

public enum WindowClickTraceStage: String, Sendable, Equatable {
    case before
    case afterFocus
    case afterMouseMoved
    case afterPrimerDown
    case afterPrimerUp
    case afterTargetDown
    case afterTargetUp
    case afterFocusRestore
    case afterTargetUp250ms
    case afterTargetUp1s
    case afterTargetUp3s
    case afterTargetUp10s
}

public struct WindowOrderEntry: Sendable, Equatable {
    public let rank: Int
    public let windowId: CGWindowID
    public let pid: pid_t
    public let owner: String
    public let title: String
    public let bounds: WindowBounds
    public let zIndex: Int

    public init(rank: Int, window: WindowInfo) {
        self.rank = rank
        self.windowId = window.id
        self.pid = window.pid
        self.owner = window.owner
        self.title = window.title
        self.bounds = window.bounds
        self.zIndex = window.zIndex
    }
}

public struct WindowOrderSnapshot: Sendable, Equatable {
    public let stage: WindowClickTraceStage
    public let frontmostPid: pid_t?
    public let frontmostBundleId: String?
    public let frontmostName: String?
    public let targetRank: Int?
    public let targetZIndex: Int?
    public let windowsAboveTarget: Int?
    public let overlappingWindowsAboveTarget: Int?
    public let protectedOverlappingWindowsCoveredByTarget: Int?
    public let topWindows: [WindowOrderEntry]

    public init(
        stage: WindowClickTraceStage,
        frontmostPid: pid_t?,
        frontmostBundleId: String?,
        frontmostName: String?,
        targetRank: Int?,
        targetZIndex: Int?,
        windowsAboveTarget: Int?,
        overlappingWindowsAboveTarget: Int?,
        protectedOverlappingWindowsCoveredByTarget: Int?,
        topWindows: [WindowOrderEntry]
    ) {
        self.stage = stage
        self.frontmostPid = frontmostPid
        self.frontmostBundleId = frontmostBundleId
        self.frontmostName = frontmostName
        self.targetRank = targetRank
        self.targetZIndex = targetZIndex
        self.windowsAboveTarget = windowsAboveTarget
        self.overlappingWindowsAboveTarget = overlappingWindowsAboveTarget
        self.protectedOverlappingWindowsCoveredByTarget = protectedOverlappingWindowsCoveredByTarget
        self.topWindows = topWindows
    }
}

public struct WindowClickTraceResult: Sendable, Equatable {
    public let pid: pid_t
    public let windowId: CGWindowID
    public let point: CGPoint
    public let samples: [WindowOrderSnapshot]

    public init(
        pid: pid_t,
        windowId: CGWindowID,
        point: CGPoint,
        samples: [WindowOrderSnapshot]
    ) {
        self.pid = pid
        self.windowId = windowId
        self.point = point
        self.samples = samples
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
    private let prepareWindowForMouseClick: @Sendable (pid_t, CGWindowID) async throws -> Void
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
        let mouseClickFocuser = SkyLightMouseClickFocuser.live()
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
            prepareWindowForMouseClick: { pid, windowId in
                try mouseClickFocuser.prepareForMouseClick(pid: pid, windowId: windowId)
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
        prepareWindowForMouseClick: @escaping @Sendable (pid_t, CGWindowID) async throws -> Void = { _, _ in
            throw ComputerUseError.clickUnavailable("mouse click focus preparer is not configured")
        },
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
        self.prepareWindowForMouseClick = prepareWindowForMouseClick
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

    /// Posts a background left-click to the current center of `windowId`
    /// after first preparing that window for pid-routed input.
    public func postLeftClick(
        pid: pid_t,
        windowId: CGWindowID
    ) async throws -> WindowClickResult {
        let window = try validateOwnership(pid: pid, windowId: windowId)
        let point = CGPoint(
            x: window.bounds.x + window.bounds.width / 2,
            y: window.bounds.y + window.bounds.height / 2
        )
        return try await postLeftClick(pid: pid, windowId: windowId, point: point)
    }

    /// Posts a background left-click to an explicit screen-space point inside
    /// `windowId`, using the same non-raising focus and order-guardian path as
    /// the center-click helper.
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
        try await prepareWindowForMouseClick(pid, windowId)
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
        return WindowClickResult(pid: pid, windowId: windowId, point: point)
    }

    /// Runs the same click path as `postLeftClick`, recording WindowServer
    /// front-to-back order after every dispatch phase. This is a diagnostic
    /// hook for proving no-raise behavior against the live compositor.
    public func tracePostLeftClick(
        pid: pid_t,
        windowId: CGWindowID,
        skipFocus: Bool = false,
        overridePoint: CGPoint? = nil
    ) async throws -> WindowClickTraceResult {
        let window = try validateOwnership(pid: pid, windowId: windowId)
        let point = overridePoint ?? CGPoint(
            x: window.bounds.x + window.bounds.width / 2,
            y: window.bounds.y + window.bounds.height / 2
        )
        let recorder = WindowClickTraceRecorder(targetWindowId: windowId)
        let originalFrontWindow = frontmostWindowLookup()
        let orderGuardian = try makeWindowOrderGuardian(targetWindowId: windowId)

        recorder.record(.before)
        if !skipFocus {
            try await prepareWindowForMouseClick(pid, windowId)
        }
        recorder.record(.afterFocus)
        try await Task.sleep(nanoseconds: 5_000_000)
        try await postLeftClickEvent(pid, windowId, point, window.bounds) { postStage in
            recorder.record(WindowClickTraceStage(postStage))
        }
        try await restoreOriginalFrontWindow(originalFrontWindow, targetWindowId: windowId)
        try await repairWindowOrderOnce(
            orderGuardian,
            originalFrontWindow: originalFrontWindow,
            targetWindowId: windowId
        )
        recorder.record(.afterFocusRestore)
        try await repairWindowOrderDuring(
            250_000_000,
            orderGuardian,
            originalFrontWindow: originalFrontWindow,
            targetWindowId: windowId
        )
        recorder.record(.afterTargetUp250ms)
        try await repairWindowOrderDuring(
            750_000_000,
            orderGuardian,
            originalFrontWindow: originalFrontWindow,
            targetWindowId: windowId
        )
        recorder.record(.afterTargetUp1s)
        try await repairWindowOrderDuring(
            2_000_000_000,
            orderGuardian,
            originalFrontWindow: originalFrontWindow,
            targetWindowId: windowId
        )
        recorder.record(.afterTargetUp3s)
        try await Task.sleep(nanoseconds: 7_000_000_000)
        try await repairWindowOrderOnce(
            orderGuardian,
            originalFrontWindow: originalFrontWindow,
            targetWindowId: windowId
        )
        recorder.record(.afterTargetUp10s)

        return WindowClickTraceResult(
            pid: pid,
            windowId: windowId,
            point: point,
            samples: recorder.snapshots
        )
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

private extension WindowClickTraceStage {
    init(_ postStage: MouseClickPostStage) {
        switch postStage {
        case .afterMouseMoved:
            self = .afterMouseMoved
        case .afterTargetDown:
            self = .afterTargetDown
        case .afterTargetUp:
            self = .afterTargetUp
        }
    }
}

private final class WindowClickTraceRecorder: @unchecked Sendable {
    private let targetWindowId: CGWindowID
    private let lock = NSLock()
    private var recordedSnapshots: [WindowOrderSnapshot] = []
    private var protectedOverlappingWindowIds: Set<CGWindowID>?

    init(targetWindowId: CGWindowID) {
        self.targetWindowId = targetWindowId
    }

    var snapshots: [WindowOrderSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return recordedSnapshots
    }

    func record(_ stage: WindowClickTraceStage) {
        let snapshot = capture(stage: stage)
        lock.lock()
        recordedSnapshots.append(snapshot)
        lock.unlock()
    }

    private func capture(stage: WindowClickTraceStage) -> WindowOrderSnapshot {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let orderedWindows = WindowEnumerator.visibleWindows()
            .filter { window in
                window.layer == 0
                    && window.bounds.width >= 64
                    && window.bounds.height >= 64
            }
        let targetIndex = orderedWindows.firstIndex(where: { $0.id == targetWindowId })
        let targetWindow = targetIndex.map { orderedWindows[$0] }
        let overlappingWindowIndexes = Self.overlappingWindowIndexes(
            orderedWindows: orderedWindows,
            targetIndex: targetIndex,
            targetWindow: targetWindow
        )
        let overlappingWindowsAboveTarget = targetIndex.map { targetIndex in
            overlappingWindowIndexes.filter { $0 < targetIndex }.count
        }
        let protectedCoveredCount = protectedCoveredOverlaps(
            stage: stage,
            orderedWindows: orderedWindows,
            targetIndex: targetIndex,
            overlappingWindowIndexes: overlappingWindowIndexes
        )
        let topWindows = orderedWindows.prefix(12).enumerated().map { index, window in
            WindowOrderEntry(rank: index + 1, window: window)
        }

        return WindowOrderSnapshot(
            stage: stage,
            frontmostPid: frontmost.map(\.processIdentifier),
            frontmostBundleId: frontmost?.bundleIdentifier,
            frontmostName: frontmost?.localizedName,
            targetRank: targetIndex.map { $0 + 1 },
            targetZIndex: targetWindow?.zIndex,
            windowsAboveTarget: targetIndex,
            overlappingWindowsAboveTarget: overlappingWindowsAboveTarget,
            protectedOverlappingWindowsCoveredByTarget: protectedCoveredCount,
            topWindows: topWindows
        )
    }

    private func protectedCoveredOverlaps(
        stage: WindowClickTraceStage,
        orderedWindows: [WindowInfo],
        targetIndex: Int?,
        overlappingWindowIndexes: [Int]
    ) -> Int? {
        guard let targetIndex else {
            return nil
        }

        lock.lock()
        if protectedOverlappingWindowIds == nil, stage == .before {
            protectedOverlappingWindowIds = Set(
                overlappingWindowIndexes
                    .filter { $0 < targetIndex }
                    .map { orderedWindows[$0].id }
            )
        }
        let protectedIds = protectedOverlappingWindowIds
        lock.unlock()

        guard let protectedIds else {
            return nil
        }
        return orderedWindows.enumerated().filter { index, window in
            protectedIds.contains(window.id) && index > targetIndex
        }.count
    }

    private static func overlappingWindowIndexes(
        orderedWindows: [WindowInfo],
        targetIndex: Int?,
        targetWindow: WindowInfo?
    ) -> [Int] {
        guard let targetIndex, let targetWindow else {
            return []
        }
        return orderedWindows.enumerated().compactMap { index, window in
            guard index != targetIndex,
                  WindowOrderGuardian.visuallyCompetes(window, with: targetWindow) else {
                return nil
            }
            return index
        }
    }
}

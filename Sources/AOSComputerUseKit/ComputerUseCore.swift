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

public enum WindowClickTraceStage: String, Sendable, Codable, Equatable {
    case before
    case afterFocus
    case afterMouseMoved
    case afterPrimerDown
    case afterPrimerUp
    case afterPrimerGap
    case afterTargetDown
    case afterTargetUp
    case afterRestoreOriginalFrontWindow
    case afterTargetDeactivate
    case activeStateGuardTick
    case afterActiveStateGuard
    case afterTraceSettle50ms
    case afterTraceSettle200ms
    case afterTraceSettle1s
}

public struct WindowClickTraceSnapshot: Sendable, Codable, Equatable {
    public let stage: WindowClickTraceStage
    public let frontmostPID: pid_t?
    public let frontmostBundleIdentifier: String?
    public let frontmostWindowId: CGWindowID?
    public let targetIsActive: Bool
    public let targetRank: Int?
    public let protectedCoveredCount: Int?
    public let elapsedNanoseconds: UInt64?
    public let guardAttempt: Int?
    public let corrected: Bool?

    public init(
        stage: WindowClickTraceStage,
        frontmostPID: pid_t?,
        frontmostBundleIdentifier: String?,
        frontmostWindowId: CGWindowID?,
        targetIsActive: Bool,
        targetRank: Int?,
        protectedCoveredCount: Int?,
        elapsedNanoseconds: UInt64? = nil,
        guardAttempt: Int? = nil,
        corrected: Bool? = nil
    ) {
        self.stage = stage
        self.frontmostPID = frontmostPID
        self.frontmostBundleIdentifier = frontmostBundleIdentifier
        self.frontmostWindowId = frontmostWindowId
        self.targetIsActive = targetIsActive
        self.targetRank = targetRank
        self.protectedCoveredCount = protectedCoveredCount
        self.elapsedNanoseconds = elapsedNanoseconds
        self.guardAttempt = guardAttempt
        self.corrected = corrected
    }
}

public struct WindowClickTraceResult: Sendable, Equatable {
    public let result: WindowClickResult
    public let snapshots: [WindowClickTraceSnapshot]

    public init(result: WindowClickResult, snapshots: [WindowClickTraceSnapshot]) {
        self.result = result
        self.snapshots = snapshots
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
    private let requiresPreClickFocus: @Sendable (pid_t) -> Bool
    private let focusWindowWithoutRaising: @Sendable (pid_t, CGWindowID) async throws -> Void
    private let deactivateWindowWithoutRaising: @Sendable (pid_t, CGWindowID) async throws -> Void
    private let activateApplication: @Sendable (pid_t) async -> Bool
    private let isApplicationActive: @Sendable (pid_t) async -> Bool
    private let windowOrderChangeObserver: WindowOrderChangeObserver?
    private let activeStateGuardDelays: [UInt64]
    private let sleepForActiveStateGuard: @Sendable (UInt64) async throws -> Void
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
        let mouseDeliveryClassifier = MouseClickDeliveryClassifier()
        let deliveryRouteForPID: @Sendable (pid_t) -> MouseClickDeliveryRoute = { pid in
            let app = NSRunningApplication(processIdentifier: pid)
            return mouseDeliveryClassifier.deliveryRoute(
                bundleIdentifier: app?.bundleIdentifier,
                bundleURL: app?.bundleURL
            )
        }
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
            requiresPreClickFocus: { pid in
                deliveryRouteForPID(pid).requiresPreClickFocus
            },
            focusWindowWithoutRaising: { pid, windowId in
                try windowFocuser.focusWindowWithoutRaising(pid: pid, windowId: windowId)
            },
            deactivateWindowWithoutRaising: { pid, windowId in
                try windowFocuser.deactivateWindowWithoutRaising(pid: pid, windowId: windowId)
            },
            activateApplication: { pid in
                await MainActor.run {
                    NSRunningApplication(processIdentifier: pid)?.activate(options: []) ?? false
                }
            },
            isApplicationActive: { pid in
                await MainActor.run {
                    NSRunningApplication(processIdentifier: pid)?.isActive ?? false
                }
            },
            windowOrderChangeObserver: .live(),
            activeStateGuardDelays: Self.liveActiveStateGuardDelays,
            sleepForActiveStateGuard: { delay in
                try await Task.sleep(nanoseconds: delay)
            },
            postLeftClick: { pid, windowId, point, windowBounds, stageObserver in
                try await mousePoster.postLeftClick(
                    pid: pid,
                    windowId: windowId,
                    point: point,
                    windowBounds: windowBounds,
                    deliveryRoute: deliveryRouteForPID(pid),
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
        requiresPreClickFocus: @escaping @Sendable (pid_t) -> Bool = { _ in true },
        focusWindowWithoutRaising: @escaping @Sendable (pid_t, CGWindowID) async throws -> Void,
        deactivateWindowWithoutRaising: @escaping @Sendable (pid_t, CGWindowID) async throws -> Void,
        activateApplication: @escaping @Sendable (pid_t) async -> Bool = { _ in false },
        isApplicationActive: @escaping @Sendable (pid_t) async -> Bool = { _ in false },
        windowOrderChangeObserver: WindowOrderChangeObserver? = nil,
        activeStateGuardDelays: [UInt64] = [],
        sleepForActiveStateGuard: @escaping @Sendable (UInt64) async throws -> Void = { _ in },
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
        self.requiresPreClickFocus = requiresPreClickFocus
        self.focusWindowWithoutRaising = focusWindowWithoutRaising
        self.deactivateWindowWithoutRaising = deactivateWindowWithoutRaising
        self.activateApplication = activateApplication
        self.isApplicationActive = isApplicationActive
        self.windowOrderChangeObserver = windowOrderChangeObserver
        self.activeStateGuardDelays = activeStateGuardDelays
        self.sleepForActiveStateGuard = sleepForActiveStateGuard
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
        try await performPostLeftClick(pid: pid, windowId: windowId, point: point, tracing: false).result
    }

    /// Posts a background left-click and returns per-stage WindowServer state
    /// for diagnosing browser/Web-content activation and ordering side effects.
    public func postLeftClickTrace(
        pid: pid_t,
        windowId: CGWindowID,
        point: CGPoint
    ) async throws -> WindowClickTraceResult {
        try await performPostLeftClick(
            pid: pid,
            windowId: windowId,
            point: point,
            tracing: true
        )
    }

    private func performPostLeftClick(
        pid: pid_t,
        windowId: CGWindowID,
        point: CGPoint,
        tracing: Bool
    ) async throws -> WindowClickTraceResult {
        let window = try validateOwnership(pid: pid, windowId: windowId)
        guard window.bounds.cgRect.contains(point) else {
            throw ComputerUseError.clickUnavailable(
                "point \(Int(point.x)),\(Int(point.y)) is outside window \(windowId)"
            )
        }
        let originalFrontWindow = frontmostWindowLookup()
        let orderGuardian = try makeWindowOrderGuardian(targetWindowId: windowId)
        let traceRecorder = tracing ? WindowClickTraceRecorder() : nil
        let orderChangeObservation = try await startWindowOrderChangeGuard(
            orderGuardian,
            originalFrontWindow: originalFrontWindow,
            targetWindowId: windowId,
            targetPID: pid
        )

        do {
            await recordTraceStage(
                .before,
                recorder: traceRecorder,
                targetPID: pid,
                targetWindowId: windowId,
                orderGuardian: orderGuardian
            )
            if requiresPreClickFocus(pid) {
                try await focusWindowWithoutRaising(pid, windowId)
                try await Task.sleep(nanoseconds: 5_000_000)
                await recordTraceStage(
                    .afterFocus,
                    recorder: traceRecorder,
                    targetPID: pid,
                    targetWindowId: windowId,
                    orderGuardian: orderGuardian
                )
            }
            try await postLeftClickEvent(pid, windowId, point, window.bounds) { [self] stage in
                if stage.runsActiveStateGuard {
                    try await self.runActiveStateGuardOnce(
                        orderGuardian,
                        originalFrontWindow: originalFrontWindow,
                        targetWindowId: windowId
                    )
                }
                await self.recordTraceStage(
                    WindowClickTraceStage(stage),
                    recorder: traceRecorder,
                    targetPID: pid,
                    targetWindowId: windowId,
                    orderGuardian: orderGuardian
                )
            }
            try await runPostDispatchCleanup(
                pid: pid,
                windowId: windowId,
                originalFrontWindow: originalFrontWindow,
                orderGuardian: orderGuardian,
                traceRecorder: traceRecorder
            )
            try await runActiveStateGuard(
                orderGuardian,
                originalFrontWindow: originalFrontWindow,
                targetWindowId: windowId,
                traceRecorder: traceRecorder,
                targetPID: pid,
                delays: activeStateGuardDelays
            )
            await recordTraceStage(
                .afterActiveStateGuard,
                recorder: traceRecorder,
                targetPID: pid,
                targetWindowId: windowId,
                orderGuardian: orderGuardian
            )
            if let traceRecorder {
                try await recordTraceSettleSamples(
                    recorder: traceRecorder,
                    targetPID: pid,
                    targetWindowId: windowId,
                    orderGuardian: orderGuardian
                )
            }
            try await orderChangeObservation?.finish()
            let result = WindowClickResult(pid: pid, windowId: windowId, point: point)
            let snapshots = await traceRecorder?.allSnapshots() ?? []
            return WindowClickTraceResult(result: result, snapshots: snapshots)
        } catch {
            try? await orderChangeObservation?.finish()
            throw error
        }
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

    private func reactivateOriginalFrontApplicationIfNeeded(
        _ originalFrontWindow: WindowInfo?,
        targetWindowId: CGWindowID
    ) async {
        guard let originalFrontWindow, originalFrontWindow.id != targetWindowId else {
            return
        }
        _ = await activateApplication(originalFrontWindow.pid)
    }

    private func runPostDispatchCleanup(
        pid: pid_t,
        windowId: CGWindowID,
        originalFrontWindow: WindowInfo?,
        orderGuardian: WindowOrderGuardian?,
        traceRecorder: WindowClickTraceRecorder?
    ) async throws {
        try await restoreOriginalFrontWindow(originalFrontWindow, targetWindowId: windowId)
        await recordTraceStage(
            .afterRestoreOriginalFrontWindow,
            recorder: traceRecorder,
            targetPID: pid,
            targetWindowId: windowId,
            orderGuardian: orderGuardian
        )
        try await deactivateTargetWindowIfNeeded(
            pid: pid,
            windowId: windowId,
            originalFrontWindow: originalFrontWindow
        )
        await reactivateOriginalFrontApplicationIfNeeded(
            originalFrontWindow,
            targetWindowId: windowId
        )
        await recordTraceStage(
            .afterTargetDeactivate,
            recorder: traceRecorder,
            targetPID: pid,
            targetWindowId: windowId,
            orderGuardian: orderGuardian
        )
    }

    private func makeWindowOrderGuardian(targetWindowId: CGWindowID) throws -> WindowOrderGuardian? {
        guard windowOrderChangeObserver != nil || !activeStateGuardDelays.isEmpty else {
            return nil
        }
        return try WindowOrderGuardian(
            targetWindowId: targetWindowId,
            beforeWindows: visibleWindowsLookup()
        )
    }

    private func startWindowOrderChangeGuard(
        _ orderGuardian: WindowOrderGuardian?,
        originalFrontWindow: WindowInfo?,
        targetWindowId: CGWindowID,
        targetPID: pid_t
    ) async throws -> WindowOrderChangeObservation? {
        guard let orderGuardian, let windowOrderChangeObserver else {
            return nil
        }
        return try await windowOrderChangeObserver.observe(
            windowIds: orderGuardian.observedWindowIds
        ) { [self] _ in
            try await self.runActiveStateGuard(
                orderGuardian,
                originalFrontWindow: originalFrontWindow,
                targetWindowId: targetWindowId,
                targetPID: targetPID,
                delays: [0]
            )
        }
    }

    private func runActiveStateGuard(
        _ orderGuardian: WindowOrderGuardian?,
        originalFrontWindow: WindowInfo?,
        targetWindowId: CGWindowID,
        traceRecorder: WindowClickTraceRecorder? = nil,
        targetPID: pid_t? = nil,
        delays: [UInt64]
    ) async throws {
        var elapsed: UInt64 = 0
        for (attempt, delay) in delays.enumerated() {
            if delay > 0 {
                try await sleepForActiveStateGuard(delay)
                elapsed += delay
            }
            let orderDriftObserved = try await runActiveStateGuardOnce(
                orderGuardian,
                originalFrontWindow: originalFrontWindow,
                targetWindowId: targetWindowId
            )
            let targetActive = await targetApplicationIsActive(
                targetPID,
                originalFrontWindow: originalFrontWindow,
                targetWindowId: targetWindowId
            )
            let corrected = orderDriftObserved || targetActive
            if corrected {
                await reactivateOriginalFrontApplicationIfNeeded(
                    originalFrontWindow,
                    targetWindowId: targetWindowId
                )
            }
            if let traceRecorder, let targetPID {
                await recordTraceStage(
                    .activeStateGuardTick,
                    recorder: traceRecorder,
                    targetPID: targetPID,
                    targetWindowId: targetWindowId,
                    orderGuardian: orderGuardian,
                    elapsedNanoseconds: elapsed,
                    guardAttempt: attempt,
                    corrected: corrected
                )
            }
        }
    }

    private func targetApplicationIsActive(
        _ targetPID: pid_t?,
        originalFrontWindow: WindowInfo?,
        targetWindowId: CGWindowID
    ) async -> Bool {
        guard let targetPID, originalFrontWindow?.id != targetWindowId else {
            return false
        }
        return await isApplicationActive(targetPID)
    }

    @discardableResult
    private func runActiveStateGuardOnce(
        _ orderGuardian: WindowOrderGuardian?,
        originalFrontWindow: WindowInfo?,
        targetWindowId: CGWindowID
    ) async throws -> Bool {
        guard let orderGuardian else {
            return false
        }
        let orderDriftObserved = try orderGuardian.targetCrossedProtectedWindow(
            currentWindows: visibleWindowsLookup()
        )
        if orderDriftObserved {
            try await restoreOriginalFrontWindow(originalFrontWindow, targetWindowId: targetWindowId)
        }
        return orderDriftObserved
    }

    private func recordTraceStage(
        _ stage: WindowClickTraceStage,
        recorder: WindowClickTraceRecorder?,
        targetPID: pid_t,
        targetWindowId: CGWindowID,
        orderGuardian: WindowOrderGuardian?,
        elapsedNanoseconds: UInt64? = nil,
        guardAttempt: Int? = nil,
        corrected: Bool? = nil,
        currentWindows providedCurrentWindows: [WindowInfo]? = nil
    ) async {
        guard let recorder else {
            return
        }

        let currentWindows = providedCurrentWindows ?? visibleWindowsLookup()
        let orderedWindows = WindowOrderGuardian.guardableWindows(currentWindows)
        let targetRank = orderedWindows.firstIndex { $0.id == targetWindowId }.map { $0 + 1 }
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let frontmostWindow = Self.currentFrontmostLayerZeroWindow()
        let targetApp = NSRunningApplication(processIdentifier: targetPID)
        await recorder.record(WindowClickTraceSnapshot(
            stage: stage,
            frontmostPID: frontmostApp?.processIdentifier,
            frontmostBundleIdentifier: frontmostApp?.bundleIdentifier,
            frontmostWindowId: frontmostWindow?.id,
            targetIsActive: targetApp?.isActive ?? false,
            targetRank: targetRank,
            protectedCoveredCount: orderGuardian?.protectedCoveredCount(currentWindows: currentWindows),
            elapsedNanoseconds: elapsedNanoseconds,
            guardAttempt: guardAttempt,
            corrected: corrected
        ))
    }

    private func recordTraceSettleSamples(
        recorder: WindowClickTraceRecorder,
        targetPID: pid_t,
        targetWindowId: CGWindowID,
        orderGuardian: WindowOrderGuardian?
    ) async throws {
        let samples: [(stage: WindowClickTraceStage, delay: UInt64)] = [
            (.afterTraceSettle50ms, 50_000_000),
            (.afterTraceSettle200ms, 150_000_000),
            (.afterTraceSettle1s, 800_000_000),
        ]
        for sample in samples {
            try await sleepForActiveStateGuard(sample.delay)
            await recordTraceStage(
                sample.stage,
                recorder: recorder,
                targetPID: targetPID,
                targetWindowId: targetWindowId,
                orderGuardian: orderGuardian
            )
        }
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
    static let liveActiveStateGuardInterval: UInt64 = 5_000_000
    static let liveActiveStateGuardWindow: UInt64 = 300_000_000
    static let liveActiveStateGuardDelays: [UInt64] = [
        0,
    ] + Array(
        repeating: liveActiveStateGuardInterval,
        count: Int(liveActiveStateGuardWindow / liveActiveStateGuardInterval)
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

private actor WindowClickTraceRecorder {
    private var recordedSnapshots: [WindowClickTraceSnapshot] = []

    func record(_ snapshot: WindowClickTraceSnapshot) {
        recordedSnapshots.append(snapshot)
    }

    func allSnapshots() -> [WindowClickTraceSnapshot] {
        recordedSnapshots
    }
}

private extension MouseClickPostStage {
    var runsActiveStateGuard: Bool {
        switch self {
        case .afterMouseMoved, .afterTargetDown, .afterTargetUp:
            return true
        case .afterPrimerDown, .afterPrimerUp, .afterPrimerGap:
            return false
        }
    }
}

private extension MouseClickDeliveryRoute {
    var requiresPreClickFocus: Bool {
        switch self {
        case .appKit, .chromiumElectron:
            return true
        }
    }
}

private extension WindowClickTraceStage {
    init(_ stage: MouseClickPostStage) {
        switch stage {
        case .afterMouseMoved:
            self = .afterMouseMoved
        case .afterPrimerDown:
            self = .afterPrimerDown
        case .afterPrimerUp:
            self = .afterPrimerUp
        case .afterPrimerGap:
            self = .afterPrimerGap
        case .afterTargetDown:
            self = .afterTargetDown
        case .afterTargetUp:
            self = .afterTargetUp
        }
    }
}

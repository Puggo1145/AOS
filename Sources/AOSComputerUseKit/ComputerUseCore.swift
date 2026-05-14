import AppKit
import AOSAXSupport
import CoreGraphics
import Darwin
import Foundation

// MARK: - ComputerUseCore
//
// Public façade for the Computer Use foundation: app/window enumeration,
// AX snapshot rendering, screenshot capture, non-raising focus, background
// mouse-event dispatch, and snapshot cache ownership.

public struct AppStateBundle: Sendable {
    public let pid: pid_t
    public let stateId: StateID
    public let treeMarkdown: String
    public let elementCount: Int
    public let screenshot: Screenshot?
    public let bundleId: String?
    public let appName: String?

    public init(
        pid: pid_t,
        stateId: StateID,
        treeMarkdown: String,
        elementCount: Int,
        screenshot: Screenshot?,
        bundleId: String?,
        appName: String?
    ) {
        self.pid = pid
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

/// Result of starting or stopping a pid-scoped app session.
public struct AppSessionResult: Sendable, Equatable {
    public let pid: pid_t

    public init(pid: pid_t) {
        self.pid = pid
    }
}

/// Result of posting a coordinate-based mouse event to a WindowServer window.
public struct WindowMouseEventResult: Sendable, Equatable {
    public let pid: pid_t
    public let windowId: CGWindowID
    public let event: BackgroundMouseEvent

    public init(pid: pid_t, windowId: CGWindowID, event: BackgroundMouseEvent) {
        self.pid = pid
        self.windowId = windowId
        self.event = event
    }
}

/// Result of posting a pid-scoped keyboard event to a WindowServer window.
public struct WindowKeyboardEventResult: Sendable, Equatable {
    public let pid: pid_t
    public let windowId: CGWindowID
    public let event: BackgroundKeyboardEvent

    public init(pid: pid_t, windowId: CGWindowID, event: BackgroundKeyboardEvent) {
        self.pid = pid
        self.windowId = windowId
        self.event = event
    }
}

/// WindowServer and app-active sampling stage around a background mouse event.
public enum WindowMouseEventTraceStage: String, Sendable, Codable, Equatable {
    case before
    case afterFocus
    case afterMouseMoved
    case afterPrimerDown
    case afterPrimerUp
    case afterPrimerGap
    case afterTargetDown
    case afterTargetDragged
    case afterTargetUp
    case activeStateGuardTick
    case afterActiveStateGuard
    case afterTraceSettle50ms
    case afterTraceSettle200ms
    case afterTraceSettle1s
}

/// Snapshot of frontmost-window and target-window state at one trace stage.
public struct WindowMouseEventTraceSnapshot: Sendable, Codable, Equatable {
    public let stage: WindowMouseEventTraceStage
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
        stage: WindowMouseEventTraceStage,
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

/// Trace result for a coordinate-based background mouse event.
public struct WindowMouseEventTraceResult: Sendable, Equatable {
    public let result: WindowMouseEventResult
    public let snapshots: [WindowMouseEventTraceSnapshot]

    public init(result: WindowMouseEventResult, snapshots: [WindowMouseEventTraceSnapshot]) {
        self.result = result
        self.snapshots = snapshots
    }
}

/// Diagnostics-only Computer Use surface, kept separate from business calls.
public struct ComputerUseDiagnostics: Sendable {
    private let core: ComputerUseCore

    init(core: ComputerUseCore) {
        self.core = core
    }

    /// Focuses `windowId` for `pid` without raising or reordering the window.
    public func focusWindowWithoutRaise(
        pid: pid_t,
        windowId: CGWindowID
    ) async throws -> WindowFocusResult {
        try await core.focusWindowWithoutRaise(pid: pid, windowId: windowId)
    }

    /// Posts a mouse event and returns diagnostic state captured around each event stage.
    public func postMouseEventTrace(
        windowId: CGWindowID,
        event: BackgroundMouseEvent
    ) async throws -> WindowMouseEventTraceResult {
        try await core.postMouseEventTrace(windowId: windowId, event: event)
    }

    /// Passively samples WindowServer ordering around a target window.
    public func observeWindowOrder(
        pid: pid_t,
        windowId: CGWindowID,
        durationMilliseconds: Int,
        intervalMilliseconds: Int
    ) async throws -> [WindowOrderObservationSample] {
        let durationNanoseconds = try Self.nanoseconds(
            fromMilliseconds: durationMilliseconds,
            parameterName: "durationMilliseconds"
        )
        let intervalNanoseconds = try Self.nanoseconds(
            fromMilliseconds: intervalMilliseconds,
            parameterName: "intervalMilliseconds"
        )
        let probe = try WindowOrderProbe.live(targetPID: pid, targetWindowId: windowId)
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        var samples: [WindowOrderObservationSample] = []

        while true {
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let elapsed = now >= start ? now - start : 0
            samples.append(probe.sample(elapsedNanoseconds: elapsed))
            if elapsed >= durationNanoseconds {
                return samples
            }
            try await Task.sleep(nanoseconds: intervalNanoseconds)
        }
    }

    private static func nanoseconds(
        fromMilliseconds milliseconds: Int,
        parameterName: String
    ) throws -> UInt64 {
        guard milliseconds > 0 else {
            throw ComputerUseError.diagnosticsUnavailable("\(parameterName) must be greater than 0")
        }
        let (nanoseconds, overflow) = UInt64(milliseconds).multipliedReportingOverflow(by: 1_000_000)
        if overflow {
            throw ComputerUseError.diagnosticsUnavailable("\(parameterName) is too large")
        }
        return nanoseconds
    }
}

/// Type that exposes Computer Use diagnostics separately from business calls.
public protocol ComputerUseDiagnosticsProviding: Sendable {
    var diagnostics: ComputerUseDiagnostics { get }
}

public enum CaptureMode: String, Sendable, Equatable {
    case vision
    case ax
}

public enum ComputerUseError: Error, CustomStringConvertible, Sendable {
    case appNotFound(pid: pid_t)
    case windowMismatch(pid: pid_t, windowId: CGWindowID, ownerPid: pid_t?)
    case captureUnavailable(String)
    case focusUnavailable(String)
    case mouseEventUnavailable(String)
    case keyboardEventUnavailable(String)
    case axElementEventUnavailable(String)
    case appSessionUnavailable(String)
    case diagnosticsUnavailable(String)
    case payloadTooLarge(bytes: Int, limit: Int)
    case windowNotFound(windowId: CGWindowID)

    public var description: String {
        switch self {
        case .appNotFound(let pid):
            return "no running application with pid \(pid)"
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
        case .mouseEventUnavailable(let message):
            return "mouse event unavailable: \(message)"
        case .keyboardEventUnavailable(let message):
            return "keyboard event unavailable: \(message)"
        case .axElementEventUnavailable(let message):
            return "AX element event unavailable: \(message)"
        case .appSessionUnavailable(let message):
            return "app session unavailable: \(message)"
        case .diagnosticsUnavailable(let message):
            return "diagnostics unavailable: \(message)"
        case .payloadTooLarge(let bytes, let limit):
            return "screenshot payload \(bytes) bytes exceeds raw limit \(limit) bytes after downscale retries"
        case .windowNotFound(let windowId):
            return "no window with id \(windowId)"
        }
    }
}

private struct ActiveAppSession: Sendable {
    let id: UInt64
    let pid: pid_t

    var result: AppSessionResult {
        AppSessionResult(pid: pid)
    }

    init(
        id: UInt64,
        pid: pid_t
    ) {
        self.id = id
        self.pid = pid
    }

    func isSameSession(as other: ActiveAppSession) -> Bool {
        id == other.id
    }

    func isSameApp(pid: pid_t) -> Bool {
        self.pid == pid
    }

}

public actor ComputerUseCore: ComputerUseDiagnosticsProviding {
    private let webAccessibilityActivator: AXWebAccessibilityActivator
    private let snapshot: AccessibilitySnapshot
    private let cache: StateCache
    private let capture: WindowCapture
    private let windowLookup: @Sendable (CGWindowID) -> WindowInfo?
    private let windowsForPIDLookup: @Sendable (pid_t) -> [WindowInfo]
    private let visibleWindowsLookup: @Sendable () -> [WindowInfo]
    private let frontmostWindowLookup: @Sendable () -> WindowInfo?
    private let mouseEventDeliveryRoute: @Sendable (pid_t) -> BackgroundMouseEventDeliveryRoute
    private let requiresPreEventFocus: @Sendable (BackgroundMouseEventDeliveryRoute, BackgroundMouseEvent) -> Bool
    private let focusWindowWithoutRaising: @Sendable (pid_t, CGWindowID) async throws -> Void
    private let deactivateWindowWithoutRaising: @Sendable (pid_t, CGWindowID) async throws -> Void
    private let activateApplication: @Sendable (pid_t) async -> Bool
    private let isApplicationActive: @Sendable (pid_t) async -> Bool
    private let windowOrderChangeObserver: WindowOrderChangeObserver?
    private let activeStateGuardDelays: [UInt64]
    private let sleepForActiveStateGuard: @Sendable (UInt64) async throws -> Void
    private let postMouseEventToRoute: @Sendable (
        BackgroundMouseEvent,
        BackgroundMouseEventTarget,
        BackgroundMouseEventDeliveryRoute,
        BackgroundMouseEventPostObserver?
    ) async throws -> Void
    private let postKeyboardEventToPid: @Sendable (
        BackgroundKeyboardEvent,
        BackgroundKeyboardEventTarget
    ) async throws -> Void
    private let postAXElementEventToTarget: @Sendable (
        AXElementEvent,
        AXElementEventTarget
    ) async throws -> Void
    private var activeAppSession: ActiveAppSession?
    private var nextAppSessionId: UInt64 = 1

    public init() {
        let webAccessibilityActivator = AXWebAccessibilityActivator()
        let windowFocuser = SkyLightWindowFocuser.live()
        let mousePoster = MouseEventPoster.live()
        let keyboardPoster = KeyboardEventPoster.live()
        let axElementEventPoster = AXElementEventPoster(webAccessibilityActivator: webAccessibilityActivator)
        let mouseDeliveryClassifier = BackgroundMouseEventDeliveryClassifier()
        let deliveryRouteForPID: @Sendable (pid_t) -> BackgroundMouseEventDeliveryRoute = { pid in
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
            windowsForPIDLookup: { pid in
                WindowEnumerator.appWindows(forPid: pid)
            },
            visibleWindowsLookup: {
                WindowEnumerator.visibleWindows()
            },
            frontmostWindowLookup: {
                Self.currentFrontmostLayerZeroWindow()
            },
            mouseEventDeliveryRoute: deliveryRouteForPID,
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
            postMouseEvent: { event, target, deliveryRoute, stageObserver in
                try await mousePoster.post(
                    event,
                    to: target,
                    deliveryRoute: deliveryRoute,
                    stageObserver: stageObserver
                )
            },
            postKeyboardEvent: { event, target in
                try keyboardPoster.post(event, to: target)
            },
            postAXElementEvent: { event, target in
                try await axElementEventPoster.post(event, to: target)
            }
        )
    }

    public nonisolated var diagnostics: ComputerUseDiagnostics {
        ComputerUseDiagnostics(core: self)
    }

    init(
        webAccessibilityActivator: AXWebAccessibilityActivator = AXWebAccessibilityActivator(),
        snapshot: AccessibilitySnapshot? = nil,
        cache: StateCache = StateCache(ttlSeconds: 30),
        capture: WindowCapture = WindowCapture(),
        windowLookup: @escaping @Sendable (CGWindowID) -> WindowInfo?,
        windowsForPIDLookup: (@Sendable (pid_t) -> [WindowInfo])? = nil,
        visibleWindowsLookup: @escaping @Sendable () -> [WindowInfo] = { [] },
        frontmostWindowLookup: @escaping @Sendable () -> WindowInfo? = { nil },
        mouseEventDeliveryRoute: @escaping @Sendable (pid_t) -> BackgroundMouseEventDeliveryRoute = { _ in .appKit },
        requiresPreEventFocus: @escaping @Sendable (
            BackgroundMouseEventDeliveryRoute,
            BackgroundMouseEvent
        ) -> Bool = { route, _ in route.requiresPreEventFocus },
        focusWindowWithoutRaising: @escaping @Sendable (pid_t, CGWindowID) async throws -> Void,
        deactivateWindowWithoutRaising: @escaping @Sendable (pid_t, CGWindowID) async throws -> Void,
        activateApplication: @escaping @Sendable (pid_t) async -> Bool = { _ in false },
        isApplicationActive: @escaping @Sendable (pid_t) async -> Bool = { _ in false },
        windowOrderChangeObserver: WindowOrderChangeObserver? = nil,
        activeStateGuardDelays: [UInt64] = [],
        sleepForActiveStateGuard: @escaping @Sendable (UInt64) async throws -> Void = { _ in },
        postMouseEvent: @escaping @Sendable (
            BackgroundMouseEvent,
            BackgroundMouseEventTarget,
            BackgroundMouseEventDeliveryRoute,
            BackgroundMouseEventPostObserver?
        ) async throws -> Void = { _, _, _, _ in
            throw ComputerUseError.mouseEventUnavailable("postMouseEvent dependency was not configured")
        },
        postKeyboardEvent: @escaping @Sendable (
            BackgroundKeyboardEvent,
            BackgroundKeyboardEventTarget
        ) async throws -> Void = { _, _ in
            throw ComputerUseError.keyboardEventUnavailable("postKeyboardEvent dependency was not configured")
        },
        postAXElementEvent: @escaping @Sendable (
            AXElementEvent,
            AXElementEventTarget
        ) async throws -> Void = { _, _ in
            throw ComputerUseError.axElementEventUnavailable("postAXElementEvent dependency was not configured")
        }
    ) {
        let snapshot = snapshot ?? AccessibilitySnapshot(webAccessibilityActivator: webAccessibilityActivator)
        self.webAccessibilityActivator = webAccessibilityActivator
        self.snapshot = snapshot
        self.cache = cache
        self.capture = capture
        self.windowLookup = windowLookup
        self.visibleWindowsLookup = visibleWindowsLookup
        self.windowsForPIDLookup = windowsForPIDLookup ?? { pid in
            visibleWindowsLookup().filter { $0.pid == pid && $0.layer == 0 }
        }
        self.frontmostWindowLookup = frontmostWindowLookup
        self.mouseEventDeliveryRoute = mouseEventDeliveryRoute
        self.requiresPreEventFocus = requiresPreEventFocus
        self.focusWindowWithoutRaising = focusWindowWithoutRaising
        self.deactivateWindowWithoutRaising = deactivateWindowWithoutRaising
        self.activateApplication = activateApplication
        self.isApplicationActive = isApplicationActive
        self.windowOrderChangeObserver = windowOrderChangeObserver
        self.activeStateGuardDelays = activeStateGuardDelays
        self.sleepForActiveStateGuard = sleepForActiveStateGuard
        self.postMouseEventToRoute = postMouseEvent
        self.postKeyboardEventToPid = postKeyboardEvent
        self.postAXElementEventToTarget = postAXElementEvent
    }

    public func listApps(mode: AppListMode) -> [AppInfo] {
        AppEnumerator.apps(mode: mode)
    }

    public func getAppType(pid: pid_t) throws -> AppTypeResult {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            throw ComputerUseError.appNotFound(pid: pid)
        }

        let classifier = BackgroundMouseEventDeliveryClassifier()
        let classification = classifier.classification(
            bundleIdentifier: app.bundleIdentifier,
            bundleURL: app.bundleURL
        )

        return AppTypeResult(
            pid: pid,
            appName: app.localizedName,
            bundleId: app.bundleIdentifier,
            bundlePath: app.bundleURL?.standardizedFileURL.path,
            type: classification.route.appType,
            reason: classification.reason
        )
    }

    public func listWindows(pid: pid_t) -> [WindowInfo] {
        windowsForPIDLookup(pid)
    }

    public func getAppState(
        windowId: CGWindowID,
        captureMode: CaptureMode = .vision,
        maxImageDimension: Int = 0
    ) async throws -> AppStateBundle {
        let session = try requireActiveAppSession()
        let pid = session.pid
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
            pid: pid,
            stateId: stateId,
            treeMarkdown: result.treeMarkdown,
            elementCount: result.elements.count,
            screenshot: shot,
            bundleId: bundleId,
            appName: appName
        )
    }

    func focusWindowWithoutRaise(
        pid: pid_t,
        windowId: CGWindowID
    ) async throws -> WindowFocusResult {
        try validateOwnership(pid: pid, windowId: windowId)
        try await focusWindowWithoutRaising(pid, windowId)
        return WindowFocusResult(pid: pid, windowId: windowId)
    }

    /// Starts an app session for `windowId`, ending any active session for a
    /// different target before focusing the requested window without raising it.
    public func startAppSession(
        pid: pid_t,
        windowId: CGWindowID
    ) async throws -> AppSessionResult {
        _ = try validateOwnership(pid: pid, windowId: windowId)
        let session = try await startAppSession(
            pid: pid,
            windowId: windowId,
            shouldFocusTarget: true,
            traceRecorder: nil
        )
        return session.result
    }

    /// Stops the active app session and runs the target deactivation cleanup.
    public func stopAppSession() async throws -> AppSessionResult {
        guard let session = activeAppSession else {
            throw ComputerUseError.appSessionUnavailable("no active app session")
        }
        try await stopAppSession(session)
        if activeAppSession?.isSameSession(as: session) == true {
            activeAppSession = nil
        }
        return session.result
    }

    /// Returns the active app session without changing focus or window order.
    public func currentAppSession() throws -> AppSessionResult {
        try requireActiveAppSession().result
    }

    /// Posts a coordinate-based background mouse event to a window owned by
    /// the active app session.
    public func postMouseEvent(
        windowId: CGWindowID,
        event: BackgroundMouseEvent
    ) async throws -> WindowMouseEventResult {
        try await performPostMouseEvent(windowId: windowId, event: event, tracing: false).result
    }

    func postMouseEventTrace(
        windowId: CGWindowID,
        event: BackgroundMouseEvent
    ) async throws -> WindowMouseEventTraceResult {
        try await performPostMouseEvent(
            windowId: windowId,
            event: event,
            tracing: true
        )
    }

    /// Posts a pid-scoped background keyboard event to a window owned by the
    /// active app session.
    public func postKeyboardEvent(
        windowId: CGWindowID,
        event: BackgroundKeyboardEvent
    ) async throws -> WindowKeyboardEventResult {
        try await performPostKeyboardEvent(windowId: windowId, event: event)
    }

    /// Posts a semantic AX event to an element from a prior app-state snapshot.
    public func postEventToAXElement(
        windowId: CGWindowID,
        stateId: StateID,
        elementIndex: Int,
        event: AXElementEvent
    ) async throws -> AXElementEventResult {
        let session = try requireActiveAppSession()
        let pid = session.pid
        try validateOwnership(pid: pid, windowId: windowId)
        try validateAXElementEvent(event)
        let element = try await cache.lookup(
            pid: pid,
            windowId: windowId,
            stateId: stateId,
            elementIndex: elementIndex
        )
        let target = AXElementEventTarget(
            pid: pid,
            windowId: windowId,
            stateId: stateId,
            elementIndex: elementIndex,
            element: element
        )
        try await postAXElementEventToTarget(event, target)
        return AXElementEventResult(
            pid: pid,
            windowId: windowId,
            stateId: stateId,
            elementIndex: elementIndex,
            event: event
        )
    }

    private func performPostMouseEvent(
        windowId: CGWindowID,
        event: BackgroundMouseEvent,
        tracing: Bool
    ) async throws -> WindowMouseEventTraceResult {
        let activeSession = try requireActiveAppSession()
        let pid = activeSession.pid
        let window = try validateOwnership(pid: pid, windowId: windowId)
        try validateMouseEvent(event, isInside: window)
        let deliveryRoute = mouseEventDeliveryRoute(pid)
        guard deliveryRoute.supports(event) else {
            throw ComputerUseError.mouseEventUnavailable(
                "\(deliveryRoute) route does not support \(event)"
            )
        }
        let target = BackgroundMouseEventTarget(pid: pid, windowId: windowId, windowBounds: window.bounds)
        let traceRecorder = tracing ? WindowMouseEventTraceRecorder() : nil
        let orderGuardian = try makeWindowOrderGuardian(targetWindowId: windowId)
        try await prepareActiveAppSessionWindow(
            windowId: windowId,
            shouldFocusTarget: requiresPreEventFocus(deliveryRoute, event),
            orderGuardian: orderGuardian,
            traceRecorder: traceRecorder
        )
        let originalFrontWindow = frontmostWindowLookup()
        let orderChangeObservation = try await startWindowOrderChangeGuard(
            orderGuardian,
            originalFrontWindow: originalFrontWindow,
            targetWindowId: windowId,
            targetPID: pid,
            allowsTargetActive: true
        )

        do {
            try await postMouseEventToRoute(event, target, deliveryRoute) { [self] stage in
                if stage.runsActiveStateGuard {
                    let orderDriftObserved = try await self.runActiveStateGuardOnce(
                        orderGuardian,
                        originalFrontWindow: originalFrontWindow,
                        targetWindowId: windowId
                    )
                    if orderDriftObserved {
                        await self.reactivateOriginalFrontApplicationIfNeeded(
                            originalFrontWindow,
                            targetWindowId: windowId
                        )
                    }
                }
                await self.recordTraceStage(
                    WindowMouseEventTraceStage(stage),
                    recorder: traceRecorder,
                    targetPID: pid,
                    targetWindowId: windowId,
                    orderGuardian: orderGuardian
                )
            }
            try await runActiveStateGuard(
                orderGuardian,
                originalFrontWindow: originalFrontWindow,
                targetWindowId: windowId,
                traceRecorder: traceRecorder,
                targetPID: pid,
                delays: activeStateGuardDelays,
                allowsTargetActive: true
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
            let result = WindowMouseEventResult(pid: pid, windowId: windowId, event: event)
            let snapshots = await traceRecorder?.allSnapshots() ?? []
            return WindowMouseEventTraceResult(result: result, snapshots: snapshots)
        } catch {
            try? await orderChangeObservation?.finish()
            throw error
        }
    }

    private func performPostKeyboardEvent(
        windowId: CGWindowID,
        event: BackgroundKeyboardEvent
    ) async throws -> WindowKeyboardEventResult {
        let activeSession = try requireActiveAppSession()
        let pid = activeSession.pid
        _ = try validateOwnership(pid: pid, windowId: windowId)
        try validateKeyboardEvent(event)
        let target = BackgroundKeyboardEventTarget(pid: pid, windowId: windowId)
        let orderGuardian = try makeWindowOrderGuardian(targetWindowId: windowId)
        try await prepareActiveAppSessionWindow(
            windowId: windowId,
            shouldFocusTarget: true,
            orderGuardian: orderGuardian,
            traceRecorder: nil
        )
        let originalFrontWindow = frontmostWindowLookup()
        let orderChangeObservation = try await startWindowOrderChangeGuard(
            orderGuardian,
            originalFrontWindow: originalFrontWindow,
            targetWindowId: windowId,
            targetPID: pid,
            allowsTargetActive: true
        )

        do {
            try await postKeyboardEventToPid(event, target)
            try await runActiveStateGuard(
                orderGuardian,
                originalFrontWindow: originalFrontWindow,
                targetWindowId: windowId,
                traceRecorder: nil,
                targetPID: pid,
                delays: activeStateGuardDelays,
                allowsTargetActive: true
            )
            try await orderChangeObservation?.finish()
            return WindowKeyboardEventResult(pid: pid, windowId: windowId, event: event)
        } catch {
            try? await orderChangeObservation?.finish()
            throw error
        }
    }

    private func validateKeyboardEvent(_ event: BackgroundKeyboardEvent) throws {
        switch event {
        case .text(let text, let delayMilliseconds):
            guard !text.isEmpty else {
                throw ComputerUseError.keyboardEventUnavailable("text input cannot be empty")
            }
            guard (0...200).contains(delayMilliseconds) else {
                throw ComputerUseError.keyboardEventUnavailable(
                    "text input delay must be between 0 and 200ms"
                )
            }
        case .keyPress(_, _, let count):
            guard count > 0 else {
                throw ComputerUseError.keyboardEventUnavailable(
                    "key press count must be greater than 0"
                )
            }
        case .hotkey(let modifiers, _):
            guard !modifiers.isEmpty else {
                throw ComputerUseError.keyboardEventUnavailable(
                    "hotkey requires at least one modifier"
                )
            }
        }
    }

    private func validateAXElementEvent(_ event: AXElementEvent) throws {
        switch event {
        case .setValue(let value), .setSelectedText(let value):
            guard !value.isEmpty else {
                throw ComputerUseError.axElementEventUnavailable("AX text value cannot be empty")
            }
        case .scroll(_, let pages):
            guard pages.isFinite, pages > 0 else {
                throw ComputerUseError.axElementEventUnavailable("scroll pages must be finite and greater than 0")
            }
        case .action, .focus:
            break
        }
    }

    private func validateMouseEvent(_ event: BackgroundMouseEvent, isInside window: WindowInfo) throws {
        if case .click(_, _, let count) = event {
            guard count > 0 else {
                throw ComputerUseError.mouseEventUnavailable(
                    "click count must be greater than 0"
                )
            }
        }
        for point in event.screenPoints {
            guard window.bounds.cgRect.contains(point) else {
                throw ComputerUseError.mouseEventUnavailable(
                    "point \(Int(point.x)),\(Int(point.y)) for \(event) is outside window \(window.id)"
                )
            }
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

    private func startAppSession(
        pid: pid_t,
        windowId: CGWindowID,
        shouldFocusTarget: Bool,
        traceRecorder: WindowMouseEventTraceRecorder?
    ) async throws -> ActiveAppSession {
        if let session = activeAppSession {
            if session.isSameApp(pid: pid) {
                try await prepareActiveAppSessionWindow(
                    windowId: windowId,
                    shouldFocusTarget: shouldFocusTarget,
                    orderGuardian: nil,
                    traceRecorder: traceRecorder
                )
                return try requireActiveAppSession()
            }

            try await stopAppSession(session)
            if activeAppSession?.isSameSession(as: session) == true {
                activeAppSession = nil
            }
        }

        let session = ActiveAppSession(
            id: nextAppSessionId,
            pid: pid
        )
        nextAppSessionId += 1
        await recordTraceStage(
            .before,
            recorder: traceRecorder,
            targetPID: pid,
            targetWindowId: windowId,
            orderGuardian: nil
        )
        if shouldFocusTarget {
            try await focusWindowWithoutRaising(pid, windowId)
            activeAppSession = session
            try await Task.sleep(nanoseconds: 5_000_000)
            await recordTraceStage(
                .afterFocus,
                recorder: traceRecorder,
                targetPID: pid,
                targetWindowId: windowId,
                orderGuardian: nil
            )
        } else {
            activeAppSession = session
        }
        return session
    }

    private func prepareActiveAppSessionWindow(
        windowId: CGWindowID,
        shouldFocusTarget: Bool,
        orderGuardian: WindowOrderGuardian?,
        traceRecorder: WindowMouseEventTraceRecorder?
    ) async throws {
        let session = try requireActiveAppSession()
        let pid = session.pid
        await recordTraceStage(
            .before,
            recorder: traceRecorder,
            targetPID: pid,
            targetWindowId: windowId,
            orderGuardian: orderGuardian
        )
        if shouldFocusTarget {
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
    }

    private func requireActiveAppSession() throws -> ActiveAppSession {
        guard let session = activeAppSession else {
            throw ComputerUseError.appSessionUnavailable("no active app session")
        }
        return session
    }

    private func stopAppSession(_ session: ActiveAppSession) async throws {
        let windows = windowsForPIDLookup(session.pid)
        let frontmostWindow = frontmostWindowLookup()
        let protectedWindowId = frontmostWindow?.pid == session.pid ? frontmostWindow?.id : nil
        let windowIds = windows
            .map(\.id)
            .filter { $0 != protectedWindowId }

        for windowId in windowIds {
            try await deactivateTargetWindowIfNeeded(
                pid: session.pid,
                windowId: windowId
            )
        }
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
        windowId: CGWindowID
    ) async throws {
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
        targetPID: pid_t,
        allowsTargetActive: Bool
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
                delays: [0],
                allowsTargetActive: allowsTargetActive
            )
        }
    }

    private func runActiveStateGuard(
        _ orderGuardian: WindowOrderGuardian?,
        originalFrontWindow: WindowInfo?,
        targetWindowId: CGWindowID,
        traceRecorder: WindowMouseEventTraceRecorder? = nil,
        targetPID: pid_t? = nil,
        delays: [UInt64],
        allowsTargetActive: Bool = false
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
            let targetActive = allowsTargetActive
                ? false
                : await targetApplicationIsActive(
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
        _ stage: WindowMouseEventTraceStage,
        recorder: WindowMouseEventTraceRecorder?,
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
        await recorder.record(WindowMouseEventTraceSnapshot(
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
        recorder: WindowMouseEventTraceRecorder,
        targetPID: pid_t,
        targetWindowId: CGWindowID,
        orderGuardian: WindowOrderGuardian?
    ) async throws {
        let samples: [(stage: WindowMouseEventTraceStage, delay: UInt64)] = [
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

private actor WindowMouseEventTraceRecorder {
    private var recordedSnapshots: [WindowMouseEventTraceSnapshot] = []

    func record(_ snapshot: WindowMouseEventTraceSnapshot) {
        recordedSnapshots.append(snapshot)
    }

    func allSnapshots() -> [WindowMouseEventTraceSnapshot] {
        recordedSnapshots
    }
}

private extension BackgroundMouseEventPostStage {
    var runsActiveStateGuard: Bool {
        switch self {
        case .afterMouseMoved, .afterTargetDown, .afterTargetDragged, .afterTargetUp:
            return true
        case .afterPrimerDown, .afterPrimerUp, .afterPrimerGap:
            return false
        }
    }
}

private extension BackgroundMouseEventDeliveryRoute {
    var requiresPreEventFocus: Bool {
        switch self {
        case .appKit, .webContent:
            return true
        }
    }
}

private extension WindowMouseEventTraceStage {
    init(_ stage: BackgroundMouseEventPostStage) {
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
        case .afterTargetDragged:
            self = .afterTargetDragged
        case .afterTargetUp:
            self = .afterTargetUp
        }
    }
}

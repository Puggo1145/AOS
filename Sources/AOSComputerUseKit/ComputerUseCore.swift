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
    public let stateId: StateID?
    public let treeMarkdown: String?
    public let elementCount: Int?
    public let screenshot: Screenshot?
    public let bundleId: String?
    public let appName: String?

    public init(
        stateId: StateID?,
        treeMarkdown: String?,
        elementCount: Int?,
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

public enum CaptureMode: String, Sendable, Equatable {
    case som
    case vision
    case ax
}

public enum ComputerUseError: Error, CustomStringConvertible, Sendable {
    case windowMismatch(pid: pid_t, windowId: CGWindowID, ownerPid: pid_t?)
    case captureUnavailable(String)
    case focusUnavailable(String)
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
    private let focusWindowWithoutRaising: @Sendable (pid_t, CGWindowID) async throws -> Void

    public init() {
        let webAccessibilityActivator = AXWebAccessibilityActivator()
        let windowFocuser = SkyLightWindowFocuser.live()
        self.init(
            webAccessibilityActivator: webAccessibilityActivator,
            snapshot: AccessibilitySnapshot(webAccessibilityActivator: webAccessibilityActivator),
            cache: StateCache(ttlSeconds: 30),
            capture: WindowCapture(),
            windowLookup: { windowId in
                WindowEnumerator.window(forId: windowId)
            },
            focusWindowWithoutRaising: { pid, windowId in
                try windowFocuser.focusWindowWithoutRaising(pid: pid, windowId: windowId)
            }
        )
    }

    init(
        webAccessibilityActivator: AXWebAccessibilityActivator = AXWebAccessibilityActivator(),
        snapshot: AccessibilitySnapshot? = nil,
        cache: StateCache = StateCache(ttlSeconds: 30),
        capture: WindowCapture = WindowCapture(),
        windowLookup: @escaping @Sendable (CGWindowID) -> WindowInfo?,
        focusWindowWithoutRaising: @escaping @Sendable (pid_t, CGWindowID) async throws -> Void
    ) {
        let snapshot = snapshot ?? AccessibilitySnapshot(webAccessibilityActivator: webAccessibilityActivator)
        self.webAccessibilityActivator = webAccessibilityActivator
        self.snapshot = snapshot
        self.cache = cache
        self.capture = capture
        self.windowLookup = windowLookup
        self.focusWindowWithoutRaising = focusWindowWithoutRaising
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
        captureMode: CaptureMode = .som,
        maxImageDimension: Int = 0
    ) async throws -> AppStateBundle {
        try validateOwnership(pid: pid, windowId: windowId)

        let app = NSRunningApplication(processIdentifier: pid)
        let bundleId = app?.bundleIdentifier
        let appName = app?.localizedName

        var stateId: StateID?
        var markdown: String?
        var elementCount: Int?
        if captureMode != .vision {
            let result = try await snapshot.walk(pid: pid, windowId: windowId)
            let id = await cache.store(pid: pid, windowId: windowId, elements: result.elements)
            stateId = id
            markdown = result.treeMarkdown
            elementCount = result.elements.count
        }

        var shot: Screenshot?
        if captureMode != .ax {
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
            treeMarkdown: markdown,
            elementCount: elementCount,
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

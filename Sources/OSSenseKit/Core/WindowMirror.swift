import Foundation
import AppKit
import ApplicationServices
import AXSupport

// MARK: - WindowMirror
//
// Per `docs/designs/os-sense.md` §"事件源与字段映射" rows "前台 app 切换"
// (NSWorkspace) and "焦点窗口切换" (AX `kAXFocusedWindowChangedNotification`).
//
// Two event sources, one projection:
//   - NSWorkspace.didActivateApplicationNotification → updates `app` and
//     re-binds AX subscription to the new pid.
//   - AX kAXFocusedWindowChangedNotification on the application element →
//     re-resolves the focused window inside the same app (used when the
//     user shifts focus across windows without leaving the app).
//
// Window resolution path: `kAXFocusedWindowAttribute` on the application
// element gives the window AXUIElement; from that we read
// `kAXTitleAttribute` (title) and call `_AXUIElementGetWindow` via
// `AXSupport` (windowId).
//
// Degraded path: when Accessibility is denied, AX subscription / reads are
// skipped and `WindowIdentity` falls back to `(title: app.name, windowId:
// nil)`. SenseStore pushes accessibility-grant transitions through
// `setAccessibilityGranted(_:)` so we never restart the hub.

@MainActor
public final class WindowMirror {
    internal struct FocusedWindowSnapshot {
        let element: AXUIElement
        let identity: WindowIdentity
    }

    public private(set) var app: AppIdentity?
    public private(set) var window: WindowIdentity?

    private let hub: AXObserverHub?
    /// Synchronous MainActor callback. Was previously `async`, which forced
    /// every emit through `Task { await self.onChange(...) }` and let two
    /// concurrent NSWorkspace activations interleave inside the consumer's
    /// state — breaking the documented "single writer" invariant. The
    /// synchronous form serializes naturally on @MainActor.
    private let onChange: @MainActor (AppIdentity?, WindowIdentity?) -> Void
    private let focusedWindowReader: @MainActor (AXUIElement, AppIdentity) -> FocusedWindowSnapshot?
    private let appElementFactory: @MainActor (pid_t) -> AXUIElement
    private let selfBundleId: String?

    private var workspaceObserver: NSObjectProtocol?
    private var accessibilityGranted: Bool = false
    private var currentPid: pid_t?
    private var currentAppElement: AXUIElement?
    private var focusedWindowToken: AXObserverHub.Token?
    private var mainWindowToken: AXObserverHub.Token?
    private var focusedWindowTitleToken: AXObserverHub.Token?
    private var currentFocusedWindowElement: AXUIElement?

    public init(
        hub: AXObserverHub? = nil,
        selfBundleId: String? = Bundle.main.bundleIdentifier,
        onChange: @escaping @MainActor (AppIdentity?, WindowIdentity?) -> Void
    ) {
        self.hub = hub
        self.selfBundleId = selfBundleId
        self.focusedWindowReader = { appElement, app in
            Self.readFocusedWindowSnapshot(appElement: appElement, fallbackTitle: app.name)
        }
        self.appElementFactory = { AXUIElementCreateApplication($0) }
        self.onChange = onChange
    }

    internal init(
        hub: AXObserverHub? = nil,
        selfBundleId: String? = Bundle.main.bundleIdentifier,
        focusedWindowReader: @escaping @MainActor (AXUIElement, AppIdentity) -> FocusedWindowSnapshot?,
        appElementFactory: @escaping @MainActor (pid_t) -> AXUIElement,
        onChange: @escaping @MainActor (AppIdentity?, WindowIdentity?) -> Void
    ) {
        self.hub = hub
        self.selfBundleId = selfBundleId
        self.focusedWindowReader = focusedWindowReader
        self.appElementFactory = appElementFactory
        self.onChange = onChange
    }

    public func start() {
        // Initial read so chip UI is populated before the first activation event.
        applyFrontmost(NSWorkspace.shared.frontmostApplication)

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // Callback is registered with `queue: .main`, so we are
            // already on the main thread when this fires. Use
            // `MainActor.assumeIsolated` instead of `Task { @MainActor }`
            // so back-to-back activations don't interleave inside
            // `applyFrontmost` via two queued Tasks.
            MainActor.assumeIsolated {
                guard let self else { return }
                let runningApp = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                self.applyFrontmost(runningApp)
            }
        }
    }

    public func stop() {
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        workspaceObserver = nil
        detachAX()
        currentPid = nil
        currentAppElement = nil
    }

    /// Push the current accessibility grant state. SenseStore calls this when
    /// PermissionsService publishes a change so AX hookup goes live (or
    /// retreats) without restarting the mirror.
    public func setAccessibilityGranted(_ granted: Bool) {
        guard granted != accessibilityGranted else { return }
        accessibilityGranted = granted
        if granted {
            attachAXForCurrentPid()
            // Re-emit so any consumer sees the AX-resolved window now that
            // we can read it.
            reemitWithCurrentWindow()
        } else {
            detachAX()
            // Re-emit with degraded window — title / windowId from AX no
            // longer reflect reality once we're not subscribed.
            reemitWithCurrentWindow()
        }
    }

    private func applyFrontmost(_ runningApp: NSRunningApplication?) {
        // Self-activation suppression: clicking the notch activates Notch Agent.
        // Drop the event so the user's prior context survives.
        if let bundleId = runningApp?.bundleIdentifier,
           let selfBundleId,
           bundleId == selfBundleId {
            return
        }

        let projection = Self.project(runningApp: runningApp)
        let newApp = projection.app
        let newPid = newApp?.pid

        // App / pid changed → swap AX subscription onto the new app element.
        if newPid != currentPid {
            detachAX()
            currentPid = newPid
            currentAppElement = newPid.map { appElementFactory($0) }
            if accessibilityGranted {
                attachAXForCurrentPid()
            }
        }

        let resolvedWindow = newApp.map { resolveWindow(for: $0) } ?? nil
        self.app = newApp
        self.window = resolvedWindow
        self.onChange(newApp, resolvedWindow)
    }

    /// Re-resolve the focused window for the current app and re-emit. Used
    /// by both the AX focus-change handler and `setAccessibilityGranted` so
    /// every "current state" path goes through one writer.
    private func reemitWithCurrentWindow() {
        guard let currentApp = app else {
            window = nil
            detachFocusedWindowTitleObserver()
            self.onChange(nil, nil)
            return
        }
        let resolvedWindow = resolveWindow(for: currentApp)
        window = resolvedWindow
        self.onChange(currentApp, resolvedWindow)
    }

    /// Try the AX path first; fall back to `(app.name, nil)` if AX isn't
    /// available or the read fails. The fallback matches what the rest of
    /// the system has been displaying since Stage 0, so chips stay coherent
    /// across permission flips.
    private func resolveWindow(for app: AppIdentity) -> WindowIdentity {
        if accessibilityGranted, let appElement = currentAppElement {
            if let snapshot = focusedWindowReader(appElement, app) {
                attachFocusedWindowTitleObserverIfNeeded(to: snapshot.element)
                return snapshot.identity
            }
        }
        detachFocusedWindowTitleObserver()
        return WindowIdentity(title: app.name, windowId: nil)
    }

    // MARK: - AX subscription

    private func attachAXForCurrentPid() {
        guard let hub, let pid = currentPid, let element = currentAppElement else { return }
        focusedWindowToken = hub.subscribe(
            pid: pid,
            element: element,
            notification: kAXFocusedWindowChangedNotification as String,
            handler: { [weak self] in
                self?.reemitWithCurrentWindow()
            }
        )
        mainWindowToken = hub.subscribe(
            pid: pid,
            element: element,
            notification: kAXMainWindowChangedNotification as String,
            handler: { [weak self] in
                self?.reemitWithCurrentWindow()
            }
        )
    }

    private func detachAX() {
        if let hub, let token = focusedWindowToken {
            hub.unsubscribe(token)
        }
        if let hub, let token = mainWindowToken {
            hub.unsubscribe(token)
        }
        focusedWindowToken = nil
        mainWindowToken = nil
        detachFocusedWindowTitleObserver()
    }

    private func attachFocusedWindowTitleObserverIfNeeded(to element: AXUIElement) {
        guard let hub, let pid = currentPid else { return }
        if let currentFocusedWindowElement,
           CFEqual(currentFocusedWindowElement, element) {
            return
        }
        detachFocusedWindowTitleObserver()
        currentFocusedWindowElement = element
        focusedWindowTitleToken = hub.subscribe(
            pid: pid,
            element: element,
            notification: kAXTitleChangedNotification as String,
            handler: { [weak self] in
                self?.reemitWithCurrentWindow()
            }
        )
    }

    private func detachFocusedWindowTitleObserver() {
        if let hub, let token = focusedWindowTitleToken {
            hub.unsubscribe(token)
        }
        focusedWindowTitleToken = nil
        currentFocusedWindowElement = nil
    }

    // MARK: - Static helpers

    /// AX-side window resolution: read the application element's focused
    /// window, then pull title + windowId off it. Returns nil iff the AX
    /// reads fail (window missing, AX dropped, etc.).
    internal nonisolated static func readFocusedWindow(
        appElement: AXUIElement,
        fallbackTitle: String
    ) -> WindowIdentity? {
        readFocusedWindowSnapshot(appElement: appElement, fallbackTitle: fallbackTitle)?.identity
    }

    internal nonisolated static func readFocusedWindowSnapshot(
        appElement: AXUIElement,
        fallbackTitle: String
    ) -> FocusedWindowSnapshot? {
        var focusedRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedRef
        )
        guard err == .success, let value = focusedRef else { return nil }
        guard let windowElement = axElement(from: value) else { return nil }

        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(
            windowElement,
            kAXTitleAttribute as CFString,
            &titleRef
        )
        let title = (titleRef as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackTitle
        let windowId = axWindowID(for: windowElement)
        return FocusedWindowSnapshot(
            element: windowElement,
            identity: WindowIdentity(title: title, windowId: windowId)
        )
    }

    /// Pure projection helper, exposed `internal` so unit tests can cover
    /// the bundleId / localizedName / icon-passthrough rules without
    /// fabricating an `NSRunningApplication`. Always returns the degraded
    /// `(app.name, nil)` window — AX-side resolution is instance-scoped
    /// because it depends on subscription state.
    internal nonisolated static func project(
        runningApp: NSRunningApplication?
    ) -> (app: AppIdentity?, window: WindowIdentity?) {
        guard let runningApp,
              let bundleId = runningApp.bundleIdentifier
        else {
            return (nil, nil)
        }
        let name = runningApp.localizedName ?? bundleId
        let identity = AppIdentity(
            bundleId: bundleId,
            name: name,
            pid: runningApp.processIdentifier,
            icon: runningApp.icon
        )
        let win = WindowIdentity(title: name, windowId: nil)
        return (identity, win)
    }

    /// Test-only entry to drive the writer side without an NSWorkspace event.
    internal func _applyFrontmostForTesting(_ runningApp: NSRunningApplication?) {
        applyFrontmost(runningApp)
    }

    internal func _applyFrontmostForTesting(app: AppIdentity?) {
        let newPid = app?.pid
        if newPid != currentPid {
            detachAX()
            currentPid = newPid
            currentAppElement = newPid.map { appElementFactory($0) }
            if accessibilityGranted {
                attachAXForCurrentPid()
            }
        }
        let resolvedWindow = app.map { resolveWindow(for: $0) } ?? nil
        self.app = app
        self.window = resolvedWindow
        self.onChange(app, resolvedWindow)
    }

    internal func _dispatchFocusedWindowTitleChangedForTesting() {
        reemitWithCurrentWindow()
    }
}

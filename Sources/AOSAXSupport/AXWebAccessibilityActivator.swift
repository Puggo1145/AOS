import ApplicationServices
import Foundation

// MARK: - AXWebAccessibilityActivator
//
// Shared Chromium / Electron accessibility activation primitive. Chromium
// family apps lazily build their web AX tree only after they observe a real
// accessibility client: the two enablement attributes plus a live AXObserver
// source retained on the Shell's main runloop. OS Sense uses this to keep its
// focused-element reads lightweight while still getting the richer tree;
// Computer Use uses the same primitive before its deeper window tree walk.

/// Writes one Accessibility attribute value onto an AX element.
public typealias AXAttributeWriter = @Sendable (AXUIElement, CFString, CFTypeRef) -> AXError

/// Probes whether a root element currently exposes web content.
public typealias AXWebContentProbe = @Sendable (AXUIElement) -> Bool

/// Registers the no-op observer Chromium uses as the "AX client present" signal.
public struct AXWebAccessibilityObserverRegistrar: Sendable {
    private let register: @Sendable (pid_t, AXUIElement) -> AXObserver?

    /// Creates a registrar from a concrete observer registration closure.
    public init(_ register: @escaping @Sendable (pid_t, AXUIElement) -> AXObserver?) {
        self.register = register
    }

    /// Registers and returns an observer that must be retained by the caller.
    public func registerObserver(pid: pid_t, root: AXUIElement) -> AXObserver? {
        register(pid, root)
    }

    /// Production registrar that attaches a no-op AXObserver to the main runloop.
    public static let live = AXWebAccessibilityObserverRegistrar { pid, _ in
        var observer: AXObserver?
        let createResult = AXObserverCreateWithInfoCallback(
            pid, aosAXSupportNoopObserverCallback, &observer
        )
        guard createResult == .success, let observer else { return nil }

        if let source = AXObserverGetRunLoopSource(observer) as CFRunLoopSource? {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }

        let root = AXUIElementCreateApplication(pid)
        for notification in Self.chromiumActivationNotifications {
            _ = addObserverNotificationPreferRemote(
                observer: observer,
                element: root,
                notification: notification as CFString
            )
        }
        return observer
    }

    /// Test registrar that performs no AX work.
    public static let disabledForTesting = AXWebAccessibilityObserverRegistrar { _, _ in nil }

    private static let chromiumActivationNotifications: [String] = [
        kAXFocusedUIElementChangedNotification as String,
        kAXFocusedWindowChangedNotification as String,
        kAXApplicationActivatedNotification as String,
        kAXApplicationDeactivatedNotification as String,
        kAXApplicationHiddenNotification as String,
        kAXApplicationShownNotification as String,
        kAXWindowCreatedNotification as String,
        kAXWindowMovedNotification as String,
        kAXWindowResizedNotification as String,
        kAXValueChangedNotification as String,
        kAXTitleChangedNotification as String,
        kAXSelectedChildrenChangedNotification as String,
        kAXLayoutChangedNotification as String,
    ]
}

/// Enables Chromium / Electron web accessibility without walking the tree.
public actor AXWebAccessibilityActivator {
    private var activatedPids: Set<pid_t> = []
    private var nonActivatableSince: [pid_t: Date] = [:]
    private var observers: [pid_t: AXObserver] = [:]

    private let negativeCacheTTL: TimeInterval
    private let writeAttribute: AXAttributeWriter
    private let observerRegistrar: AXWebAccessibilityObserverRegistrar
    private let webContentProbe: AXWebContentProbe

    /// Creates an activator with injectable AX hooks for deterministic tests.
    public init(
        negativeCacheTTL: TimeInterval = 30,
        writeAttribute: AXAttributeWriter? = nil,
        observerRegistrar: AXWebAccessibilityObserverRegistrar = .live,
        webContentProbe: @escaping AXWebContentProbe = { AXWebAccessibilityActivator.hasWebContent(root: $0) }
    ) {
        self.negativeCacheTTL = negativeCacheTTL
        self.writeAttribute = writeAttribute ?? { element, attribute, value in
            AXUIElementSetAttributeValue(element, attribute, value)
        }
        self.observerRegistrar = observerRegistrar
        self.webContentProbe = webContentProbe
    }

    /// Activates web accessibility for `pid` and returns whether the target accepted the hint.
    @discardableResult
    public func activate(pid: pid_t, root: AXUIElement) async -> Bool {
        guard !isNegativeCached(pid: pid) else { return false }

        let accepted = assertEnablement(pid: pid, root: root)
        guard accepted else { return false }

        if !activatedPids.contains(pid) {
            activatedPids.insert(pid)
            observers[pid] = observerRegistrar.registerObserver(pid: pid, root: root)
            await waitForWebContent(root: root)
        }

        return true
    }

    /// Returns whether `pid` has previously accepted web AX activation.
    public func isActivated(pid: pid_t) -> Bool {
        activatedPids.contains(pid)
    }

    /// Returns whether `pid` is still inside the negative-cache TTL.
    public func isKnownNonActivatable(pid: pid_t) -> Bool {
        isNegativeCached(pid: pid)
    }

    private func assertEnablement(pid: pid_t, root: AXUIElement) -> Bool {
        let manualResult = writeAttribute(
            root, "AXManualAccessibility" as CFString, kCFBooleanTrue
        )
        let enhancedResult = writeAttribute(
            root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue
        )

        if manualResult != .success && enhancedResult != .success {
            if !activatedPids.contains(pid) {
                nonActivatableSince[pid] = Date()
            }
            return activatedPids.contains(pid)
        }

        nonActivatableSince.removeValue(forKey: pid)
        return true
    }

    private func isNegativeCached(pid: pid_t) -> Bool {
        guard let recordedAt = nonActivatableSince[pid] else { return false }
        if Date().timeIntervalSince(recordedAt) >= negativeCacheTTL {
            nonActivatableSince.removeValue(forKey: pid)
            return false
        }
        return true
    }

    private func waitForWebContent(root: AXUIElement) async {
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            if Task.isCancelled { return }
            if webContentProbe(root) { return }
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                return
            }
        }
    }

    /// Returns whether `root` currently exposes an `AXWebArea` descendant.
    public nonisolated static func hasWebContent(root: AXUIElement) -> Bool {
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &windowsRef)
        guard result == .success, let windowsRef,
              CFGetTypeID(windowsRef) == CFArrayGetTypeID()
        else { return false }

        let windows = unsafeDowncast(windowsRef, to: CFArray.self)
        for index in 0..<CFArrayGetCount(windows) {
            guard let raw = CFArrayGetValueAtIndex(windows, index) else { continue }
            let window = Unmanaged<AXUIElement>.fromOpaque(raw).takeUnretainedValue()
            if subtreeHasWebContent(window, depth: 0, maxDepth: 4) { return true }
        }
        return false
    }

    private nonisolated static func subtreeHasWebContent(
        _ element: AXUIElement,
        depth: Int,
        maxDepth: Int
    ) -> Bool {
        if depth > maxDepth { return false }

        var roleRef: CFTypeRef?
        let roleResult = AXUIElementCopyAttributeValue(element, "AXRole" as CFString, &roleRef)
        if roleResult == .success, let role = roleRef as? String, role == "AXWebArea" {
            return true
        }

        var childrenRef: CFTypeRef?
        let childrenResult = AXUIElementCopyAttributeValue(element, "AXChildren" as CFString, &childrenRef)
        guard childrenResult == .success, let childrenRef,
              CFGetTypeID(childrenRef) == CFArrayGetTypeID()
        else { return false }

        let children = unsafeDowncast(childrenRef, to: CFArray.self)
        for index in 0..<CFArrayGetCount(children) {
            guard let raw = CFArrayGetValueAtIndex(children, index) else { continue }
            let child = Unmanaged<AXUIElement>.fromOpaque(raw).takeUnretainedValue()
            if subtreeHasWebContent(child, depth: depth + 1, maxDepth: maxDepth) { return true }
        }
        return false
    }
}

private let aosAXSupportNoopObserverCallback: AXObserverCallbackWithInfo = { _, _, _, _, _ in }

private func addObserverNotificationPreferRemote(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString
) -> AXError {
    if let fn = axObserverAddNotificationAndCheckRemote {
        return fn(observer, element, notification, nil)
    }
    return AXObserverAddNotification(observer, element, notification, nil)
}

private let axObserverAddNotificationAndCheckRemote:
    (@convention(c) (AXObserver, AXUIElement, CFString, UnsafeMutableRawPointer?) -> AXError)? = {
        guard
            let symbol = dlsym(
                UnsafeMutableRawPointer(bitPattern: -2),
                "AXObserverAddNotificationAndCheckRemote"
            )
        else { return nil }
        return unsafeBitCast(
            symbol,
            to: (@convention(c) (AXObserver, AXUIElement, CFString, UnsafeMutableRawPointer?) -> AXError).self
        )
    }()

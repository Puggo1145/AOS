import AOSAXSupport
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - AccessibilitySnapshot
//
// Per `docs/designs/computer-use.md` §"AX 树遍历" and §"Chromium / Electron
// AX 激活". Walks `pid`'s AX tree starting from
// `AXUIElementCreateApplication(pid)`, filters to the target `windowId`'s
// subtree (plus menu bar), assigns monotonic `elementIndex` to every
// actionable node, and hands the index → element map to `StateCache`.
//
// First snapshot per pid runs the Chromium activation routine:
//
//   1. `AXEnablementAssertion.assert(pid, root)` — write
//      AXManualAccessibility / AXEnhancedUserInterface
//   2. Create AXObserver; subscribe to a basket of cheap notifications
//      (callback is no-op — observer existence is the signal)
//   3. Attach observer's run-loop source to `CFRunLoopGetMain()` (Shell's
//      SwiftUI runloop is always spinning — required for Chromium's AX
//      pipeline to stay open between snapshots)
//   4. `CFRunLoopRunInMode(.defaultMode, 0.5, false)` — give Chromium time
//      to build the web AX tree before we walk
//
// Subsequent snapshots skip steps 2-4 (observer reference is retained in
// `accessibilityObservers`) but always re-run step 1 (Chromium resets
// AXEnhancedUserInterface on backgrounding / tab switches).

/// AXUIElement is a CFType safe for the read + perform / set operations
/// we run; Apple hasn't annotated Sendable, conform retroactively.
extension AXUIElement: @retroactive @unchecked Sendable {}
extension AXObserver: @retroactive @unchecked Sendable {}

/// No-op AXObserver callback. The observer's mere existence is what
/// Chromium watches for — we never react to events.
private let aosNoopObserverCallback: AXObserverCallbackWithInfo = { _, _, _, _, _ in }

public struct SnapshotElement: Sendable {
    public let role: String
    public let title: String?
    public let value: String?
    public let description: String?
    public let identifier: String?
    public let help: String?
    public let enabled: Bool?
    public let actions: [String]
    public let depth: Int
    public let elementIndex: Int?
    public let element: AXUIElement
}

/// Result of a walk: the rendered markdown tree + the element-index map
/// the cache stores. The walker fills `elementCount` from the map.
public struct SnapshotResult: Sendable {
    public let treeMarkdown: String
    public let elements: [Int: AXUIElement]
    public var elementCount: Int { elements.count }
}

public enum SnapshotError: Error, CustomStringConvertible, Sendable {
    case notAuthorized
    case appNotFound(pid_t)

    public var description: String {
        switch self {
        case .notAuthorized: return "Accessibility permission not granted."
        case .appNotFound(let pid): return "App with pid \(pid) is not running."
        }
    }
}

public actor AccessibilitySnapshot {
    /// Hard caps from `docs/designs/computer-use.md` §"AX 树遍历":
    ///   - 最多 500 actionable 元素 (maxElements — bounds the
    ///     `elementIndex` map handed to `StateCache`; preserves the wire
    ///     contract on `elementIndex` semantics)
    ///   - 最多 2000 总节点 (maxRenderedNodes — bounds the markdown
    ///     output regardless of how few of those nodes are actionable;
    ///     a static document tree can have thousands of leaves with no
    ///     actions and would otherwise inflate the payload unbounded)
    ///   - 最深 25 层 (maxDepth)
    public static let maxElements: Int = 500
    public static let maxRenderedNodes: Int = 2000
    public static let maxDepth: Int = 25

    private let enablement: AXEnablementAssertion
    private var pumpedPids: Set<pid_t> = []
    /// AXObserver retain map. We never call from this dict — its only
    /// purpose is to keep the observer alive for the process lifetime.
    /// Chromium's "AX client present" detector wants `AXObserver`
    /// existence + active subscription, not callbacks.
    private var observers: [pid_t: AXObserver] = [:]

    public init(enablement: AXEnablementAssertion) {
        self.enablement = enablement
    }

    /// Walk `pid`'s tree, filter to `windowId`'s subtree (plus menu bar),
    /// produce markdown + element-index map. Caller stores the map in
    /// `StateCache`.
    public func walk(pid: pid_t, windowId: CGWindowID) async throws -> SnapshotResult {
        guard AXIsProcessTrusted() else { throw SnapshotError.notAuthorized }
        guard NSRunningApplication(processIdentifier: pid) != nil else {
            throw SnapshotError.appNotFound(pid)
        }

        let root = AXUIElementCreateApplication(pid)
        try await activateAccessibilityIfNeeded(pid: pid, root: root)

        var elements: [Int: AXUIElement] = [:]
        var nextIndex = 0
        var renderedNodes = 0
        var markdown = ""

        renderTree(
            root,
            depth: 0,
            targetWindowId: windowId,
            elements: &elements,
            nextIndex: &nextIndex,
            renderedNodes: &renderedNodes,
            output: &markdown
        )

        return SnapshotResult(treeMarkdown: markdown, elements: elements)
    }

    // MARK: - Chromium activation

    private func activateAccessibilityIfNeeded(pid: pid_t, root: AXUIElement) async throws {
        if pumpedPids.contains(pid) {
            // Already activated — re-write enablement attributes only.
            // Backgrounding / tab switches reset AXEnhancedUserInterface
            // on Chromium; the per-write cost is sub-millisecond.
            _ = await enablement.assert(pid: pid, root: root)
            return
        }
        let accepted = await enablement.assert(pid: pid, root: root)
        guard accepted else { return }  // native Cocoa app — nothing more to do

        pumpedPids.insert(pid)
        registerAccessibilityObserver(pid: pid)
        // Wait for Chromium to build the web AX tree before walking.
        // Previously this was a synchronous 500ms `CFRunLoopRunInMode`
        // call from the actor's executor thread, but the run-loop source
        // is attached to the SHELL'S MAIN runloop (see
        // `registerAccessibilityObserver`); pumping a different runloop
        // doesn't service that source, so the activation completed only
        // by accident (when SwiftUI's main loop happened to spin
        // alongside). Now: yield in short slices so SwiftUI's main loop
        // services the source naturally, and probe the tree each slice
        // — return as soon as web content appears, or after 500ms total.
        await waitForChromiumActivation(pid: pid, root: root)
    }

    /// Up to ~500ms total, polled in 25ms slices. Each slice yields the
    /// actor (so the main runloop is unblocked to service the AX
    /// observer's source) and probes whether the tree now contains a
    /// web-area child. Stops early on success — typical activation
    /// completes in 50-150ms once the source is being serviced.
    ///
    /// Trade-off vs the old sync pump: we never block the actor for
    /// more than 25ms at a time, and we never block the main thread at
    /// all — the SwiftUI shell stays responsive even on first Chrome
    /// snapshot. The cost is up to one extra probe per slice (a single
    /// `AXUIElementCopyAttributeValue` call), negligible.
    private func waitForChromiumActivation(pid: pid_t, root: AXUIElement) async {
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            if Self.hasWebContent(root: root) { return }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    /// Probe: walk one level of `AXWindows` and look for a descendant
    /// whose `AXRole` matches a web-content marker. Cheap (single
    /// attribute read per node, bounded by max windows × first-level
    /// children).
    private nonisolated static func hasWebContent(root: AXUIElement) -> Bool {
        var windowsRef: CFTypeRef?
        let r = AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &windowsRef)
        guard r == .success, let windowsRef,
              CFGetTypeID(windowsRef) == CFArrayGetTypeID()
        else { return false }
        let cfWindows = unsafeDowncast(windowsRef, to: CFArray.self)
        let wcount = CFArrayGetCount(cfWindows)
        for i in 0..<wcount {
            guard let raw = CFArrayGetValueAtIndex(cfWindows, i) else { continue }
            let window = Unmanaged<AXUIElement>.fromOpaque(raw).takeUnretainedValue()
            if subtreeHasWebContent(window, depth: 0, maxDepth: 4) { return true }
        }
        return false
    }

    private nonisolated static func subtreeHasWebContent(
        _ element: AXUIElement, depth: Int, maxDepth: Int
    ) -> Bool {
        if depth > maxDepth { return false }
        var roleRef: CFTypeRef?
        let r = AXUIElementCopyAttributeValue(element, "AXRole" as CFString, &roleRef)
        if r == .success, let role = roleRef as? String {
            // `AXWebArea` is the canonical Chromium / WebKit web content
            // root. `AXScrollArea` alone is too generic (native scroll
            // views match) so we don't accept it as a positive signal.
            if role == "AXWebArea" { return true }
        }
        var childrenRef: CFTypeRef?
        let cr = AXUIElementCopyAttributeValue(element, "AXChildren" as CFString, &childrenRef)
        guard cr == .success, let childrenRef,
              CFGetTypeID(childrenRef) == CFArrayGetTypeID()
        else { return false }
        let cfKids = unsafeDowncast(childrenRef, to: CFArray.self)
        let count = CFArrayGetCount(cfKids)
        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(cfKids, i) else { continue }
            let child = Unmanaged<AXUIElement>.fromOpaque(raw).takeUnretainedValue()
            if subtreeHasWebContent(child, depth: depth + 1, maxDepth: maxDepth) { return true }
        }
        return false
    }

    private func registerAccessibilityObserver(pid: pid_t) {
        var observer: AXObserver?
        let createResult = AXObserverCreateWithInfoCallback(
            pid, aosNoopObserverCallback, &observer
        )
        guard createResult == .success, let observer else { return }

        if let source = AXObserverGetRunLoopSource(observer) as CFRunLoopSource? {
            // Attach to the SHELL'S MAIN runloop. SwiftUI keeps it
            // permanently spinning, which is what Chromium needs for its
            // AX pipeline to stay engaged. Attaching to a transient
            // task runloop collapses Chrome's tree the moment the task
            // ends.
            CFRunLoopAddSource(CFRunLoopGetMain(), source, CFRunLoopMode.defaultMode)
        }

        let root = AXUIElementCreateApplication(pid)
        // Subscribe to a broad set so Chromium's "screen reader-style
        // listener" detector latches on. Failures are expected per-app
        // (some refuse certain notifications) and silently ignored.
        for notification in [
            kAXFocusedUIElementChangedNotification,
            kAXFocusedWindowChangedNotification,
            kAXApplicationActivatedNotification,
            kAXApplicationDeactivatedNotification,
            kAXApplicationHiddenNotification,
            kAXApplicationShownNotification,
            kAXWindowCreatedNotification,
            kAXWindowMovedNotification,
            kAXWindowResizedNotification,
            kAXValueChangedNotification,
            kAXTitleChangedNotification,
            kAXSelectedChildrenChangedNotification,
            kAXLayoutChangedNotification,
        ] {
            _ = addObserverNotificationPreferRemote(
                observer: observer, element: root, notification: notification as CFString
            )
        }
        observers[pid] = observer
    }

    private func addObserverNotificationPreferRemote(
        observer: AXObserver,
        element: AXUIElement,
        notification: CFString
    ) -> AXError {
        if let fn = Self.axObserverAddNotificationAndCheckRemote {
            return fn(observer, element, notification, nil)
        }
        return AXObserverAddNotification(observer, element, notification, nil)
    }

    /// `AXObserverAddNotificationAndCheckRemote` if the symbol resolves
    /// — the private variant ACK's the subscription on the target's AX
    /// server side, which keeps Chromium's renderer-side AX pipeline
    /// alive when the target is backgrounded. Public API is the
    /// fallback on older macOS.
    private static let axObserverAddNotificationAndCheckRemote:
        (@convention(c) (AXObserver, AXUIElement, CFString, UnsafeMutableRawPointer?) -> AXError)? = {
            guard
                let sym = dlsym(
                    UnsafeMutableRawPointer(bitPattern: -2),
                    "AXObserverAddNotificationAndCheckRemote"
                )
            else { return nil }
            return unsafeBitCast(
                sym,
                to: (@convention(c) (AXObserver, AXUIElement, CFString, UnsafeMutableRawPointer?) -> AXError).self
            )
        }()

    // MARK: - Tree walk

    private func renderTree(
        _ element: AXUIElement,
        depth: Int,
        targetWindowId: CGWindowID,
        elements: inout [Int: AXUIElement],
        nextIndex: inout Int,
        renderedNodes: inout Int,
        output: inout String
    ) {
        guard depth <= Self.maxDepth else { return }
        // Two independent caps: actionable elements (preserves
        // elementIndex semantics — model can address up to maxElements
        // distinct interactive targets) and total rendered nodes
        // (bounds payload size regardless of how few are actionable).
        guard elements.count < Self.maxElements else { return }
        guard renderedNodes < Self.maxRenderedNodes else { return }
        renderedNodes += 1

        let role = Self.attributeString(element, "AXRole") ?? "?"
        let subrole = Self.attributeString(element, "AXSubrole")
        let title = Self.attributeString(element, "AXTitle")
        let value = Self.attributeString(element, "AXValue")
        let description = Self.attributeString(element, "AXDescription")
        let identifier = Self.attributeString(element, "AXIdentifier")
        let help = Self.attributeString(element, "AXHelp")
        let enabled = Self.attributeBool(element, "AXEnabled")
        let actions = Self.actionNames(of: element)

        let interactive = !actions.isEmpty
        var assignedIndex: Int? = nil
        if interactive {
            assignedIndex = nextIndex
            elements[nextIndex] = element
            nextIndex += 1
        }

        let line = TreeRenderer.renderLine(
            depth: depth,
            elementIndex: assignedIndex,
            role: role,
            subrole: subrole,
            title: title,
            value: value,
            description: description,
            identifier: identifier,
            help: help,
            enabled: enabled,
            actions: actions
        )
        output += line + "\n"

        // Skip closed AXMenu subtrees — every menu bar lists every Recent
        // Item macOS has ever seen, which would inflate the tree 10-100x.
        // Open menus (just AXPick'd) DO get walked so AXMenuItem children
        // pick up element indices.
        if role == "AXMenu" && !Self.isMenuOpen(element) { return }

        var kids = (depth == 0 && role == "AXApplication")
            ? topLevelChildren(of: element)
            : Self.children(of: element)

        // At app root, filter AXWindow children to only the target window
        // (keep non-window children: menu bar, etc).
        if depth == 0 && role == "AXApplication" {
            kids = kids.filter { child in
                let childRole = Self.attributeString(child, "AXRole")
                guard childRole == "AXWindow" else { return true }
                guard let cgWindowId = axWindowID(for: child) else {
                    // Couldn't resolve the CGWindowID — keep it rather than
                    // silently dropping a window we can't classify.
                    return true
                }
                return cgWindowId == targetWindowId
            }
        }

        for child in kids {
            renderTree(
                child,
                depth: depth + 1,
                targetWindowId: targetWindowId,
                elements: &elements,
                nextIndex: &nextIndex,
                renderedNodes: &renderedNodes,
                output: &output
            )
        }
    }

    /// Union `AXChildren` ∪ `AXWindows` on the app root. `AXChildren`
    /// drops windows when the app isn't frontmost; `AXWindows` exposes
    /// them but omits the menu bar. Need both.
    private func topLevelChildren(of appRoot: AXUIElement) -> [AXUIElement] {
        let fromChildren = Self.children(of: appRoot)
        let fromWindows = Self.windows(of: appRoot)
        var out = fromChildren
        for window in fromWindows where !out.contains(where: { CFEqual($0, window) }) {
            out.append(window)
        }
        return out
    }

    // MARK: - Static AX helpers

    private static func windows(of appRoot: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appRoot, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let array = value,
              CFGetTypeID(array) == CFArrayGetTypeID()
        else { return [] }
        let cfArray = unsafeDowncast(array, to: CFArray.self)
        let count = CFArrayGetCount(cfArray)
        var out: [AXUIElement] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            if let raw = CFArrayGetValueAtIndex(cfArray, i) {
                let element = Unmanaged<AXUIElement>.fromOpaque(raw).takeUnretainedValue()
                out.append(element)
            }
        }
        return out
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, "AXChildren" as CFString, &value)
        guard result == .success, let array = value,
              CFGetTypeID(array) == CFArrayGetTypeID()
        else { return [] }
        let cfArray = unsafeDowncast(array, to: CFArray.self)
        let count = CFArrayGetCount(cfArray)
        var out: [AXUIElement] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            if let raw = CFArrayGetValueAtIndex(cfArray, i) {
                let element = Unmanaged<AXUIElement>.fromOpaque(raw).takeUnretainedValue()
                out.append(element)
            }
        }
        return out
    }

    private static func isMenuOpen(_ menu: AXUIElement) -> Bool {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(menu, "AXVisibleChildren" as CFString, &value)
        guard result == .success, let array = value,
              CFGetTypeID(array) == CFArrayGetTypeID()
        else { return false }
        return CFArrayGetCount(unsafeDowncast(array, to: CFArray.self)) > 0
    }

    private static func attributeString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? String
    }

    private static func attributeBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let v = value else { return nil }
        if CFGetTypeID(v) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((v as! CFBoolean))
        }
        return nil
    }

    private static func actionNames(of element: AXUIElement) -> [String] {
        var names: CFArray?
        let result = AXUIElementCopyActionNames(element, &names)
        guard result == .success, let names = names as? [String] else { return [] }
        return names.map(cleanActionName)
    }

    /// Standard AX actions arrive as `AXPress`; custom actions registered
    /// via `NSAccessibilityCustomAction` sometimes serialize as a multi-
    /// line dump (`Name:Copy\nTarget:0x0\nSelector:(null)`). Extract the
    /// `Name:` value to keep the tree compact.
    private static func cleanActionName(_ raw: String) -> String {
        if raw.hasPrefix("AX") { return raw }
        for line in raw.split(whereSeparator: \.isNewline) {
            if let range = line.range(of: "Name:") {
                let name = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { return name }
            }
        }
        return raw
    }
}

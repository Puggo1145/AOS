import AXSupport
import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

struct AXElementEventPoster: Sendable {
    typealias CopyAttribute = @Sendable (AXUIElement, CFString, UnsafeMutablePointer<CFTypeRef?>) -> AXError
    typealias SetAttribute = @Sendable (AXUIElement, CFString, CFTypeRef) -> AXError
    typealias CopyActionNames = @Sendable (AXUIElement, UnsafeMutablePointer<CFArray?>) -> AXError
    typealias PerformAction = @Sendable (AXUIElement, CFString) -> AXError
    typealias IsProcessTrusted = @Sendable () -> Bool
    typealias FrontmostApplicationPID = @Sendable () -> pid_t?
    typealias IsApplicationActive = @Sendable (pid_t) -> Bool
    typealias Sleep = @Sendable (UInt64) async throws -> Void

    private let webAccessibilityActivator: AXWebAccessibilityActivator
    private let copyAttribute: CopyAttribute
    private let setAttribute: SetAttribute
    private let copyActionNames: CopyActionNames
    private let performAction: PerformAction
    private let isProcessTrusted: IsProcessTrusted
    private let focusStealSuppression: AXFocusStealSuppression
    private let frontmostApplicationPID: FrontmostApplicationPID
    private let isApplicationActive: IsApplicationActive
    private let sleepAfterAXAction: Sleep

    init(
        webAccessibilityActivator: AXWebAccessibilityActivator,
        copyAttribute: @escaping CopyAttribute = { element, attribute, value in
            AXUIElementCopyAttributeValue(element, attribute, value)
        },
        setAttribute: @escaping SetAttribute = { element, attribute, value in
            AXUIElementSetAttributeValue(element, attribute, value)
        },
        copyActionNames: @escaping CopyActionNames = { element, names in
            AXUIElementCopyActionNames(element, names)
        },
        performAction: @escaping PerformAction = { element, action in
            AXUIElementPerformAction(element, action)
        },
        isProcessTrusted: @escaping IsProcessTrusted = {
            AXIsProcessTrusted()
        },
        focusStealSuppression: AXFocusStealSuppression = .live(),
        frontmostApplicationPID: @escaping FrontmostApplicationPID = {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        },
        isApplicationActive: @escaping IsApplicationActive = { pid in
            NSRunningApplication(processIdentifier: pid)?.isActive ?? false
        },
        sleepAfterAXAction: @escaping Sleep = { delay in
            try await Task.sleep(nanoseconds: delay)
        }
    ) {
        self.webAccessibilityActivator = webAccessibilityActivator
        self.copyAttribute = copyAttribute
        self.setAttribute = setAttribute
        self.copyActionNames = copyActionNames
        self.performAction = performAction
        self.isProcessTrusted = isProcessTrusted
        self.focusStealSuppression = focusStealSuppression
        self.frontmostApplicationPID = frontmostApplicationPID
        self.isApplicationActive = isApplicationActive
        self.sleepAfterAXAction = sleepAfterAXAction
    }

    func post(_ event: AXElementEvent, to target: AXElementEventTarget) async throws {
        guard isProcessTrusted() else {
            throw ComputerUseError.axElementEventUnavailable("Accessibility permission not granted")
        }

        let root = AXUIElementCreateApplication(target.pid)
        await webAccessibilityActivator.activate(pid: target.pid, root: root)

        try await withReactiveFocusStealSuppression(pid: target.pid) {
            switch event {
            case .focus:
                setFocusState(window: enclosingWindow(of: target.element), element: target.element, focused: true)
            case .action(let action):
                try await withSyntheticFocus(element: target.element) {
                    try performRequiredAction(action.axActionName, on: target.element)
                }
            case .setValue(let value):
                try await withSyntheticFocus(element: target.element) {
                    try setRequiredAttribute("AXValue", on: target.element, value: value as CFTypeRef)
                }
            case .setSelectedText(let text):
                try await withSyntheticFocus(element: target.element) {
                    try setRequiredAttribute("AXSelectedText", on: target.element, value: text as CFTypeRef)
                }
            case .scroll(let direction, let pages):
                try validateScrollPages(pages)
                try await withSyntheticFocus(element: target.element) {
                    try scroll(target.element, direction: direction, pages: pages)
                }
            }
        }
    }

    private func withReactiveFocusStealSuppression<T: Sendable>(
        pid: pid_t,
        body: @Sendable () async throws -> T
    ) async throws -> T {
        var handle: AXFocusSuppressionHandle?
        if !isApplicationActive(pid),
           let restorePid = frontmostApplicationPID(),
           restorePid != pid {
            handle = await focusStealSuppression.begin(pid, restorePid)
        }

        do {
            let result = try await body()
            if let handle {
                try? await sleepAfterAXAction(50_000_000)
                await focusStealSuppression.end(handle)
            }
            return result
        } catch {
            if let handle {
                await focusStealSuppression.end(handle)
            }
            throw error
        }
    }

    private func withSyntheticFocus<T: Sendable>(
        element: AXUIElement,
        body: @Sendable () async throws -> T
    ) async throws -> T {
        let window = enclosingWindow(of: element)
        if readBool(window, "AXMinimized") == true {
            return try await body()
        }

        let priorWindowFocused = readBool(window, "AXFocused")
        let priorWindowMain = readBool(window, "AXMain")
        let priorElementFocused = readBool(element, "AXFocused")

        setFocusState(window: window, element: element, focused: true)
        do {
            let result = try await body()
            restoreFocusState(
                window: window,
                element: element,
                windowFocused: priorWindowFocused,
                windowMain: priorWindowMain,
                elementFocused: priorElementFocused
            )
            return result
        } catch {
            restoreFocusState(
                window: window,
                element: element,
                windowFocused: priorWindowFocused,
                windowMain: priorWindowMain,
                elementFocused: priorElementFocused
            )
            throw error
        }
    }

    private func scroll(_ element: AXUIElement, direction: AXScrollDirection, pages: Double) throws {
        let actions = advertisedActionNames(of: element)
        if let action = scrollAction(direction: direction, advertisedActions: actions) {
            let count = max(1, Int(ceil(pages)))
            for _ in 0..<count {
                try performRequiredAction(action, on: element)
            }
            return
        }

        let scrollBars = scrollBars(for: element, direction: direction)
        guard !scrollBars.isEmpty else {
            throw ComputerUseError.axElementEventUnavailable(
                "element does not advertise a \(direction.rawValue) scroll action or expose a scroll bar"
            )
        }

        for scrollBar in scrollBars {
            guard let range = scrollBarRange(scrollBar) else { continue }
            try writeScrollBar(scrollBar, range: range, direction: direction, pages: pages)
            return
        }

        for scrollBar in scrollBars {
            guard let range = normalizedScrollBarRange(scrollBar) else { continue }
            try writeScrollBar(scrollBar, range: range, direction: direction, pages: pages)
            return
        }

        throw ComputerUseError.axElementEventUnavailable(
            "element exposes scroll bars, but none have a valid min/max range or numeric AXValue"
        )
    }

    private func scrollAction(
        direction: AXScrollDirection,
        advertisedActions: [String]
    ) -> String? {
        let candidates: [String]
        switch direction {
        case .up:
            candidates = ["AXScrollUpByPage", "Scroll Up", "scroll up"]
        case .down:
            candidates = ["AXScrollDownByPage", "Scroll Down", "scroll down"]
        case .left:
            candidates = ["AXScrollLeftByPage", "Scroll Left", "scroll left"]
        case .right:
            candidates = ["AXScrollRightByPage", "Scroll Right", "scroll right"]
        }
        for candidate in candidates {
            if let action = advertisedActions.first(where: { $0 == candidate }) {
                return action
            }
        }
        let directionToken = direction.rawValue
        return advertisedActions.first { action in
            let lower = action.lowercased()
            return lower.contains("scroll") && lower.contains(directionToken)
        }
    }

    private func writeScrollBar(
        _ scrollBar: AXUIElement,
        range: (current: Double, min: Double, max: Double),
        direction: AXScrollDirection,
        pages: Double
    ) throws {
        let sign: Double
        switch direction {
        case .down, .right: sign = 1
        case .up, .left: sign = -1
        }
        let delta = sign * pages * (range.max - range.min)
        let next = Swift.max(range.min, Swift.min(range.max, range.current + delta))
        try setRequiredAttribute("AXValue", on: scrollBar, value: next as CFTypeRef)
    }

    private func scrollBarRange(_ scrollBar: AXUIElement) -> (current: Double, min: Double, max: Double)? {
        guard let current = readDouble(scrollBar, "AXValue"),
              let min = readDouble(scrollBar, "AXMinValue"),
              let max = readDouble(scrollBar, "AXMaxValue"),
              max > min
        else {
            return nil
        }
        return (current: current, min: min, max: max)
    }

    private func normalizedScrollBarRange(_ scrollBar: AXUIElement) -> (current: Double, min: Double, max: Double)? {
        guard let current = readDouble(scrollBar, "AXValue") else { return nil }
        return (current: current, min: 0, max: 1)
    }

    private func scrollBars(for element: AXUIElement, direction: AXScrollDirection) -> [AXUIElement] {
        var current: AXUIElement? = element
        var scrollBars: [AXUIElement] = []
        for _ in 0..<12 {
            guard let node = current else { return scrollBars }
            if role(of: node) == "AXScrollBar", scrollBarMatches(node, direction: direction) {
                appendUnique(node, to: &scrollBars)
            }
            let attribute = (direction == .up || direction == .down)
                ? "AXVerticalScrollBar"
                : "AXHorizontalScrollBar"
            if let direct = axElementAttribute(node, attribute), scrollBarMatches(direct, direction: direction) {
                appendUnique(direct, to: &scrollBars)
            }
            for child in children(of: node)
                where role(of: child) == "AXScrollBar" && scrollBarMatches(child, direction: direction) {
                appendUnique(child, to: &scrollBars)
            }
            current = axElementAttribute(node, "AXParent")
        }
        return scrollBars
    }

    private func appendUnique(_ element: AXUIElement, to elements: inout [AXUIElement]) {
        guard elements.contains(where: { CFEqual($0, element) }) == false else { return }
        elements.append(element)
    }

    private func scrollBarMatches(_ element: AXUIElement, direction: AXScrollDirection) -> Bool {
        guard let orientation = readString(element, "AXOrientation") else { return true }
        switch direction {
        case .up, .down:
            return orientation == "AXVerticalOrientation"
        case .left, .right:
            return orientation == "AXHorizontalOrientation"
        }
    }

    private func validateScrollPages(_ pages: Double) throws {
        guard pages.isFinite, pages > 0 else {
            throw ComputerUseError.axElementEventUnavailable("scroll pages must be finite and greater than 0")
        }
    }

    private func performRequiredAction(_ action: String, on element: AXUIElement) throws {
        let result = performAction(element, action as CFString)
        guard result == .success else {
            throw ComputerUseError.axElementEventUnavailable(
                "AX action \(action) failed with code \(result.rawValue)"
            )
        }
    }

    private func setRequiredAttribute(_ attribute: String, on element: AXUIElement, value: CFTypeRef) throws {
        let result = setAttribute(element, attribute as CFString, value)
        guard result == .success else {
            throw ComputerUseError.axElementEventUnavailable(
                "AX setAttribute \(attribute) failed with code \(result.rawValue)"
            )
        }
    }

    private func setFocusState(window: AXUIElement?, element: AXUIElement, focused: Bool) {
        let value = (focused ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef
        if let window {
            _ = setAttribute(window, "AXFocused" as CFString, value)
            _ = setAttribute(window, "AXMain" as CFString, value)
        }
        _ = setAttribute(element, "AXFocused" as CFString, value)
    }

    private func restoreFocusState(
        window: AXUIElement?,
        element: AXUIElement,
        windowFocused: Bool?,
        windowMain: Bool?,
        elementFocused: Bool?
    ) {
        if let window {
            if let windowFocused {
                _ = setAttribute(window, "AXFocused" as CFString, boolRef(windowFocused))
            }
            if let windowMain {
                _ = setAttribute(window, "AXMain" as CFString, boolRef(windowMain))
            }
        }
        if let elementFocused {
            _ = setAttribute(element, "AXFocused" as CFString, boolRef(elementFocused))
        }
    }

    private func enclosingWindow(of element: AXUIElement) -> AXUIElement? {
        axElementAttribute(element, "AXWindow")
    }

    private func advertisedActionNames(of element: AXUIElement) -> [String] {
        var names: CFArray?
        let result = copyActionNames(element, &names)
        guard result == .success, let names = names as? [String] else { return [] }
        return names
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        let result = copyAttribute(element, "AXChildren" as CFString, &value)
        guard result == .success, let array = value,
              CFGetTypeID(array) == CFArrayGetTypeID()
        else { return [] }
        let cfArray = unsafeDowncast(array, to: CFArray.self)
        let count = CFArrayGetCount(cfArray)
        var out: [AXUIElement] = []
        out.reserveCapacity(count)
        for index in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(cfArray, index) else { continue }
            out.append(Unmanaged<AXUIElement>.fromOpaque(raw).takeUnretainedValue())
        }
        return out
    }

    private func axElementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        let result = copyAttribute(element, attribute as CFString, &value)
        guard result == .success, let value else { return nil }
        return axElement(from: value)
    }

    private func role(of element: AXUIElement) -> String? {
        readString(element, "AXRole")
    }

    private func readString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        let result = copyAttribute(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? String
    }

    private func readBool(_ element: AXUIElement?, _ attribute: String) -> Bool? {
        guard let element else { return nil }
        var value: CFTypeRef?
        let result = copyAttribute(element, attribute as CFString, &value)
        guard result == .success, let value else { return nil }
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((value as! CFBoolean))
        }
        return nil
    }

    private func readDouble(_ element: AXUIElement, _ attribute: String) -> Double? {
        var value: CFTypeRef?
        let result = copyAttribute(element, attribute as CFString, &value)
        guard result == .success, let value else { return nil }
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string)
        }
        return nil
    }

    private func boolRef(_ value: Bool) -> CFTypeRef {
        (value ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef
    }
}

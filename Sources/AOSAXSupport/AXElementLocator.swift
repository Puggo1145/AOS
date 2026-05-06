import ApplicationServices
import CoreGraphics
import CryptoKit
import Foundation

// MARK: - AXElementLocator
//
// Shared locator signature used by OS Sense and Computer Use to describe the
// same AX element across two independently-timed snapshots. This is not a
// durable OS handle: it is a deterministic fingerprint over stable app/window
// identity, the element's ancestor path, sibling ordinal, and attributes.
// Volatile metadata such as window title and frame intentionally stays out of
// the hash so title edits or window moves do not break context ↔ app-state
// correlation. Consumers still resolve it against a fresh app-state snapshot
// before issuing operations.

public struct AXElementLocator: Equatable, Sendable {
    public struct PathComponent: Equatable, Sendable {
        public let role: String
        public let subrole: String?
        public let identifier: String?
        public let title: String?
        public let description: String?
        public let siblingOrdinal: Int?

        public init(
            role: String,
            subrole: String? = nil,
            identifier: String? = nil,
            title: String? = nil,
            description: String? = nil,
            siblingOrdinal: Int? = nil
        ) {
            self.role = role
            self.subrole = Self.nonEmpty(subrole)
            self.identifier = Self.nonEmpty(identifier)
            self.title = Self.nonEmpty(title)
            self.description = Self.nonEmpty(description)
            self.siblingOrdinal = siblingOrdinal
        }

        fileprivate var canonical: String {
            [
                "role=\(role)",
                "subrole=\(subrole ?? "")",
                "identifier=\(identifier ?? "")",
                "title=\(title ?? "")",
                "description=\(description ?? "")",
                "siblingOrdinal=\(siblingOrdinal.map(String.init) ?? "")",
            ].joined(separator: "\u{1F}")
        }

        private static func nonEmpty(_ value: String?) -> String? {
            guard let value, !value.isEmpty else { return nil }
            return value
        }
    }

    public struct Frame: Equatable, Sendable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public let pid: pid_t
    public let bundleId: String?
    public let windowId: CGWindowID?
    public let windowTitle: String?
    public let pathFromWindow: [PathComponent]
    public let frame: Frame?

    public init(
        pid: pid_t,
        bundleId: String? = nil,
        windowId: CGWindowID? = nil,
        windowTitle: String? = nil,
        pathFromWindow: [PathComponent],
        frame: Frame? = nil
    ) {
        self.pid = pid
        self.bundleId = Self.nonEmpty(bundleId)
        self.windowId = windowId
        self.windowTitle = Self.nonEmpty(windowTitle)
        self.pathFromWindow = pathFromWindow
        self.frame = frame
    }

    public var locatorId: String {
        let digest = SHA256.hash(data: Data(canonical.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "axloc_" + hex.prefix(20)
    }

    private var canonical: String {
        [
            "pid=\(pid)",
            "bundleId=\(bundleId ?? "")",
            "windowId=\(windowId.map(String.init) ?? "")",
            "path=\(pathFromWindow.map(\.canonical).joined(separator: "\u{1E}"))",
        ].joined(separator: "\u{1D}")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

public enum AXElementLocatorReader {
    public static let maxAncestorDepth = 25

    public static func locate(
        element: AXUIElement,
        pid: pid_t,
        bundleId: String? = nil,
        windowId explicitWindowId: CGWindowID? = nil,
        windowTitle explicitWindowTitle: String? = nil
    ) -> AXElementLocator {
        var components: [AXElementLocator.PathComponent] = []
        var current: AXUIElement? = element
        var windowElement: AXUIElement?

        for _ in 0..<maxAncestorDepth {
            guard let node = current else { break }
            let role = attributeString(node, "AXRole") ?? "AXUnknown"
            if role == "AXWindow" {
                windowElement = node
                break
            }
            components.append(pathComponent(for: node, role: role))
            current = parent(of: node)
        }

        let resolvedWindow = windowElement ?? window(of: element)
        let windowId = explicitWindowId ?? resolvedWindow.flatMap { axWindowID(for: $0) }
        let windowTitle = explicitWindowTitle ?? resolvedWindow.flatMap { attributeString($0, "AXTitle") }

        return AXElementLocator(
            pid: pid,
            bundleId: bundleId,
            windowId: windowId,
            windowTitle: windowTitle,
            pathFromWindow: components.reversed(),
            frame: frame(of: element)
        )
    }

    private static func pathComponent(
        for element: AXUIElement,
        role: String
    ) -> AXElementLocator.PathComponent {
        let subrole = attributeString(element, "AXSubrole")
        let identifier = attributeString(element, "AXIdentifier")
        let title = attributeString(element, "AXTitle")
        let description = attributeString(element, "AXDescription")
        let ordinal = siblingOrdinal(
            of: element,
            role: role,
            subrole: subrole,
            identifier: identifier,
            title: title,
            description: description
        )

        return AXElementLocator.PathComponent(
            role: role,
            subrole: subrole,
            identifier: identifier,
            title: title,
            description: description,
            siblingOrdinal: ordinal
        )
    }

    private static func siblingOrdinal(
        of element: AXUIElement,
        role: String,
        subrole: String?,
        identifier: String?,
        title: String?,
        description: String?
    ) -> Int? {
        guard let parent = parent(of: element) else { return nil }
        let children = children(of: parent)
        var ordinal = 0
        for child in children {
            guard attributeString(child, "AXRole") == role,
                  attributeString(child, "AXSubrole") == subrole,
                  attributeString(child, "AXIdentifier") == identifier,
                  attributeString(child, "AXTitle") == title,
                  attributeString(child, "AXDescription") == description
            else { continue }

            if CFEqual(child, element) {
                return ordinal
            }
            ordinal += 1
        }
        return nil
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, "AXParent" as CFString, &value)
        guard result == .success, let value else { return nil }
        return axElement(from: value)
    }

    private static func window(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, "AXWindow" as CFString, &value)
        guard result == .success, let value else { return nil }
        return axElement(from: value)
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, "AXChildren" as CFString, &value)
        guard result == .success, let value,
              CFGetTypeID(value) == CFArrayGetTypeID()
        else { return [] }
        let array = unsafeDowncast(value, to: CFArray.self)
        let count = CFArrayGetCount(array)
        var out: [AXUIElement] = []
        out.reserveCapacity(count)
        for index in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(array, index) else { continue }
            out.append(Unmanaged<AXUIElement>.fromOpaque(raw).takeUnretainedValue())
        }
        return out
    }

    private static func attributeString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    private static func frame(of element: AXUIElement) -> AXElementLocator.Frame? {
        guard let point = cgPointAttribute(element, "AXPosition"),
              let size = cgSizeAttribute(element, "AXSize")
        else { return nil }
        return AXElementLocator.Frame(
            x: point.x,
            y: point.y,
            width: size.width,
            height: size.height
        )
    }

    private static func cgPointAttribute(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func cgSizeAttribute(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgSize else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }
}

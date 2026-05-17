import AXSupport
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
// rendered node, and hands the index → element map to `StateCache`.
//
// Before walking, calls `AXWebAccessibilityActivator` from AXSupport so
// Chromium / Electron apps expose their richer web AX tree. The activator owns
// enablement attribute writes, no-op observer retention, and readiness waiting;
// this module owns only Computer Use's deep window walk.

// `AXUIElement` / `AXObserver` retroactive `Sendable` conformance lives in
// `AXSupport` (the only module both kits depend on) so there is exactly
// one declaration in the linked binary.

struct SnapshotElement: Sendable {
    public let role: String
    public let title: String?
    public let value: String?
    public let description: String?
    public let identifier: String?
    public let help: String?
    public let placeholder: String?
    public let enabled: Bool?
    public let selected: Bool?
    public let valueSettable: Bool
    public let actions: [String]
    public let depth: Int
    public let elementIndex: Int?
    public let element: AXUIElement
}

/// Result of a walk: the rendered markdown tree + the element-index map
/// the cache stores. The walker fills `elementCount` from the map.
struct SnapshotResult: Sendable {
    public let treeMarkdown: String
    public let elements: [Int: AXUIElement]
    public var elementCount: Int { elements.count }
}

enum SnapshotError: Error, CustomStringConvertible, Sendable {
    case notAuthorized
    case appNotFound(pid_t)

    public var description: String {
        switch self {
        case .notAuthorized: return "Accessibility permission not granted."
        case .appNotFound(let pid): return "App with pid \(pid) is not running."
        }
    }
}

actor AccessibilitySnapshot {
    /// Hard caps from `docs/designs/computer-use.md` §"AX 树遍历":
    ///   - 最多 500 addressable rendered elements (maxElements — bounds the
    ///     `elementIndex` map handed to `StateCache`)
    ///   - 最多 2000 总节点 (maxRenderedNodes — bounds the markdown
    ///     output regardless of how few of those nodes are actionable;
    ///     a static document tree can have thousands of leaves with no
    ///     actions and would otherwise inflate the payload unbounded)
    ///   - 最深 25 层 (maxDepth)
    public static let maxElements: Int = 500
    public static let maxRenderedNodes: Int = 2000
    public static let maxDepth: Int = 25

    private let webAccessibilityActivator: AXWebAccessibilityActivator

    private struct NodeAttributes {
        let role: String
        let subrole: String?
        let title: String?
        let value: String?
        let description: String?
        let identifier: String?
        let help: String?
        let placeholder: String?
        let enabled: Bool?
        let selected: Bool?
        let valueSettable: Bool
        let actions: [String]
    }

    public init(webAccessibilityActivator: AXWebAccessibilityActivator) {
        self.webAccessibilityActivator = webAccessibilityActivator
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
        await webAccessibilityActivator.activate(pid: pid, root: root)

        var elements: [Int: AXUIElement] = [:]
        var nextIndex = 0
        var renderedNodes = 0
        var markdown = ""

        for childElement in topLevelChildren(of: root) {
            guard elements.count < Self.maxElements else { break }
            guard renderedNodes < Self.maxRenderedNodes else { break }
            let childAttributes = Self.readNodeAttributes(childElement)
            if childAttributes.role == "AXWindow" {
                if let cgWindowId = axWindowID(for: childElement) {
                    guard cgWindowId == windowId else { continue }
                }
            }
            renderTree(
                childElement,
                depth: 0,
                attributes: childAttributes,
                elements: &elements,
                nextIndex: &nextIndex,
                renderedNodes: &renderedNodes,
                output: &markdown
            )
        }

        return SnapshotResult(treeMarkdown: markdown, elements: elements)
    }

    // MARK: - Tree walk

    private func renderTree(
        _ element: AXUIElement,
        depth: Int,
        attributes initialAttributes: NodeAttributes?,
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

        let attributes = initialAttributes ?? Self.readNodeAttributes(element)

        let assignedIndex = nextIndex
        elements[nextIndex] = element
        nextIndex += 1

        let line = TreeRenderer.renderLine(
            depth: depth,
            elementIndex: assignedIndex,
            role: attributes.role,
            subrole: attributes.subrole,
            title: attributes.title,
            value: attributes.value,
            description: attributes.description,
            identifier: attributes.identifier,
            help: attributes.help,
            placeholder: attributes.placeholder,
            enabled: attributes.enabled,
            selected: attributes.selected,
            valueSettable: attributes.valueSettable,
            actions: attributes.actions
        )
        output += line + "\n"

        // Skip closed AXMenu subtrees — every menu bar lists every Recent
        // Item macOS has ever seen, which would inflate the tree 10-100x.
        // Open menus (just AXPick'd) DO get walked so AXMenuItem children
        // pick up element indices.
        if attributes.role == "AXMenu" && !Self.isMenuOpen(element) { return }

        let kids = Self.children(of: element)
        let collapsedStaticTextOffsets = renderCollapsedStaticTextChildren(
            kids,
            parentDepth: depth,
            elements: &elements,
            nextIndex: &nextIndex,
            renderedNodes: &renderedNodes,
            output: &output
        )

        for (childOffset, childElement) in kids.enumerated() {
            if collapsedStaticTextOffsets.contains(childOffset) { continue }
            guard elements.count < Self.maxElements else { break }
            guard renderedNodes < Self.maxRenderedNodes else { break }

            let childAttributes = Self.readNodeAttributes(childElement)
            if childAttributes.role == "AXMenu" && !Self.isMenuOpen(childElement) {
                continue
            }
            renderTree(
                childElement,
                depth: depth + 1,
                attributes: childAttributes,
                elements: &elements,
                nextIndex: &nextIndex,
                renderedNodes: &renderedNodes,
                output: &output
            )
        }
    }

    private func renderCollapsedStaticTextChildren(
        _ children: [AXUIElement],
        parentDepth: Int,
        elements: inout [Int: AXUIElement],
        nextIndex: inout Int,
        renderedNodes: inout Int,
        output: inout String
    ) -> Set<Int> {
        let textChildren = children.enumerated().compactMap { offset, child -> (Int, AXUIElement, NodeAttributes)? in
            let attributes = Self.readNodeAttributes(child)
            guard attributes.role == "AXStaticText" else { return nil }
            return (offset, child, attributes)
        }
        guard textChildren.count >= 3 else { return [] }
        let combined = textChildren
            .compactMap { Self.primaryText(from: $0.2) }
            .joined(separator: " ")
        guard !combined.isEmpty else { return [] }
        let collapsedOffsets = Set(textChildren.map(\.0))
        guard elements.count < Self.maxElements else { return collapsedOffsets }
        guard renderedNodes < Self.maxRenderedNodes else { return collapsedOffsets }

        let firstText = textChildren[0].1
        let assignedIndex = nextIndex
        elements[assignedIndex] = firstText
        nextIndex += 1
        renderedNodes += 1
        output += TreeRenderer.renderLine(
            depth: parentDepth + 1,
            elementIndex: assignedIndex,
            role: "AXStaticText",
            subrole: nil,
            title: nil,
            value: combined,
            description: nil,
            identifier: nil,
            help: nil,
            placeholder: nil,
            enabled: true,
            selected: nil,
            valueSettable: false,
            actions: []
        ) + "\n"
        return collapsedOffsets
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

    private static func readNodeAttributes(_ element: AXUIElement) -> NodeAttributes {
        NodeAttributes(
            role: attributeString(element, "AXRole") ?? "?",
            subrole: attributeString(element, "AXSubrole"),
            title: attributeString(element, "AXTitle"),
            value: attributeString(element, "AXValue"),
            description: attributeString(element, "AXDescription"),
            identifier: attributeString(element, "AXIdentifier"),
            help: attributeString(element, "AXHelp"),
            placeholder: attributeString(element, "AXPlaceholderValue"),
            enabled: attributeBool(element, "AXEnabled"),
            selected: attributeBool(element, "AXSelected"),
            valueSettable: attributeSettable(element, "AXValue"),
            actions: actionNames(of: element)
        )
    }

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

    private static func attributeSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        guard result == .success else { return false }
        return settable.boolValue
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

    private static func primaryText(from attributes: NodeAttributes) -> String? {
        if let title = attributes.title, !title.isEmpty { return title }
        if let value = attributes.value, !value.isEmpty { return value }
        if let description = attributes.description, !description.isEmpty { return description }
        return nil
    }
}

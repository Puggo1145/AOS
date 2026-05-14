import ApplicationServices
import CoreGraphics
import Foundation

/// Source path that produced a virtual mouse visualization event.
enum VirtualMouseEventSource: String, Sendable, Equatable {
    case coordinate
    case ax
}

/// Resolved screen-space target for the software cursor used to visualize
/// agent mouse intent without moving the user's hardware pointer.
struct VirtualMouseTarget: Sendable, Equatable {
    let source: VirtualMouseEventSource
    let point: CGPoint
    let windowId: CGWindowID?
    let windowBounds: WindowBounds?
}

/// UI-only event stream for the software cursor overlay.
enum VirtualMouseEvent: Sendable, Equatable {
    case move(VirtualMouseTarget)
    case click(VirtualMouseTarget, button: BackgroundMouseButton, count: Int)
    case drag(VirtualMouseTarget, to: CGPoint, button: BackgroundMouseButton)
    case settle(VirtualMouseTarget)
    case dismiss
}

struct VirtualMouseReflector: Sendable {
    typealias AXElementFrameReader = @Sendable (AXUIElement) throws -> CGRect?
    typealias EventSink = @Sendable (VirtualMouseEvent) async -> Void

    static let live = VirtualMouseReflector(
        axElementFrame: { element in
            try Self.axElementFrame(for: element)
        },
        emit: { event in
            await ComputerUseVirtualMouseOverlay.shared.handle(event)
        }
    )

    private let axElementFrame: AXElementFrameReader
    private let emit: EventSink

    init(
        axElementFrame: @escaping AXElementFrameReader,
        emit: @escaping EventSink
    ) {
        self.axElementFrame = axElementFrame
        self.emit = emit
    }

    func reflectCoordinateStart(
        _ event: BackgroundMouseEvent,
        window: WindowInfo
    ) async {
        await emit(.move(target(
            source: .coordinate,
            point: event.screenPoints[0],
            window: window
        )))
    }

    func reflectCoordinateCompletion(
        _ event: BackgroundMouseEvent,
        window: WindowInfo
    ) async {
        switch event {
        case .click(let button, let point, let count):
            await emit(.click(
                target(source: .coordinate, point: point, window: window),
                button: button,
                count: count
            ))
        case .drag(let button, let start, let end):
            await emit(.drag(
                target(source: .coordinate, point: start, window: window),
                to: end,
                button: button
            ))
        }
    }

    func reflectAXStart(
        element: AXUIElement,
        window: WindowInfo
    ) async -> VirtualMouseTarget? {
        let frame: CGRect?
        do {
            frame = try axElementFrame(element)
        } catch {
            return nil
        }
        guard let frame else {
            return nil
        }

        let target = target(
            source: .ax,
            point: frame.center,
            window: window
        )
        await emit(.move(target))
        return target
    }

    func reflectAXCompletion(
        _ event: AXElementEvent,
        target: VirtualMouseTarget
    ) async {
        switch event {
        case .action(let action):
            guard let button = action.virtualMouseButton else {
                await emit(.settle(target))
                return
            }
            await emit(.click(target, button: button, count: 1))
        case .focus, .scroll, .setValue, .setSelectedText:
            await emit(.settle(target))
        }
    }

    func dismiss() async {
        await emit(.dismiss)
    }

    private func target(
        source: VirtualMouseEventSource,
        point: CGPoint,
        window: WindowInfo
    ) -> VirtualMouseTarget {
        VirtualMouseTarget(
            source: source,
            point: point,
            windowId: window.id,
            windowBounds: window.bounds
        )
    }

    private static func axElementFrame(for element: AXUIElement) throws -> CGRect? {
        guard
            let position = try copyAXPointAttribute(kAXPositionAttribute as String, from: element),
            let size = try copyAXSizeAttribute(kAXSizeAttribute as String, from: element)
        else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    private static func copyAXPointAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) throws -> CGPoint? {
        guard let value = try copyAXValueAttribute(attribute, from: element) else {
            return nil
        }
        guard AXValueGetType(value) == .cgPoint else {
            throw ComputerUseError.axElementEventUnavailable("\(attribute) is not a CGPoint AXValue")
        }
        var point = CGPoint.zero
        AXValueGetValue(value, .cgPoint, &point)
        return point
    }

    private static func copyAXSizeAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) throws -> CGSize? {
        guard let value = try copyAXValueAttribute(attribute, from: element) else {
            return nil
        }
        guard AXValueGetType(value) == .cgSize else {
            throw ComputerUseError.axElementEventUnavailable("\(attribute) is not a CGSize AXValue")
        }
        var size = CGSize.zero
        AXValueGetValue(value, .cgSize, &size)
        return size
    }

    private static func copyAXValueAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) throws -> AXValue? {
        var rawValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue)
        guard result == .success else {
            return nil
        }
        guard let rawValue, CFGetTypeID(rawValue) == AXValueGetTypeID() else {
            throw ComputerUseError.axElementEventUnavailable("\(attribute) is not an AXValue")
        }
        return (rawValue as! AXValue)
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

private extension AXElementAction {
    var virtualMouseButton: BackgroundMouseButton? {
        switch self {
        case .press, .pick, .confirm, .open:
            return .left
        case .showMenu:
            return .right
        case .cancel, .increment, .decrement, .scrollToVisible:
            return nil
        }
    }
}

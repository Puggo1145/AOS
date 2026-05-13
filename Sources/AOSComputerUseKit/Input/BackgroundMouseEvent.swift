import CoreGraphics
import Darwin
import Foundation

/// Mouse button used by coordinate-based background mouse events.
public enum BackgroundMouseButton: String, Sendable, Equatable {
    case left
    case right
}

/// Coordinate-based mouse behavior that can be posted into a target window.
public enum BackgroundMouseEvent: Sendable, Equatable {
    case click(button: BackgroundMouseButton, point: CGPoint, count: Int = 1)
    case drag(button: BackgroundMouseButton, from: CGPoint, to: CGPoint)
}

extension BackgroundMouseEvent: CustomStringConvertible {
    public var description: String {
        switch self {
        case .click(let button, let point, let count):
            let base = "\(button.rawValue) click at \(Int(point.x)),\(Int(point.y))"
            return count == 1 ? base : "\(base) x\(count)"
        case .drag(let button, let start, let end):
            return "\(button.rawValue) drag from \(Int(start.x)),\(Int(start.y)) to \(Int(end.x)),\(Int(end.y))"
        }
    }
}

extension BackgroundMouseEvent {
    var screenPoints: [CGPoint] {
        switch self {
        case .click(_, let point, _):
            return [point]
        case .drag(_, let start, let end):
            return [start, end]
        }
    }
}

/// Fully resolved target context for posting one background mouse event.
struct BackgroundMouseEventTarget: Sendable, Equatable {
    let pid: pid_t
    let windowId: CGWindowID
    let windowBounds: WindowBounds

    init(pid: pid_t, windowId: CGWindowID, windowBounds: WindowBounds) {
        self.pid = pid
        self.windowId = windowId
        self.windowBounds = windowBounds
    }

    func windowLocalPoint(for screenPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: screenPoint.x - windowBounds.x,
            y: screenPoint.y - windowBounds.y
        )
    }
}

/// Observable post stage emitted after a background mouse event sub-event.
enum BackgroundMouseEventPostStage: String, Sendable, Equatable {
    case afterMouseMoved
    case afterPrimerDown
    case afterPrimerUp
    case afterPrimerGap
    case afterTargetDown
    case afterTargetDragged
    case afterTargetUp
}

/// Async hook used by the core to run window-order guards between sub-events.
typealias BackgroundMouseEventPostObserver = @Sendable (BackgroundMouseEventPostStage) async throws -> Void

import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

/// Semantic event delivered to a cached AX element from a prior app-state snapshot.
public enum AXElementEvent: Sendable, Equatable {
    case action(AXElementAction)
    case setValue(String)
    case setSelectedText(String)
    case focus
    case scroll(direction: AXScrollDirection, pages: Double)
}

public enum AXElementAction: String, Sendable, Codable, Equatable {
    case press
    case showMenu
    case pick
    case confirm
    case cancel
    case open
    case increment
    case decrement
    case scrollToVisible

    var axActionName: String {
        switch self {
        case .press: return "AXPress"
        case .showMenu: return "AXShowMenu"
        case .pick: return "AXPick"
        case .confirm: return "AXConfirm"
        case .cancel: return "AXCancel"
        case .open: return "AXOpen"
        case .increment: return "AXIncrement"
        case .decrement: return "AXDecrement"
        case .scrollToVisible: return "AXScrollToVisible"
        }
    }
}

public enum AXScrollDirection: String, Sendable, Codable, Equatable {
    case up
    case down
    case left
    case right
}

public struct AXElementEventResult: Sendable, Equatable {
    public let pid: pid_t
    public let windowId: CGWindowID
    public let stateId: StateID
    public let elementIndex: Int
    public let event: AXElementEvent

    public init(
        pid: pid_t,
        windowId: CGWindowID,
        stateId: StateID,
        elementIndex: Int,
        event: AXElementEvent
    ) {
        self.pid = pid
        self.windowId = windowId
        self.stateId = stateId
        self.elementIndex = elementIndex
        self.event = event
    }
}

struct AXElementEventTarget: Sendable, Equatable {
    let pid: pid_t
    let windowId: CGWindowID
    let stateId: StateID
    let elementIndex: Int
    let element: AXUIElement

    static func == (lhs: AXElementEventTarget, rhs: AXElementEventTarget) -> Bool {
        lhs.pid == rhs.pid
            && lhs.windowId == rhs.windowId
            && lhs.stateId == rhs.stateId
            && lhs.elementIndex == rhs.elementIndex
            && CFEqual(lhs.element, rhs.element)
    }
}

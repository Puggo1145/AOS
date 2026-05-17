import CoreGraphics
import Darwin
import Foundation

/// Modifier key held while posting a pid-scoped keyboard event.
public enum BackgroundKeyboardModifier: String, Sendable, Codable, Equatable, CaseIterable {
    case command
    case shift
    case option
    case control
    case function
}

extension BackgroundKeyboardModifier: CustomStringConvertible {
    public var description: String { rawValue }
}

/// Keyboard behavior posted into a target process without routing through the
/// user's frontmost app.
public enum BackgroundKeyboardEvent: Sendable, Equatable {
    case text(String, delayMilliseconds: Int = 30)
    case keyPress(key: String, modifiers: [BackgroundKeyboardModifier] = [], count: Int = 1)
    case hotkey(modifiers: [BackgroundKeyboardModifier], key: String)
}

extension BackgroundKeyboardEvent: CustomStringConvertible {
    public var description: String {
        switch self {
        case .text(let text, let delayMilliseconds):
            return "text input \(text.count) character(s) delay \(delayMilliseconds)ms"
        case .keyPress(let key, let modifiers, let count):
            let press = keyboardDescription(key: key, modifiers: modifiers)
            return count == 1 ? press : "\(press) x\(count)"
        case .hotkey(let modifiers, let key):
            return keyboardDescription(key: key, modifiers: modifiers)
        }
    }

    private func keyboardDescription(key: String, modifiers: [BackgroundKeyboardModifier]) -> String {
        let pieces = modifiers.map(\.rawValue) + [key]
        return pieces.joined(separator: "+")
    }
}

/// Fully resolved target context for posting one background keyboard event.
struct BackgroundKeyboardEventTarget: Sendable, Equatable {
    let pid: pid_t
    let windowId: CGWindowID

    init(pid: pid_t, windowId: CGWindowID) {
        self.pid = pid
        self.windowId = windowId
    }
}

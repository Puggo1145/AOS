import CoreGraphics
import Foundation

// MARK: - KeyboardInput
//
// Per `docs/designs/computer-use.md` §"事件投递路径". Keyboard always goes
// per-pid: `SLEventPostToPid` with the `SLSEventAuthenticationMessage`
// envelope (Chromium rejects unsigned synthetic key events on macOS 14+).
// Falls back to `CGEvent.postToPid` when the SkyLight SPI didn't resolve.
//
// `typeText` uses `CGEventKeyboardSetUnicodeString` with virtualKey=0,
// 30ms gap between characters so IME / autocomplete pipelines don't lose
// composition state.
//
// Frontmost-target HID tap (CGEvent.post via the system-wide HID stream)
// is **deliberately** absent for keyboard. Per-pid is universally available
// for keyboard surfaces; HID tap was needed only for mouse + viewport
// edge cases.

public enum KeyboardError: Error, CustomStringConvertible, Sendable {
    case unknownKey(String)
    case noKeyInCombo
    case eventCreationFailed(String)

    public var description: String {
        switch self {
        case .unknownKey(let k): return "Unknown key name: \(k)"
        case .noKeyInCombo: return "Hotkey combo has no non-modifier key."
        case .eventCreationFailed(let phase): return "Failed to create key event for \(phase)."
        }
    }
}

public enum KeyboardInput {

    /// Press + release one virtual key, optionally with modifiers. `pid`
    /// is the target process; events route via `SLEventPostToPid`. The
    /// design fixes keyboard to per-pid only — see file-level doc.
    public static func press(
        _ key: String,
        modifiers: [String] = [],
        toPid pid: pid_t
    ) throws {
        guard let code = virtualKeyCode(for: key) else {
            throw KeyboardError.unknownKey(key)
        }
        let flags = modifierMask(for: modifiers)
        try sendKey(code: code, down: true, flags: flags, toPid: pid)
        try sendKey(code: code, down: false, flags: flags, toPid: pid)
    }

    /// Press a chord (cmd+shift+a). Modifier names are extracted from
    /// `keys`; the remaining single-key entry is the chord's primary
    /// keycode. Last non-modifier wins if multiple are passed.
    public static func hotkey(_ keys: [String], toPid pid: pid_t) throws {
        var modifiers: [String] = []
        var finalKey: String?
        for raw in keys {
            if modifierNames.contains(raw.lowercased()) {
                modifiers.append(raw)
            } else {
                finalKey = raw
            }
        }
        guard let final = finalKey else {
            throw KeyboardError.noKeyInCombo
        }
        try press(final, modifiers: modifiers, toPid: pid)
    }

    /// Type Unicode text character-by-character via
    /// `CGEventKeyboardSetUnicodeString`, virtualKey=0. 30ms between
    /// characters covers IME composition / autocomplete pipelines.
    public static func typeText(
        _ text: String,
        delayMilliseconds: Int = 30,
        toPid pid: pid_t
    ) throws {
        let clampedDelay = max(0, min(200, delayMilliseconds))
        for character in text {
            try sendUnicodeCharacter(character, toPid: pid)
            if clampedDelay > 0 {
                let microseconds = UInt32(clampedDelay) * 1_000
                usleep(microseconds)
            }
        }
    }

    // MARK: - Internals

    private static func sendKey(
        code: Int, down: Bool, flags: CGEventFlags, toPid pid: pid_t
    ) throws {
        guard
            let event = CGEvent(
                keyboardEventSource: nil,
                virtualKey: CGKeyCode(code),
                keyDown: down
            )
        else {
            throw KeyboardError.eventCreationFailed("code=\(code) down=\(down)")
        }
        event.flags = flags
        // Keyboard always carries the auth envelope; Chromium rejects
        // unsigned synthetic kbd events on macOS 14+.
        if !SkyLightEventPost.postToPid(pid, event: event, attachAuthMessage: true) {
            event.postToPid(pid)
        }
    }

    private static func sendUnicodeCharacter(_ character: Character, toPid pid: pid_t) throws {
        let utf16 = Array(String(character).utf16)
        for keyDown in [true, false] {
            guard
                let event = CGEvent(
                    keyboardEventSource: nil,
                    virtualKey: 0,
                    keyDown: keyDown
                )
            else {
                throw KeyboardError.eventCreationFailed(
                    "unicode character \"\(character)\" down=\(keyDown)"
                )
            }
            utf16.withUnsafeBufferPointer { buffer in
                if let base = buffer.baseAddress {
                    event.keyboardSetUnicodeString(
                        stringLength: buffer.count, unicodeString: base
                    )
                }
            }
            if !SkyLightEventPost.postToPid(pid, event: event, attachAuthMessage: true) {
                event.postToPid(pid)
            }
        }
    }

    private static let modifierNames: Set<String> = [
        "cmd", "command", "shift", "option", "alt", "ctrl", "control", "fn",
    ]

    private static func modifierMask(for modifiers: [String]) -> CGEventFlags {
        var mask: CGEventFlags = []
        for raw in modifiers {
            switch raw.lowercased() {
            case "cmd", "command": mask.insert(.maskCommand)
            case "shift": mask.insert(.maskShift)
            case "option", "alt": mask.insert(.maskAlternate)
            case "ctrl", "control": mask.insert(.maskControl)
            case "fn": mask.insert(.maskSecondaryFn)
            default: break
            }
        }
        return mask
    }

    private static func virtualKeyCode(for name: String) -> Int? {
        let lower = name.lowercased()
        if let named = namedKeys[lower] { return named }
        guard lower.count == 1, let first = lower.first else { return nil }
        if let code = letterKeys[first] { return code }
        if let code = digitKeys[first] { return code }
        return nil
    }

    // Virtual key codes from Carbon/HIToolbox/Events.h (kVK_* constants).
    // Plain ints to avoid the Carbon import + Swift 6 Sendable hassles.
    private static let namedKeys: [String: Int] = [
        "return": 0x24, "enter": 0x24,
        "tab": 0x30,
        "space": 0x31,
        "delete": 0x33, "backspace": 0x33,
        "forwarddelete": 0x75, "del": 0x75,
        "escape": 0x35, "esc": 0x35,
        "left": 0x7B, "leftarrow": 0x7B,
        "right": 0x7C, "rightarrow": 0x7C,
        "down": 0x7D, "downarrow": 0x7D,
        "up": 0x7E, "uparrow": 0x7E,
        "home": 0x73, "end": 0x77,
        "pageup": 0x74, "pagedown": 0x79,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76,
        "f5": 0x60, "f6": 0x61, "f7": 0x62, "f8": 0x64,
        "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
    ]

    private static let letterKeys: [Character: Int] = [
        "a": 0x00, "b": 0x0B, "c": 0x08, "d": 0x02, "e": 0x0E, "f": 0x03,
        "g": 0x05, "h": 0x04, "i": 0x22, "j": 0x26, "k": 0x28, "l": 0x25,
        "m": 0x2E, "n": 0x2D, "o": 0x1F, "p": 0x23, "q": 0x0C, "r": 0x0F,
        "s": 0x01, "t": 0x11, "u": 0x20, "v": 0x09, "w": 0x0D, "x": 0x07,
        "y": 0x10, "z": 0x06,
    ]

    private static let digitKeys: [Character: Int] = [
        "0": 0x1D, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15,
        "5": 0x17, "6": 0x16, "7": 0x1A, "8": 0x1C, "9": 0x19,
    ]
}

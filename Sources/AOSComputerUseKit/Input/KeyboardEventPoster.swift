import CoreGraphics
import Darwin
import Foundation
import ObjectiveC

/// Posts pid-scoped keyboard events through SkyLight's authenticated per-pid
/// event route. The auth envelope is required for Chromium/Electron keyboard
/// pipelines to accept background synthetic input as live input.
struct KeyboardEventPoster: Sendable {
    typealias MakeKeyboardEvent = @Sendable (CGKeyCode, Bool) throws -> CGEvent
    typealias SetUnicodeString = @Sendable (CGEvent, [UniChar]) throws -> Void
    typealias PostEventToPID = @Sendable (CGEvent, pid_t) throws -> Void
    typealias Sleep = @Sendable (useconds_t) -> Void

    private let makeKeyboardEvent: MakeKeyboardEvent
    private let setUnicodeString: SetUnicodeString
    private let postAuthenticatedEventToPID: PostEventToPID
    private let sleep: Sleep

    init(
        makeKeyboardEvent: @escaping MakeKeyboardEvent = { keyCode, keyDown in
            guard let event = CGEvent(
                keyboardEventSource: nil,
                virtualKey: keyCode,
                keyDown: keyDown
            ) else {
                throw ComputerUseError.keyboardEventUnavailable(
                    "failed to create key event code=\(keyCode) down=\(keyDown)"
                )
            }
            return event
        },
        setUnicodeString: @escaping SetUnicodeString = { event, utf16 in
            utf16.withUnsafeBufferPointer { buffer in
                if let base = buffer.baseAddress {
                    event.keyboardSetUnicodeString(
                        stringLength: buffer.count,
                        unicodeString: base
                    )
                }
            }
        },
        postAuthenticatedEventToPID: @escaping PostEventToPID,
        sleep: @escaping Sleep = { usleep($0) }
    ) {
        self.makeKeyboardEvent = makeKeyboardEvent
        self.setUnicodeString = setUnicodeString
        self.postAuthenticatedEventToPID = postAuthenticatedEventToPID
        self.sleep = sleep
    }

    static func live() -> KeyboardEventPoster {
        KeyboardEventPoster(
            postAuthenticatedEventToPID: { event, pid in
                let symbols = try SkyLightKeyboardEventPostSymbols.load()
                try symbols.postAuthenticatedEventToPID(event, pid)
            }
        )
    }

    func post(
        _ event: BackgroundKeyboardEvent,
        to target: BackgroundKeyboardEventTarget
    ) throws {
        switch event {
        case .text(let text, let delayMilliseconds):
            try postText(text, delayMilliseconds: delayMilliseconds, pid: target.pid)
        case .keyPress(let key, let modifiers, let count):
            guard count > 0 else {
                throw ComputerUseError.keyboardEventUnavailable(
                    "key press count must be greater than 0"
                )
            }
            try postKeyPress(key: key, modifiers: modifiers, count: count, pid: target.pid)
        case .hotkey(let modifiers, let key):
            guard !modifiers.isEmpty else {
                throw ComputerUseError.keyboardEventUnavailable(
                    "hotkey requires at least one modifier"
                )
            }
            try postKeyPress(key: key, modifiers: modifiers, count: 1, pid: target.pid)
        }
    }

    private func postText(
        _ text: String,
        delayMilliseconds: Int,
        pid: pid_t
    ) throws {
        guard !text.isEmpty else {
            throw ComputerUseError.keyboardEventUnavailable("text input cannot be empty")
        }
        guard (0...200).contains(delayMilliseconds) else {
            throw ComputerUseError.keyboardEventUnavailable(
                "text input delay must be between 0 and 200ms"
            )
        }
        for character in text {
            let utf16 = Array(String(character).utf16)
            try postUnicodeCharacter(utf16, pid: pid)
            if delayMilliseconds > 0 {
                sleep(useconds_t(delayMilliseconds) * 1_000)
            }
        }
    }

    private func postUnicodeCharacter(_ utf16: [UniChar], pid: pid_t) throws {
        for keyDown in [true, false] {
            let event = try makeKeyboardEvent(0, keyDown)
            try setUnicodeString(event, utf16)
            try postAuthenticated(event, pid: pid)
        }
    }

    private func postKeyPress(
        key: String,
        modifiers: [BackgroundKeyboardModifier],
        count: Int,
        pid: pid_t
    ) throws {
        let keyCode = try Self.keyCode(for: key)
        let flags = Self.modifierFlags(for: modifiers)
        for _ in 0..<count {
            for keyDown in [true, false] {
                let event = try makeKeyboardEvent(keyCode, keyDown)
                event.flags = flags
                try postAuthenticated(event, pid: pid)
            }
        }
    }

    private func postAuthenticated(_ event: CGEvent, pid: pid_t) throws {
        event.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        try postAuthenticatedEventToPID(event, pid)
    }

    private static func modifierFlags(for modifiers: [BackgroundKeyboardModifier]) -> CGEventFlags {
        var flags: CGEventFlags = []
        for modifier in modifiers {
            switch modifier {
            case .command:
                flags.insert(.maskCommand)
            case .shift:
                flags.insert(.maskShift)
            case .option:
                flags.insert(.maskAlternate)
            case .control:
                flags.insert(.maskControl)
            case .function:
                flags.insert(.maskSecondaryFn)
            }
        }
        return flags
    }

    private static func keyCode(for name: String) throws -> CGKeyCode {
        let lower = name.lowercased()
        if let named = namedKeys[lower] {
            return named
        }
        guard lower.count == 1, let first = lower.first else {
            throw ComputerUseError.keyboardEventUnavailable("unknown key name: \(name)")
        }
        if let code = letterKeys[first] { return code }
        if let code = digitKeys[first] { return code }
        throw ComputerUseError.keyboardEventUnavailable("unknown key name: \(name)")
    }

    // Virtual key codes from HIToolbox Events.h. Duplicated as values so this
    // foundation does not need Carbon imports for a small fixed vocabulary.
    private static let namedKeys: [String: CGKeyCode] = [
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

    private static let letterKeys: [Character: CGKeyCode] = [
        "a": 0x00, "b": 0x0B, "c": 0x08, "d": 0x02, "e": 0x0E, "f": 0x03,
        "g": 0x05, "h": 0x04, "i": 0x22, "j": 0x26, "k": 0x28, "l": 0x25,
        "m": 0x2E, "n": 0x2D, "o": 0x1F, "p": 0x23, "q": 0x0C, "r": 0x0F,
        "s": 0x01, "t": 0x11, "u": 0x20, "v": 0x09, "w": 0x0D, "x": 0x07,
        "y": 0x10, "z": 0x06,
    ]

    private static let digitKeys: [Character: CGKeyCode] = [
        "0": 0x1D, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15,
        "5": 0x17, "6": 0x16, "7": 0x1A, "8": 0x1C, "9": 0x19,
    ]
}

private typealias SLEventPostToPid = @convention(c) (pid_t, CGEvent) -> Void
private typealias SLEventSetAuthenticationMessage = @convention(c) (CGEvent, AnyObject) -> Void
private typealias AuthenticationFactoryMessageSend = @convention(c) (
    AnyObject,
    Selector,
    UnsafeMutableRawPointer,
    Int32,
    UInt32
) -> AnyObject?

private struct SkyLightKeyboardEventPostSymbols {
    let postEventToPID: SLEventPostToPid
    let setAuthenticationMessage: SLEventSetAuthenticationMessage
    let makeAuthenticationMessage: AuthenticationFactoryMessageSend
    let authenticationMessageClass: AnyClass
    let authenticationFactorySelector: Selector

    static func load() throws -> SkyLightKeyboardEventPostSymbols {
        let handles = try KeyboardEventPrivateFrameworkHandles.load()
        guard let messageClass = NSClassFromString("SLSEventAuthenticationMessage") else {
            throw ComputerUseError.keyboardEventUnavailable(
                "missing private class SLSEventAuthenticationMessage"
            )
        }
        return SkyLightKeyboardEventPostSymbols(
            postEventToPID: try handles.symbol("SLEventPostToPid"),
            setAuthenticationMessage: try handles.symbol("SLEventSetAuthenticationMessage"),
            makeAuthenticationMessage: try handles.symbol("objc_msgSend"),
            authenticationMessageClass: messageClass,
            authenticationFactorySelector: NSSelectorFromString("messageWithEventRecord:pid:version:")
        )
    }

    func postAuthenticatedEventToPID(_ event: CGEvent, _ pid: pid_t) throws {
        guard let eventRecord = Self.extractEventRecord(from: event) else {
            throw ComputerUseError.keyboardEventUnavailable(
                "failed to extract SkyLight event record for keyboard authentication"
            )
        }
        guard let message = makeAuthenticationMessage(
            authenticationMessageClass as AnyObject,
            authenticationFactorySelector,
            eventRecord,
            pid,
            0
        ) else {
            throw ComputerUseError.keyboardEventUnavailable(
                "failed to create SkyLight keyboard authentication message"
            )
        }
        setAuthenticationMessage(event, message)
        postEventToPID(pid, event)
    }

    private static func extractEventRecord(from event: CGEvent) -> UnsafeMutableRawPointer? {
        let base = Unmanaged.passUnretained(event).toOpaque()
        for offset in [24, 32, 16] {
            let slot = base.advanced(by: offset).assumingMemoryBound(
                to: UnsafeMutableRawPointer?.self
            )
            if let pointer = slot.pointee {
                return pointer
            }
        }
        return nil
    }
}

private struct KeyboardEventPrivateFrameworkHandles {
    private let defaultHandle: UnsafeMutableRawPointer

    static func load() throws -> KeyboardEventPrivateFrameworkHandles {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        guard dlopen(path, RTLD_LAZY) != nil else {
            throw ComputerUseError.keyboardEventUnavailable(
                "failed to load private framework at \(path)"
            )
        }
        guard let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2) else {
            throw ComputerUseError.keyboardEventUnavailable(
                "failed to access RTLD_DEFAULT symbol scope"
            )
        }
        return KeyboardEventPrivateFrameworkHandles(defaultHandle: defaultHandle)
    }

    func symbol<T>(_ name: String) throws -> T {
        if let pointer = dlsym(defaultHandle, name) {
            return unsafeBitCast(pointer, to: T.self)
        }
        throw ComputerUseError.keyboardEventUnavailable("missing private symbol \(name)")
    }
}

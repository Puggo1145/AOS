@testable import ComputerUseKit
import CoreGraphics
import Darwin
import Foundation
import Testing

@Suite("ComputerUseCore background keyboard events")
struct KeyboardEventTests {
    @Test("core focuses target and posts keyboard event while keeping app session open")
    func coreFocusesTargetAndPostsKeyboardEventWhileKeepingAppSessionOpen() async throws {
        let recorder = KeyboardChainRecorder()
        let target = Self.window(id: 456, pid: 123, owner: "Chrome", zIndex: 2)
        let front = Self.window(id: 789, pid: 777, owner: "Ghostty", zIndex: 3)
        let event = BackgroundKeyboardEvent.hotkey(modifiers: [.command], key: "l")
        let core = ComputerUseCore(
            windowLookup: { windowId in
                [target, front].first { $0.id == windowId }
            },
            windowsForPIDLookup: { pid in
                pid == 123 ? [target] : []
            },
            frontmostWindowLookup: {
                front
            },
            focusWindowWithoutRaising: { pid, windowId in
                await recorder.record(.focus(pid: pid, windowId: windowId))
            },
            activateApplication: { pid in
                await recorder.record(.activate(pid: pid))
                return true
            },
            postKeyboardEvent: { event, target in
                await recorder.record(.keyboard(event: event, target: target))
            }
        )

        _ = try await core.startAppSession(pid: 123, windowId: 456)
        let result = try await core.postKeyboardEvent(windowId: 456, event: event)

        #expect(result == WindowKeyboardEventResult(pid: 123, windowId: 456, event: event))
        #expect(await recorder.events == [
            .focus(pid: 123, windowId: 456),
            .focus(pid: 123, windowId: 456),
            .keyboard(event: event, target: BackgroundKeyboardEventTarget(pid: 123, windowId: 456)),
        ])
    }

    @Test("core keeps keyboard app session open until explicit stopAppSession")
    func coreKeepsKeyboardAppSessionOpenUntilExplicitStopAppSession() async throws {
        let recorder = KeyboardChainRecorder()
        let target = Self.window(id: 456, pid: 123, owner: "Chrome", zIndex: 2)
        let front = Self.window(id: 789, pid: 777, owner: "Ghostty", zIndex: 3)
        let event = BackgroundKeyboardEvent.text("hello", delayMilliseconds: 30)
        let core = ComputerUseCore(
            windowLookup: { windowId in
                [target, front].first { $0.id == windowId }
            },
            windowsForPIDLookup: { pid in
                pid == 123 ? [target] : []
            },
            frontmostWindowLookup: {
                front
            },
            focusWindowWithoutRaising: { pid, windowId in
                await recorder.record(.focus(pid: pid, windowId: windowId))
            },
            activateApplication: { pid in
                await recorder.record(.activate(pid: pid))
                return true
            },
            postKeyboardEvent: { event, target in
                await recorder.record(.keyboard(event: event, target: target))
            }
        )

        _ = try await core.startAppSession(pid: 123, windowId: 456)
        _ = try await core.postKeyboardEvent(windowId: 456, event: event)
        #expect(await recorder.events == [
            .focus(pid: 123, windowId: 456),
            .focus(pid: 123, windowId: 456),
            .keyboard(event: event, target: BackgroundKeyboardEventTarget(pid: 123, windowId: 456)),
        ])

        let stopped = try await core.stopAppSession()

        #expect(stopped == AppSessionResult(pid: 123))
        #expect(await recorder.events == [
            .focus(pid: 123, windowId: 456),
            .focus(pid: 123, windowId: 456),
            .keyboard(event: event, target: BackgroundKeyboardEventTarget(pid: 123, windowId: 456)),
        ])
    }

    @Test("core validates window ownership before posting keyboard events")
    func coreValidatesWindowOwnershipBeforePostingKeyboardEvents() async {
        let recorder = KeyboardChainRecorder()
        let core = ComputerUseCore(
            windowLookup: { _ in
                Self.window(id: 456, pid: 999, owner: "Other", zIndex: 1)
            },
            focusWindowWithoutRaising: { pid, windowId in
                await recorder.record(.focus(pid: pid, windowId: windowId))
            }
        )

        await #expect(throws: ComputerUseError.self) {
            _ = try await core.startAppSession(pid: 123, windowId: 456)
            _ = try await core.postKeyboardEvent(
                windowId: 456,
                event: .keyPress(key: "return")
            )
        }
        #expect(await recorder.events.isEmpty)
    }

    @Test("core validates keyboard event before focusing target")
    func coreValidatesKeyboardEventBeforeFocusingTarget() async {
        let recorder = KeyboardChainRecorder()
        let target = Self.window(id: 456, pid: 123, owner: "Chrome", zIndex: 2)
        let core = ComputerUseCore(
            windowLookup: { windowId in
                windowId == target.id ? target : nil
            },
            focusWindowWithoutRaising: { pid, windowId in
                await recorder.record(.focus(pid: pid, windowId: windowId))
            },
            postKeyboardEvent: { event, target in
                await recorder.record(.keyboard(event: event, target: target))
            }
        )

        await #expect(throws: ComputerUseError.self) {
            _ = try await core.startAppSession(pid: 123, windowId: 456)
            _ = try await core.postKeyboardEvent(
                windowId: 456,
                event: .text("hello", delayMilliseconds: 1_000)
            )
        }
        #expect(await recorder.events == [
            .focus(pid: 123, windowId: 456),
        ])
    }

    @Test("core leaves app session open when keyboard posting fails after focus")
    func coreLeavesAppSessionOpenWhenKeyboardPostingFailsAfterFocus() async throws {
        let recorder = KeyboardChainRecorder()
        let target = Self.window(id: 456, pid: 123, owner: "Chrome", zIndex: 2)
        let front = Self.window(id: 789, pid: 777, owner: "Ghostty", zIndex: 3)
        let event = BackgroundKeyboardEvent.keyPress(key: "delete")
        let core = ComputerUseCore(
            windowLookup: { windowId in
                [target, front].first { $0.id == windowId }
            },
            windowsForPIDLookup: { pid in
                pid == 123 ? [target] : []
            },
            frontmostWindowLookup: {
                front
            },
            focusWindowWithoutRaising: { pid, windowId in
                await recorder.record(.focus(pid: pid, windowId: windowId))
            },
            activateApplication: { pid in
                await recorder.record(.activate(pid: pid))
                return true
            },
            postKeyboardEvent: { _, _ in
                throw ComputerUseError.keyboardEventUnavailable("injected failure")
            }
        )

        await #expect(throws: ComputerUseError.self) {
            _ = try await core.startAppSession(pid: 123, windowId: 456)
            _ = try await core.postKeyboardEvent(windowId: 456, event: event)
        }
        let stopped = try await core.stopAppSession()

        #expect(stopped == AppSessionResult(pid: 123))
        #expect(await recorder.events == [
            .focus(pid: 123, windowId: 456),
            .focus(pid: 123, windowId: 456),
        ])
    }

    @Test("keyboard poster types unicode text as authenticated per-character down-up events")
    func keyboardPosterTypesUnicodeTextAsAuthenticatedPerCharacterDownUpEvents() throws {
        let recorder = KeyboardPostRecorder()
        let poster = KeyboardEventPoster(
            setUnicodeString: { event, utf16 in
                recorder.recordUnicode(event: event, utf16: utf16)
            },
            postAuthenticatedEventToPID: { event, pid in
                recorder.recordPost(event: event, pid: pid)
            },
            sleep: { interval in
                recorder.recordSleep(interval)
            }
        )

        try poster.post(
            .text("é🙂", delayMilliseconds: 40),
            to: BackgroundKeyboardEventTarget(pid: 123, windowId: 456)
        )

        #expect(recorder.posts.map(\.pid) == [123, 123, 123, 123])
        #expect(recorder.posts.map(\.type) == [.keyDown, .keyUp, .keyDown, .keyUp])
        #expect(recorder.posts.map(\.keyCode) == [0, 0, 0, 0])
        #expect(recorder.unicodePayloads == [
            Array("é".utf16),
            Array("é".utf16),
            Array("🙂".utf16),
            Array("🙂".utf16),
        ])
        #expect(recorder.sleeps == [40_000, 40_000])
    }

    @Test("keyboard poster posts hotkey with modifier flags")
    func keyboardPosterPostsHotkeyWithModifierFlags() throws {
        let recorder = KeyboardPostRecorder()
        let poster = KeyboardEventPoster(
            setUnicodeString: { event, utf16 in
                recorder.recordUnicode(event: event, utf16: utf16)
            },
            postAuthenticatedEventToPID: { event, pid in
                recorder.recordPost(event: event, pid: pid)
            },
            sleep: { interval in
                recorder.recordSleep(interval)
            }
        )

        try poster.post(
            .hotkey(modifiers: [.command, .shift], key: "4"),
            to: BackgroundKeyboardEventTarget(pid: 123, windowId: 456)
        )

        #expect(recorder.posts.map(\.type) == [.keyDown, .keyUp])
        #expect(recorder.posts.map(\.keyCode) == [0x15, 0x15])
        #expect(recorder.posts.allSatisfy { post in
            post.flags.contains(.maskCommand) && post.flags.contains(.maskShift)
        })
        #expect(recorder.unicodePayloads.isEmpty)
        #expect(recorder.sleeps.isEmpty)
    }

    @Test("keyboard poster repeats key press count as down-up pairs")
    func keyboardPosterRepeatsKeyPressCountAsDownUpPairs() throws {
        let recorder = KeyboardPostRecorder()
        let poster = KeyboardEventPoster(
            setUnicodeString: { event, utf16 in
                recorder.recordUnicode(event: event, utf16: utf16)
            },
            postAuthenticatedEventToPID: { event, pid in
                recorder.recordPost(event: event, pid: pid)
            },
            sleep: { interval in
                recorder.recordSleep(interval)
            }
        )

        try poster.post(
            .keyPress(key: "delete", count: 3),
            to: BackgroundKeyboardEventTarget(pid: 123, windowId: 456)
        )

        #expect(recorder.posts.map(\.type) == [
            .keyDown, .keyUp,
            .keyDown, .keyUp,
            .keyDown, .keyUp,
        ])
        #expect(recorder.posts.map(\.keyCode) == [0x33, 0x33, 0x33, 0x33, 0x33, 0x33])
        #expect(recorder.posts.map(\.pid) == [123, 123, 123, 123, 123, 123])
    }

    @Test("keyboard poster fails on unknown keys and modifier-only hotkeys")
    func keyboardPosterFailsOnUnknownKeysAndModifierOnlyHotkeys() {
        let recorder = KeyboardPostRecorder()
        let poster = KeyboardEventPoster(
            setUnicodeString: { event, utf16 in
                recorder.recordUnicode(event: event, utf16: utf16)
            },
            postAuthenticatedEventToPID: { event, pid in
                recorder.recordPost(event: event, pid: pid)
            },
            sleep: { interval in
                recorder.recordSleep(interval)
            }
        )

        #expect(throws: ComputerUseError.self) {
            try poster.post(
                .keyPress(key: "not-a-key"),
                to: BackgroundKeyboardEventTarget(pid: 123, windowId: 456)
            )
        }
        #expect(throws: ComputerUseError.self) {
            try poster.post(
                .hotkey(modifiers: [], key: "c"),
                to: BackgroundKeyboardEventTarget(pid: 123, windowId: 456)
            )
        }
        #expect(throws: ComputerUseError.self) {
            try poster.post(
                .keyPress(key: "delete", count: 0),
                to: BackgroundKeyboardEventTarget(pid: 123, windowId: 456)
            )
        }
        #expect(throws: ComputerUseError.self) {
            try poster.post(
                .text("hello", delayMilliseconds: 1_000),
                to: BackgroundKeyboardEventTarget(pid: 123, windowId: 456)
            )
        }
        #expect(recorder.posts.isEmpty)
    }

    private static func window(
        id: CGWindowID,
        pid: pid_t,
        owner: String,
        zIndex: Int
    ) -> WindowInfo {
        WindowInfo(
            id: id,
            pid: pid,
            owner: owner,
            title: owner,
            bounds: WindowBounds(x: 0, y: 0, width: 300, height: 100),
            zIndex: zIndex,
            isOnScreen: true,
            layer: 0
        )
    }
}

private actor KeyboardChainRecorder {
    private var recordedEvents: [KeyboardChainEvent] = []

    var events: [KeyboardChainEvent] {
        recordedEvents
    }

    func record(_ event: KeyboardChainEvent) {
        recordedEvents.append(event)
    }
}

private enum KeyboardChainEvent: Equatable {
    case focus(pid: pid_t, windowId: CGWindowID)
    case activate(pid: pid_t)
    case keyboard(event: BackgroundKeyboardEvent, target: BackgroundKeyboardEventTarget)
}

private final class KeyboardPostRecorder: @unchecked Sendable {
    struct Post: Sendable, Equatable {
        let type: CGEventType
        let pid: pid_t
        let keyCode: Int64
        let flags: CGEventFlags
    }

    private let lock = NSLock()
    private var recordedPosts: [Post] = []
    private var recordedUnicodePayloads: [[UniChar]] = []
    private var recordedSleeps: [useconds_t] = []

    var posts: [Post] {
        lock.lock()
        defer { lock.unlock() }
        return recordedPosts
    }

    var unicodePayloads: [[UniChar]] {
        lock.lock()
        defer { lock.unlock() }
        return recordedUnicodePayloads
    }

    var sleeps: [useconds_t] {
        lock.lock()
        defer { lock.unlock() }
        return recordedSleeps
    }

    func recordPost(event: CGEvent, pid: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        recordedPosts.append(Post(
            type: event.type,
            pid: pid,
            keyCode: event.getIntegerValueField(.keyboardEventKeycode),
            flags: event.flags
        ))
    }

    func recordUnicode(event _: CGEvent, utf16: [UniChar]) {
        lock.lock()
        defer { lock.unlock() }
        recordedUnicodePayloads.append(utf16)
    }

    func recordSleep(_ interval: useconds_t) {
        lock.lock()
        defer { lock.unlock() }
        recordedSleeps.append(interval)
    }
}

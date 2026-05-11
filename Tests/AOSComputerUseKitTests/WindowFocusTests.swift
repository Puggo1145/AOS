@testable import AOSComputerUseKit
import CoreGraphics
import Darwin
import Foundation
import Testing

@Suite("ComputerUseCore focus without raise")
struct WindowFocusTests {
    @Test("validates pid ownership before focusing the window")
    func validatesOwnershipBeforeFocusingWindow() async throws {
        let recorder = FocusRecorder()
        let core = ComputerUseCore(
            windowLookup: { windowId in
                guard windowId == 456 else { return nil }
                return WindowInfo(
                    id: 456,
                    pid: 123,
                    owner: "Terminal",
                    title: "Shell",
                    bounds: WindowBounds(x: 0, y: 0, width: 800, height: 600),
                    zIndex: 1,
                    isOnScreen: true,
                    layer: 0
                )
            },
            focusWindowWithoutRaising: { pid, windowId in
                await recorder.record(pid: pid, windowId: windowId)
            }
        )

        let result = try await core.focusWindowWithoutRaise(pid: 123, windowId: 456)

        #expect(result.pid == 123)
        #expect(result.windowId == 456)
        #expect(await recorder.calls == [FocusCall(pid: 123, windowId: 456)])
    }

    @Test("does not focus a window owned by another pid")
    func rejectsMismatchedWindowOwner() async {
        let recorder = FocusRecorder()
        let core = ComputerUseCore(
            windowLookup: { _ in
                WindowInfo(
                    id: 456,
                    pid: 999,
                    owner: "Other",
                    title: "Shell",
                    bounds: WindowBounds(x: 0, y: 0, width: 800, height: 600),
                    zIndex: 1,
                    isOnScreen: true,
                    layer: 0
                )
            },
            focusWindowWithoutRaising: { pid, windowId in
                await recorder.record(pid: pid, windowId: windowId)
            }
        )

        await #expect(throws: ComputerUseError.self) {
            try await core.focusWindowWithoutRaise(pid: 123, windowId: 456)
        }
        #expect(await recorder.calls.isEmpty)
    }

    @Test("builds the SLPS focus event record layout")
    func buildsSLPSFocusEventRecordLayout() {
        let bytes = SkyLightWindowFocuser.makeFocusEventBytes(windowId: 0x0102_0304)

        #expect(bytes.count == 0xf8)
        #expect(bytes[0x04] == 0xf8)
        #expect(bytes[0x08] == 0x0d)
        #expect(bytes[0x3c] == 0x04)
        #expect(bytes[0x3d] == 0x03)
        #expect(bytes[0x3e] == 0x02)
        #expect(bytes[0x3f] == 0x01)
        // Always the "focus" marker (0x01); we never build the "defocus" (0x02)
        // variant since AOS no longer touches the previous front PSN.
        #expect(bytes[0x8a] == 0x01)
        #expect(bytes[0x3a] == 0x00)
        #expect(bytes[0x20] == 0x00)
    }

    @Test("builds the SLPS key-window event record layout")
    func buildsSLPSKeyWindowEventRecordLayout() {
        let beginBytes = SkyLightWindowFocuser.makeKeyWindowEventBytes(
            windowId: 0x0102_0304,
            phase: .begin
        )
        let endBytes = SkyLightWindowFocuser.makeKeyWindowEventBytes(
            windowId: 0x0102_0304,
            phase: .end
        )

        #expect(beginBytes.count == 0xf8)
        #expect(beginBytes[0x04] == 0xf8)
        #expect(beginBytes[0x08] == 0x01)
        #expect(beginBytes[0x3a] == 0x10)
        #expect(beginBytes[0x3c] == 0x04)
        #expect(beginBytes[0x3d] == 0x03)
        #expect(beginBytes[0x3e] == 0x02)
        #expect(beginBytes[0x3f] == 0x01)
        for offset in 0x20..<0x30 {
            #expect(beginBytes[offset] == 0xff)
        }

        #expect(endBytes[0x08] == 0x02)
        #expect(endBytes[0x3a] == 0x10)
        #expect(endBytes[0x3c] == 0x04)
        #expect(endBytes[0x3d] == 0x03)
        #expect(endBytes[0x3e] == 0x02)
        #expect(endBytes[0x3f] == 0x01)
    }

    /// Regression: the focuser must never touch the previously-focused
    /// process. Posting a defocus event (or any event) to a non-target PSN
    /// is what used to flip the user's prior window into a deactive state.
    @Test("focuses only the target PSN and never posts a defocus event")
    func focusesOnlyTargetPSNAndPostsNoDefocusEvent() throws {
        let targetPid: pid_t = pid_t.random(in: 1_000..<50_000)
        let targetWindowId = CGWindowID.random(in: 1..<UInt32.max)
        let targetPSN: SkyLightWindowFocuser.ProcessSerialNumber = [
            UInt32.random(in: 1..<UInt32.max),
            UInt32.random(in: 1..<UInt32.max),
        ]
        let recorder = PostedEventRecorder()

        let focuser = SkyLightWindowFocuser(
            resolveProcessPSN: { pid in
                #expect(pid == targetPid)
                return targetPSN
            },
            postEventRecord: { psn, bytes in
                recorder.record(psn: psn, bytes: bytes)
            },
            isAccessibilityTrusted: { true }
        )

        try focuser.focusWindowWithoutRaising(pid: targetPid, windowId: targetWindowId)

        let posts = recorder.posts

        // Exactly three events: focus, key-window begin, key-window end —
        // and every single one of them must target the target PSN. No
        // events should ever be addressed to a previous front PSN.
        #expect(posts.count == 3)
        for post in posts {
            #expect(post.psn == targetPSN)
        }

        // No defocus event (marker 0x02 in a focus event) is allowed. The
        // focus event-record uses opcode 0x0d at offset 0x08, so we only
        // inspect the focus event for the defocus marker.
        let focusEvents = posts.filter { $0.bytes[0x08] == 0x0d }
        #expect(focusEvents.count == 1)
        #expect(focusEvents.first?.bytes[0x8a] == 0x01)
        #expect(focusEvents.contains(where: { $0.bytes[0x8a] == 0x02 }) == false)

        // Sanity: the three events come out in the documented order
        // (focus → key-window begin → key-window end).
        #expect(posts[0].bytes[0x08] == 0x0d) // focus
        #expect(posts[1].bytes[0x08] == 0x01) // key-window begin
        #expect(posts[2].bytes[0x08] == 0x02) // key-window end
        #expect(posts[1].bytes[0x3a] == 0x10)
        #expect(posts[2].bytes[0x3a] == 0x10)
    }

    @Test("focuser fails fast without accessibility permission")
    func failsFastWithoutAccessibility() {
        let recorder = PostedEventRecorder()
        let focuser = SkyLightWindowFocuser(
            resolveProcessPSN: { _ in
                Issue.record("PSN resolver must not run without AX permission")
                return [0, 0]
            },
            postEventRecord: { _, _ in
                Issue.record("event poster must not run without AX permission")
            },
            isAccessibilityTrusted: { false }
        )

        #expect(throws: ComputerUseError.self) {
            try focuser.focusWindowWithoutRaising(pid: 123, windowId: 456)
        }
        #expect(recorder.posts.isEmpty)
    }
}

private actor FocusRecorder {
    private var recordedCalls: [FocusCall] = []

    var calls: [FocusCall] {
        recordedCalls
    }

    func record(pid: pid_t, windowId: CGWindowID) {
        recordedCalls.append(FocusCall(pid: pid, windowId: windowId))
    }
}

private struct FocusCall: Equatable {
    let pid: pid_t
    let windowId: CGWindowID
}

/// Synchronous recorder for `postEventRecord` calls. The focuser's poster
/// closure is invoked from a non-async context, so a plain class with a
/// lock keeps the test code straightforward.
private final class PostedEventRecorder: @unchecked Sendable {
    struct Post: Sendable {
        let psn: SkyLightWindowFocuser.ProcessSerialNumber
        let bytes: [UInt8]
    }

    private let lock = NSLock()
    private var storage: [Post] = []

    var posts: [Post] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(psn: SkyLightWindowFocuser.ProcessSerialNumber, bytes: [UInt8]) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(Post(psn: psn, bytes: bytes))
    }
}

@testable import AOSComputerUseKit
import CoreGraphics
import Darwin
import Foundation
import Testing

@Suite("ComputerUseCore focus without raise")
struct WindowFocusTests {
    @Test("diagnostics rejects non-positive window order sampling values before probing windows")
    func diagnosticsRejectsNonPositiveWindowOrderSamplingValuesBeforeProbingWindows() async throws {
        let core = ComputerUseCore(
            windowLookup: { _ in
                Issue.record("window lookup should not run for invalid diagnostics sampling values")
                return nil
            },
            visibleWindowsLookup: {
                Issue.record("visible window lookup should not run for invalid diagnostics sampling values")
                return []
            },
            focusWindowWithoutRaising: { _, _ in },
            deactivateWindowWithoutRaising: { _, _ in }
        )

        let invalidValues = [
            (durationMilliseconds: 0, intervalMilliseconds: 5),
            (durationMilliseconds: -1, intervalMilliseconds: 5),
            (durationMilliseconds: 20, intervalMilliseconds: 0),
            (durationMilliseconds: 20, intervalMilliseconds: -1),
            (durationMilliseconds: Int.max, intervalMilliseconds: 5),
            (durationMilliseconds: 20, intervalMilliseconds: Int.max),
        ]

        for values in invalidValues {
            do {
                _ = try await core.diagnostics.observeWindowOrder(
                    pid: 123,
                    windowId: 456,
                    durationMilliseconds: values.durationMilliseconds,
                    intervalMilliseconds: values.intervalMilliseconds
                )
                Issue.record("expected invalid diagnostics sampling values to throw")
            } catch let error as ComputerUseError {
                guard case .diagnosticsUnavailable = error else {
                    Issue.record("unexpected diagnostics sampling error: \(error)")
                    continue
                }
            } catch {
                Issue.record("unexpected diagnostics sampling error: \(error)")
            }
        }
    }

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
            },
            deactivateWindowWithoutRaising: { _, _ in
            }
        )

        let result = try await core.diagnostics.focusWindowWithoutRaise(pid: 123, windowId: 456)

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
            },
            deactivateWindowWithoutRaising: { _, _ in
            }
        )

        await #expect(throws: ComputerUseError.self) {
            try await core.diagnostics.focusWindowWithoutRaise(pid: 123, windowId: 456)
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
        // The default record is the "focus" marker (0x01). Target defocus is
        // an explicit cleanup call, not the standard focus path.
        #expect(bytes[0x8a] == 0x01)
        #expect(bytes[0x3a] == 0x00)
        #expect(bytes[0x20] == 0x00)
    }

    @Test("deactivates only the target PSN with one target-side defocus event")
    func deactivatesOnlyTargetPSNWithOneTargetSideDefocusEvent() throws {
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
            }
        )

        try focuser.deactivateWindowWithoutRaising(pid: targetPid, windowId: targetWindowId)

        let posts = recorder.posts
        #expect(posts.count == 1)
        #expect(posts[0].psn == targetPSN)
        #expect(posts[0].bytes[0x08] == 0x0d)
        #expect(posts[0].bytes[0x8a] == 0x02)
        #expect(posts[0].bytes[0x3c] == UInt8(UInt32(targetWindowId) & 0xff))
    }

    /// Regression: the focuser must never touch the previously-focused
    /// process. Posting a defocus event (or any event) to a non-target PSN
    /// is what used to flip the user's prior window into a deactive state.
    @Test("focuses only the target PSN with one target-side focus event")
    func focusesOnlyTargetPSNWithOneTargetSideFocusEvent() throws {
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
            }
        )

        try focuser.focusWindowWithoutRaising(pid: targetPid, windowId: targetWindowId)

        let posts = recorder.posts

        // Exactly one target-side focus event. No key-window activation and no
        // events should ever be addressed to a previous front PSN.
        #expect(posts.count == 1)
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
        #expect(posts[0].bytes[0x08] == 0x0d)
        #expect(posts[0].bytes[0x8a] == 0x01)
        for post in posts {
            #expect(post.bytes[0x3c] == UInt8(UInt32(targetWindowId) & 0xff))
        }
    }

    @Test("focuser bubbles private SPI failures")
    func bubblesPrivateSPIFailures() {
        enum ProbeFailure: Error {
            case postFailed
        }
        let focuser = SkyLightWindowFocuser(
            resolveProcessPSN: { _ in [1, 2] },
            postEventRecord: { _, _ in
                throw ProbeFailure.postFailed
            }
        )

        #expect(throws: ProbeFailure.postFailed) {
            try focuser.focusWindowWithoutRaising(pid: 123, windowId: 456)
        }
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

@testable import AOSComputerUseKit
import CoreGraphics
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
        let bytes = SkyLightWindowFocuser.makeFocusEventBytes(
            windowId: 0x0102_0304,
            marker: .focus
        )

        #expect(bytes.count == 0xf8)
        #expect(bytes[0x04] == 0xf8)
        #expect(bytes[0x08] == 0x0d)
        #expect(bytes[0x3c] == 0x04)
        #expect(bytes[0x3d] == 0x03)
        #expect(bytes[0x3e] == 0x02)
        #expect(bytes[0x3f] == 0x01)
        #expect(bytes[0x8a] == 0x01)
        #expect(bytes[0x3a] == 0x00)
        #expect(bytes[0x20] == 0x00)
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
